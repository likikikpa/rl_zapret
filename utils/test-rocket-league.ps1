param([int]$TimeoutSeconds = 10)
$ErrorActionPreference = 'Stop'
if (!(Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    # curl.exe ships with Windows 10 1803+ and every Windows 11 build.
    Write-Host 'curl.exe was not found. Update Windows 10 to version 1803 or newer.'
    exit 1
}
$results = @()
foreach ($hostName in 'api.rlpp.psynet.gg', 'config.psynet.gg', 'api.epicgames.dev', 'rl-cdn.psyonix.com', 'eos-general.s3.amazonaws.com') {
    $dns = $false
    try { $dns = @([Net.Dns]::GetHostAddresses($hostName)).Count -gt 0 } catch {}
    $line = & curl.exe --noproxy '*' --connect-timeout 5 --max-time $TimeoutSeconds --silent --output NUL --write-out '%{http_code} %{remote_ip} %{time_total}' ('https://' + $hostName + '/')
    $code = $LASTEXITCODE
    $parts = [string]$line -split ' '
    # These API roots need credentials or a path. 401/403/404 still prove HTTPS
    # transport, never successful game authentication or a successful UDP match.
    $https = $code -eq 0 -and $parts[0] -match '^[1-5]\d\d$'
    $results += [pscustomobject]@{ Host = $hostName; DNS = $dns; HTTPS = $https; HTTP = $parts[0]; CurlExit = $code }
}
$results | Format-Table -AutoSize
$resultDir = Join-Path $PSScriptRoot 'test results'
New-Item -ItemType Directory -Path $resultDir -Force | Out-Null
$file = Join-Path $resultDir ('rocket-league-network-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
$results | ConvertTo-Json | Set-Content -LiteralPath $file -Encoding UTF8
Write-Host 'HTTPS checks do not test login credentials, WebSocket persistence, or UDP matches.'
Write-Host 'If a VPN is connected, results describe the VPN route, not the direct ISP route.'
Write-Host "Report: $file"
if (@($results | Where-Object { !$_.DNS -or !$_.HTTPS }).Count -gt 0) { exit 1 }
