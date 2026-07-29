[CmdletBinding()]
param(
    [switch]$PinN8nOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$config = Import-PowerShellDataFile -LiteralPath (Join-Path $projectRoot 'config.psd1')
$sshExe = 'C:\Windows\System32\OpenSSH\ssh.exe'
$scpExe = 'C:\Windows\System32\OpenSSH\scp.exe'
$localScript = Join-Path $PSScriptRoot 'provision-caprover-n8n.sh'
$remoteScript = '/tmp/provision-caprover-n8n.sh'

if (-not (Test-Path -LiteralPath $localScript -PathType Leaf)) {
    throw "Provisioner not found: $localScript"
}

& $scpExe $localScript "$($config.SshAlias):$remoteScript"
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to copy the platform provisioner to the server.'
}

try {
    & $sshExe $config.SshAlias "bash -n $remoteScript"
    if ($LASTEXITCODE -ne 0) {
        throw 'The platform provisioner failed bash syntax validation.'
    }

    $argument = if ($PinN8nOnly) { ' --pin-n8n-only' } else { '' }
    & $sshExe -t $config.SshAlias "sudo bash $remoteScript$argument"
    if ($LASTEXITCODE -ne 0) {
        throw 'CapRover/n8n provisioning failed.'
    }
} finally {
    & $sshExe $config.SshAlias "sudo rm -f $remoteScript" | Out-Null
}
