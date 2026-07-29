[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$config = Import-PowerShellDataFile -LiteralPath (Join-Path $projectRoot 'config.psd1')
$statePath = Join-Path $projectRoot 'state\current.json'
$sshExe = 'C:\Windows\System32\OpenSSH\ssh.exe'
$awsExe = 'C:\Program Files\Amazon\AWSCLIV2\aws.exe'

if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    throw 'state/current.json is missing. Run run.ps1 first.'
}
$state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
$expectedIp = $state.PublicIp

foreach ($name in @('captain.apps.jurisvoice.com', 'n8n.jurisvoice.com')) {
    $answers = @(Resolve-DnsName -Name $name -Type A -Server 1.1.1.1 -ErrorAction Stop |
        Where-Object Type -eq 'A' |
        Select-Object -ExpandProperty IPAddress -Unique)
    if ($expectedIp -notin $answers) {
        throw "DNS check failed for $name. Expected $expectedIp; received $($answers -join ', ')."
    }
    Write-Host "DNS verified: $name -> $expectedIp"
}

$savedErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $instanceJson = & $awsExe ec2 describe-instances `
        --filters `
        "Name=tag:Name,Values=$($config.InstanceName)" `
        "Name=tag:Project,Values=$($config.ProjectTag)" `
        'Name=instance-state-name,Values=pending,running,stopping,stopped' `
        --profile $config.Profile `
        --region $config.Region `
        --no-cli-pager `
        --output json 2>&1
    $instanceExitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $savedErrorActionPreference
}
if ($instanceExitCode -ne 0) {
    throw "AWS read-only verification failed. Run run.ps1 to renew browser authentication.`n$instanceJson"
}
$instances = @(
    foreach ($reservation in @(($instanceJson -join [Environment]::NewLine | ConvertFrom-Json).Reservations)) {
        foreach ($instance in @($reservation.Instances)) {
            $instance
        }
    }
)
if ($instances.Count -ne 1) {
    throw "Expected exactly one managed instance; found $($instances.Count)."
}
$groupIds = @($instances[0].SecurityGroups | ForEach-Object GroupId)
$ErrorActionPreference = 'Continue'
try {
    $groupJson = & $awsExe ec2 describe-security-groups `
        --group-ids $groupIds `
        --profile $config.Profile `
        --region $config.Region `
        --no-cli-pager `
        --output json 2>&1
    $groupExitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $savedErrorActionPreference
}
if ($groupExitCode -ne 0) {
    throw "Unable to inspect AWS security groups.`n$groupJson"
}
$groups = @((($groupJson -join [Environment]::NewLine | ConvertFrom-Json).SecurityGroups))
foreach ($group in $groups) {
    foreach ($permission in @($group.IpPermissions)) {
        $hasAnyCidr = @($permission.IpRanges).Count -gt 0 -or
            @($permission.Ipv6Ranges).Count -gt 0
        $includesPort3000 = $permission.IpProtocol -eq '-1' -or (
            $permission.IpProtocol -eq 'tcp' -and
            $permission.FromPort -le 3000 -and
            $permission.ToPort -ge 3000
        )
        if ($hasAnyCidr -and $includesPort3000) {
            throw "AWS security group $($group.GroupId) exposes TCP 3000 through a CIDR rule."
        }
    }
}
Write-Host 'AWS verified: no CIDR ingress exposes TCP 3000.'

$remoteCheck = @'
set -euo pipefail
required_services=(
  captain-captain
  captain-certbot
  captain-nginx
  srv-captain--n8n
  srv-captain--n8n-postgres
)
for service in "${required_services[@]}"; do
  replicas="$(sudo docker service ls --format '{{.Name}}|{{.Replicas}}' |
    awk -F'|' -v target="${service}" '$1 == target { print $2 }')"
  [[ "$replicas" == '1/1' ]] || {
    echo "${service} replicas=${replicas:-missing}" >&2
    exit 1
  }
  echo "service verified: ${service} ${replicas}"
done
curl --fail --silent --show-error https://captain.apps.jurisvoice.com/ >/dev/null
health="$(curl --fail --silent --show-error https://n8n.jurisvoice.com/healthz)"
[[ "$health" == '{"status":"ok"}' ]] || {
  echo "Unexpected n8n health response: ${health}" >&2
  exit 1
}
echo 'HTTPS and n8n health verified.'
'@

$processInfo = [System.Diagnostics.ProcessStartInfo]::new()
$processInfo.FileName = $sshExe
$processInfo.Arguments = "$($config.SshAlias) bash -s"
$processInfo.UseShellExecute = $false
$processInfo.RedirectStandardInput = $true
$processInfo.RedirectStandardOutput = $true
$processInfo.RedirectStandardError = $true
$process = [System.Diagnostics.Process]::Start($processInfo)
$process.StandardInput.Write($remoteCheck)
$process.StandardInput.Close()
$output = $process.StandardOutput.ReadToEnd()
$errors = $process.StandardError.ReadToEnd()
$process.WaitForExit()
if ($process.ExitCode -ne 0) {
    throw "Remote platform verification failed.`n$output`n$errors"
}
Write-Host $output.Trim()
Write-Host 'JurisVoice infrastructure verification passed.' -ForegroundColor Green
