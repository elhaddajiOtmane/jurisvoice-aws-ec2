[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({
        try {
            [void][System.Net.IPAddress]::Parse($_)
            $true
        } catch {
            throw "PublicIp must be a valid IP address: $_"
        }
    })]
    [string]$PublicIp,
    [string]$ZoneName = 'jurisvoice.com',
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$token = [Environment]::GetEnvironmentVariable('CLOUDFLARE_API_TOKEN', 'Process')
if ([string]::IsNullOrWhiteSpace($token)) {
    throw 'Set CLOUDFLARE_API_TOKEN in the current PowerShell process. It is never stored by this script.'
}

$headers = @{
    Authorization = "Bearer $token"
    'Content-Type' = 'application/json'
}
$apiRoot = 'https://api.cloudflare.com/client/v4'

function Invoke-Cloudflare {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [object]$Body
    )

    $parameters = @{
        Method = $Method
        Uri = "$apiRoot$Path"
        Headers = $headers
    }
    if ($null -ne $Body) {
        $parameters.Body = $Body | ConvertTo-Json -Depth 6 -Compress
    }
    $response = Invoke-RestMethod @parameters
    if (-not $response.success) {
        $messages = @($response.errors + $response.messages) |
            ForEach-Object { $_.message } |
            Where-Object { $_ }
        throw "Cloudflare API failed: $($messages -join '; ')"
    }
    $response
}

try {
    Invoke-Cloudflare -Method GET -Path '/user/tokens/verify' | Out-Null
    $zoneResponse = Invoke-Cloudflare -Method GET -Path "/zones?name=$([uri]::EscapeDataString($ZoneName))&status=active"
    $zones = @($zoneResponse.result)
    if ($zones.Count -ne 1) {
        throw "Expected exactly one active Cloudflare zone named $ZoneName; found $($zones.Count)."
    }
    $zoneId = $zones[0].id

    foreach ($recordName in @('*.apps.jurisvoice.com', 'n8n.jurisvoice.com')) {
        $encodedName = [uri]::EscapeDataString($recordName)
        $recordResponse = Invoke-Cloudflare -Method GET -Path "/zones/$zoneId/dns_records?type=A&name=$encodedName"
        $records = @($recordResponse.result)
        if ($records.Count -gt 1) {
            throw "Found duplicate A records for $recordName. Resolve manually before continuing."
        }

        $desired = @{
            type = 'A'
            name = $recordName
            content = $PublicIp
            ttl = 1
            proxied = $false
            comment = if ($recordName -like 'n8n.*') { 'n8n on CapRover' } else { 'CapRover wildcard' }
        }
        $existing = $records | Select-Object -First 1
        $isCorrect = $existing -and
            $existing.content -eq $PublicIp -and
            -not $existing.proxied -and
            $existing.ttl -eq 1

        if ($isCorrect) {
            Write-Host "Verified: $recordName -> $PublicIp (DNS only)"
            continue
        }
        if ($CheckOnly) {
            throw "DNS drift: $recordName is missing or does not match $PublicIp, DNS-only, TTL auto."
        }

        $action = if ($existing) { 'Update' } else { 'Create' }
        if ($PSCmdlet.ShouldProcess($recordName, "$action Cloudflare A record")) {
            if ($existing) {
                Invoke-Cloudflare -Method PUT -Path "/zones/$zoneId/dns_records/$($existing.id)" -Body $desired | Out-Null
            } else {
                Invoke-Cloudflare -Method POST -Path "/zones/$zoneId/dns_records" -Body $desired | Out-Null
            }
            Write-Host "$action complete: $recordName -> $PublicIp (DNS only)"
        }
    }
} finally {
    $token = $null
    $headers.Authorization = $null
}
