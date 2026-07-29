$ErrorActionPreference = 'Stop'
$config = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'config.psd1')
$awsExe = 'C:\Program Files\Amazon\AWSCLIV2\aws.exe'

& $awsExe sts get-caller-identity --profile $config.Profile --region $config.Region --no-cli-pager | Out-Null
if ($LASTEXITCODE -ne 0) {
    & $awsExe login --profile $config.Profile
    if ($LASTEXITCODE -ne 0) {
        throw 'AWS browser authentication failed or expired.'
    }
}

& $awsExe ec2 describe-instances `
    --filters `
    "Name=tag:Name,Values=$($config.InstanceName)" `
    "Name=tag:Project,Values=$($config.ProjectTag)" `
    'Name=instance-state-name,Values=pending,running,stopping,stopped' `
    --query 'Reservations[].Instances[].{InstanceId:InstanceId,State:State.Name,Type:InstanceType,PublicIp:PublicIpAddress,AZ:Placement.AvailabilityZone}' `
    --profile $config.Profile `
    --region $config.Region `
    --no-cli-pager `
    --output table
