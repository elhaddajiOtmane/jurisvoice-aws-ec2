[CmdletBinding()]
param(
    [switch]$SkipSshTest,
    [switch]$EnsureCloudflareDns,
    [switch]$ProvisionPlatform,
    [switch]$VerifyPlatform
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = $PSScriptRoot
$config = Import-PowerShellDataFile -LiteralPath (Join-Path $projectRoot 'config.psd1')
$awsExe = 'C:\Program Files\Amazon\AWSCLIV2\aws.exe'
$sshExe = 'C:\Windows\System32\OpenSSH\ssh.exe'
$publicKeyPath = Join-Path $projectRoot 'public-keys\ubuntu-server-1.pub'
$stateFolder = Join-Path $projectRoot 'state'
$logFolder = Join-Path $projectRoot 'logs'

New-Item -ItemType Directory -Force -Path $stateFolder, $logFolder | Out-Null
$logPath = Join-Path $logFolder 'last-run.log'
Start-Transcript -LiteralPath $logPath -Force | Out-Null

function Invoke-Aws {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    $output = & $awsExe @Arguments `
        --profile $config.Profile `
        --region $config.Region `
        --no-cli-pager 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "AWS command failed: aws $($Arguments -join ' ')`n$output"
    }
    [PSCustomObject]@{
        ExitCode = $exitCode
        Output = ($output -join [Environment]::NewLine)
    }
}

function ConvertFrom-AwsJson {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $result = Invoke-Aws -Arguments ($Arguments + @('--output', 'json'))
    if ([string]::IsNullOrWhiteSpace($result.Output)) {
        return $null
    }
    $result.Output | ConvertFrom-Json
}

function Ensure-AwsLogin {
    $identity = Invoke-Aws -Arguments @('sts', 'get-caller-identity') -AllowFailure
    if ($identity.ExitCode -eq 0) {
        return
    }

    Write-Host 'AWS browser authentication is required.' -ForegroundColor Yellow
    & $awsExe configure set region $config.Region --profile $config.Profile
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to configure the AWS profile region.'
    }
    & $awsExe login --profile $config.Profile
    if ($LASTEXITCODE -ne 0) {
        throw 'AWS browser authentication failed or expired.'
    }

    $identity = Invoke-Aws -Arguments @('sts', 'get-caller-identity')
    Write-Host "Authenticated: $($identity.Output)"
}

function Ensure-SecurityGroup {
    param(
        [Parameter(Mandatory)][string]$VpcId,
        [Parameter(Mandatory)][string]$CurrentCidr
    )

    $groups = ConvertFrom-AwsJson @(
        'ec2', 'describe-security-groups',
        '--filters',
        "Name=group-name,Values=$($config.SecurityGroupName)",
        "Name=vpc-id,Values=$VpcId"
    )
    $group = @($groups.SecurityGroups) | Select-Object -First 1
    if (-not $group) {
        $created = ConvertFrom-AwsJson @(
            'ec2', 'create-security-group',
            '--group-name', $config.SecurityGroupName,
            '--description', 'SSH restricted to the current operator public IP',
            '--vpc-id', $VpcId,
            '--tag-specifications',
            "ResourceType=security-group,Tags=[{Key=Name,Value=$($config.SecurityGroupName)},{Key=Project,Value=$($config.ProjectTag)},{Key=Owner,Value=$($config.OwnerTag)}]"
        )
        $groupId = $created.GroupId
        $groups = ConvertFrom-AwsJson @(
            'ec2', 'describe-security-groups',
            '--group-ids', $groupId
        )
        $group = @($groups.SecurityGroups) | Select-Object -First 1
    }

    $groupId = $group.GroupId
    $hasPublicAllTraffic = @(
        foreach ($permission in @($group.IpPermissions)) {
            if ($permission.IpProtocol -eq '-1') {
                foreach ($range in @($permission.IpRanges)) {
                    if ($range.CidrIp -eq '0.0.0.0/0') {
                        $true
                    }
                }
            }
        }
    ) -contains $true

    if ($hasPublicAllTraffic) {
        Invoke-Aws -Arguments @(
            'ec2', 'revoke-security-group-ingress',
            '--group-id', $groupId,
            '--protocol', '-1',
            '--cidr', '0.0.0.0/0'
        ) | Out-Null
    }

    $existingCidrs = @(
        foreach ($permission in @($group.IpPermissions)) {
            if ($permission.IpProtocol -eq 'tcp' -and
                $permission.FromPort -eq 22 -and
                $permission.ToPort -eq 22) {
                foreach ($range in @($permission.IpRanges)) {
                    $range.CidrIp
                }
            }
        }
    )

    foreach ($cidr in $existingCidrs) {
        if ($cidr -and $cidr -ne $CurrentCidr) {
            Invoke-Aws -Arguments @(
                'ec2', 'revoke-security-group-ingress',
                '--group-id', $groupId,
                '--protocol', 'tcp',
                '--port', '22',
                '--cidr', $cidr
            ) | Out-Null
        }
    }

    if ($CurrentCidr -notin $existingCidrs) {
        Invoke-Aws -Arguments @(
            'ec2', 'authorize-security-group-ingress',
            '--group-id', $groupId,
            '--protocol', 'tcp',
            '--port', '22',
            '--cidr', $CurrentCidr
        ) | Out-Null
    }

    foreach ($port in @($config.PublicTcpPorts)) {
        $hasPublicIngress = @(
            foreach ($permission in @($group.IpPermissions)) {
                if ($permission.IpProtocol -eq 'tcp' -and
                    $permission.FromPort -le $port -and
                    $permission.ToPort -ge $port) {
                    foreach ($range in @($permission.IpRanges)) {
                        if ($range.CidrIp -eq '0.0.0.0/0') {
                            $true
                        }
                    }
                }
            }
        ) -contains $true

        if (-not $hasPublicIngress) {
            Invoke-Aws -Arguments @(
                'ec2', 'authorize-security-group-ingress',
                '--group-id', $groupId,
                '--protocol', 'tcp',
                '--port', [string]$port,
                '--cidr', '0.0.0.0/0'
            ) | Out-Null
        }
    }

    $groupId
}

function Ensure-KeyPair {
    $pairs = ConvertFrom-AwsJson @(
        'ec2', 'describe-key-pairs',
        '--filters', "Name=key-name,Values=$($config.KeyPairName)"
    )
    if (@($pairs.KeyPairs).Count -gt 0) {
        return
    }
    if (-not (Test-Path -LiteralPath $publicKeyPath -PathType Leaf)) {
        throw "Public key missing: $publicKeyPath"
    }
    Invoke-Aws -Arguments @(
        'ec2', 'import-key-pair',
        '--key-name', $config.KeyPairName,
        '--public-key-material', "fileb://$publicKeyPath",
        '--tag-specifications',
        "ResourceType=key-pair,Tags=[{Key=Project,Value=$($config.ProjectTag)},{Key=Owner,Value=$($config.OwnerTag)}]"
    ) | Out-Null
}

function Get-ManagedInstances {
    $result = ConvertFrom-AwsJson @(
        'ec2', 'describe-instances',
        '--filters',
        "Name=tag:Name,Values=$($config.InstanceName)",
        "Name=tag:Project,Values=$($config.ProjectTag)",
        'Name=instance-state-name,Values=pending,running,stopping,stopped'
    )
    @(
        foreach ($reservation in @($result.Reservations)) {
            foreach ($instance in @($reservation.Instances)) {
                $instance
            }
        }
    )
}

function New-ManagedInstance {
    param(
        [Parameter(Mandatory)][string]$SubnetId,
        [Parameter(Mandatory)][string]$SecurityGroupId,
        [Parameter(Mandatory)][string]$ImageId
    )

    $blockMappings = @(
        @{
            DeviceName = '/dev/sda1'
            Ebs = @{
                DeleteOnTermination = $true
                Encrypted = $true
                VolumeSize = $config.RootVolumeGiB
                VolumeType = 'gp3'
                Iops = 3000
                Throughput = 125
            }
        }
    )
    $mappingPath = Join-Path ([System.IO.Path]::GetTempPath()) 'aws-ec2-root-volume.json'
    [System.IO.File]::WriteAllText(
        $mappingPath,
        ($blockMappings | ConvertTo-Json -Depth 5),
        [System.Text.UTF8Encoding]::new($false)
    )

    $created = ConvertFrom-AwsJson @(
        'ec2', 'run-instances',
        '--image-id', $ImageId,
        '--instance-type', $config.InstanceType,
        '--count', '1',
        '--key-name', $config.KeyPairName,
        '--security-group-ids', $SecurityGroupId,
        '--subnet-id', $SubnetId,
        '--associate-public-ip-address',
        '--block-device-mappings', "file://$mappingPath",
        '--metadata-options', 'HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=1',
        '--tag-specifications',
        "ResourceType=instance,Tags=[{Key=Name,Value=$($config.InstanceName)},{Key=Project,Value=$($config.ProjectTag)},{Key=Owner,Value=$($config.OwnerTag)}]",
        "ResourceType=volume,Tags=[{Key=Name,Value=$($config.InstanceName)-root},{Key=Project,Value=$($config.ProjectTag)},{Key=Owner,Value=$($config.OwnerTag)}]",
        '--client-token', "$($config.ProjectTag)-single-server-v1"
    )
    @($created.Instances)[0]
}

function Ensure-InstanceConfiguration {
    param([Parameter(Mandatory)]$Instance)

    $instanceId = $Instance.InstanceId
    if ($Instance.InstanceType -ne $config.InstanceType) {
        if ($Instance.State.Name -ne 'stopped') {
            Write-Host "Stopping $instanceId to change type..."
            Invoke-Aws -Arguments @('ec2', 'stop-instances', '--instance-ids', $instanceId) | Out-Null
            Invoke-Aws -Arguments @('ec2', 'wait', 'instance-stopped', '--instance-ids', $instanceId) | Out-Null
        }
        Invoke-Aws -Arguments @(
            'ec2', 'modify-instance-attribute',
            '--instance-id', $instanceId,
            '--instance-type', "Value=$($config.InstanceType)"
        ) | Out-Null
        $Instance.State.Name = 'stopped'
    }

    Invoke-Aws -Arguments @(
        'ec2', 'modify-instance-metadata-options',
        '--instance-id', $instanceId,
        '--http-tokens', 'required',
        '--http-endpoint', 'enabled',
        '--http-put-response-hop-limit', '1'
    ) | Out-Null

    $volumes = ConvertFrom-AwsJson @(
        'ec2', 'describe-volumes',
        '--filters', "Name=attachment.instance-id,Values=$instanceId"
    )
    $rootVolume = @($volumes.Volumes) | Select-Object -First 1
    if (-not $rootVolume.Encrypted) {
        throw 'The existing root volume is not encrypted. Automatic in-place encryption is not safe.'
    }
    if ($rootVolume.Size -lt $config.RootVolumeGiB) {
        Invoke-Aws -Arguments @(
            'ec2', 'modify-volume',
            '--volume-id', $rootVolume.VolumeId,
            '--size', [string]$config.RootVolumeGiB,
            '--volume-type', 'gp3'
        ) | Out-Null
    }

    $fresh = Get-ManagedInstances | Where-Object InstanceId -eq $instanceId
    if ($fresh.State.Name -ne 'running') {
        Write-Host "Starting $instanceId..."
        Invoke-Aws -Arguments @('ec2', 'start-instances', '--instance-ids', $instanceId) | Out-Null
    }
    Invoke-Aws -Arguments @('ec2', 'wait', 'instance-status-ok', '--instance-ids', $instanceId) | Out-Null
}

function Set-SshAlias {
    param([Parameter(Mandatory)][string]$PublicIp)

    if (-not (Test-Path -LiteralPath $config.PrivateKeyPath -PathType Leaf)) {
        throw "Private key missing: $($config.PrivateKeyPath)"
    }

    $sshFolder = Join-Path $env:USERPROFILE '.ssh'
    $sshConfigPath = Join-Path $sshFolder 'config'
    New-Item -ItemType Directory -Force -Path $sshFolder | Out-Null
    $existing = if (Test-Path -LiteralPath $sshConfigPath -PathType Leaf) {
        [System.IO.File]::ReadAllText($sshConfigPath)
    } else {
        ''
    }
    $managedPattern = '(?ms)^\# BEGIN CODEX AWS SERVER\r?\n.*?^\# END CODEX AWS SERVER\r?\n?'
    $withoutManaged = [regex]::Replace($existing, $managedPattern, '')
    if ($withoutManaged -match "(?im)^\s*Host\s+[^\r\n]*\b$([regex]::Escape($config.SshAlias))\b") {
        throw "An unmanaged SSH Host named $($config.SshAlias) already exists."
    }

    $block = @"
# BEGIN CODEX AWS SERVER
Host $($config.SshAlias)
    HostName $PublicIp
    User $($config.SshUser)
    IdentityFile $($config.PrivateKeyPath.Replace('\', '/'))
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    ServerAliveInterval 60
# END CODEX AWS SERVER
"@
    $clean = $withoutManaged.TrimEnd()
    $newConfig = if ($clean) { "$clean`r`n`r`n$block`r`n" } else { "$block`r`n" }
    [System.IO.File]::WriteAllText(
        $sshConfigPath,
        $newConfig,
        [System.Text.UTF8Encoding]::new($false)
    )
}

try {
    if (-not (Test-Path -LiteralPath $awsExe -PathType Leaf)) {
        throw "AWS CLI not installed at $awsExe"
    }
    if (-not (Test-Path -LiteralPath $sshExe -PathType Leaf)) {
        throw "Windows OpenSSH not installed at $sshExe"
    }

    Ensure-AwsLogin
    $identity = ConvertFrom-AwsJson @('sts', 'get-caller-identity')
    Write-Host "AWS account: $($identity.Account)"

    $typeInfo = ConvertFrom-AwsJson @(
        'ec2', 'describe-instance-types',
        '--instance-types', $config.InstanceType
    )
    $selectedType = @($typeInfo.InstanceTypes)[0]
    if ($selectedType.VCpuInfo.DefaultVCpus -ne $config.ExpectedVcpus -or
        $selectedType.MemoryInfo.SizeInMiB -ne $config.ExpectedMemoryMiB) {
        throw 'Configured instance type no longer matches the expected CPU and memory.'
    }

    $publicIp = (Invoke-RestMethod -Uri 'https://checkip.amazonaws.com').Trim()
    $currentCidr = "$publicIp/32"
    Write-Host "SSH source: $currentCidr"

    $vpcs = ConvertFrom-AwsJson @(
        'ec2', 'describe-vpcs',
        '--filters', 'Name=is-default,Values=true'
    )
    $vpc = @($vpcs.Vpcs) | Select-Object -First 1
    if (-not $vpc) {
        throw 'No default VPC exists in the configured Region.'
    }

    $subnets = ConvertFrom-AwsJson @(
        'ec2', 'describe-subnets',
        '--filters',
        "Name=vpc-id,Values=$($vpc.VpcId)",
        "Name=availability-zone,Values=$($config.AvailabilityZone)",
        'Name=default-for-az,Values=true'
    )
    $subnet = @($subnets.Subnets) | Select-Object -First 1
    if (-not $subnet) {
        throw "No default subnet found in $($config.AvailabilityZone)."
    }

    $securityGroupId = Ensure-SecurityGroup -VpcId $vpc.VpcId -CurrentCidr $currentCidr
    Ensure-KeyPair

    $instances = @(Get-ManagedInstances)
    if ($instances.Count -gt 1) {
        throw "Found $($instances.Count) active managed instances. Refusing to create or delete anything."
    }
    if ($instances.Count -eq 0) {
        $ami = ConvertFrom-AwsJson @(
            'ssm', 'get-parameter',
            '--name', $config.UbuntuAmiParameter
        )
        Write-Host 'Creating the single managed EC2 instance...'
        $instance = New-ManagedInstance `
            -SubnetId $subnet.SubnetId `
            -SecurityGroupId $securityGroupId `
            -ImageId $ami.Parameter.Value
    } else {
        $instance = $instances[0]
    }

    Ensure-InstanceConfiguration -Instance $instance
    $instance = @(Get-ManagedInstances)[0]
    Set-SshAlias -PublicIp $instance.PublicIpAddress

    if (-not $SkipSshTest) {
        & $sshExe -o BatchMode=yes -o ConnectTimeout=15 $config.SshAlias 'printf connected'
        if ($LASTEXITCODE -ne 0) {
            throw 'EC2 is healthy, but the live SSH connection test failed.'
        }
    }

    $state = [ordered]@{
        UpdatedAt = (Get-Date).ToString('o')
        AccountId = $identity.Account
        Region = $config.Region
        InstanceId = $instance.InstanceId
        InstanceType = $instance.InstanceType
        PublicIp = $instance.PublicIpAddress
        SshCommand = "ssh $($config.SshAlias)"
        SshSource = $currentCidr
        PrivateKeyPath = $config.PrivateKeyPath
    }
    $statePath = Join-Path $stateFolder 'current.json'
    [System.IO.File]::WriteAllText(
        $statePath,
        ($state | ConvertTo-Json),
        [System.Text.UTF8Encoding]::new($false)
    )

    if ($EnsureCloudflareDns) {
        & (Join-Path $projectRoot 'scripts\ensure-cloudflare-dns.ps1') `
            -PublicIp $instance.PublicIpAddress
    }

    if ($ProvisionPlatform) {
        & (Join-Path $projectRoot 'scripts\deploy-platform.ps1')
    }

    if ($VerifyPlatform) {
        & (Join-Path $projectRoot 'scripts\verify-platform.ps1')
    }

    Write-Host ''
    Write-Host 'AWS EC2 is ready.' -ForegroundColor Green
    Write-Host "Instance: $($instance.InstanceId)"
    Write-Host "Type: $($instance.InstanceType) (4 vCPU, 8 GiB RAM)"
    Write-Host "Public IP: $($instance.PublicIpAddress)"
    Write-Host "Connect: ssh $($config.SshAlias)"
} finally {
    Stop-Transcript | Out-Null
}
