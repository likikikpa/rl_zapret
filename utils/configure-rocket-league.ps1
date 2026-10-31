[CmdletBinding()]
param(
    [ValidateSet('Direct', 'Strategy')][string]$AuthMode,
    [ValidateSet('Fake', 'Fragment')][string]$UdpMode,
    [string]$Payload,
    [string]$UdpPorts
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$statePath = Join-Path $PSScriptRoot 'rocket-league.json'
$state = @{ AuthMode = 'Direct'; UdpMode = 'Fake'; Payload = 'quic_initial_4pda_to.bin'; UdpPorts = '7000-10000,15000-15999,21000-21999' }
if (Test-Path -LiteralPath $statePath) {
    $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    foreach ($key in @($state.Keys)) {
        if ($saved.PSObject.Properties.Name -contains $key) { $state[$key] = $saved.$key }
    }
}
foreach ($key in 'AuthMode', 'UdpMode', 'Payload', 'UdpPorts') {
    if ($PSBoundParameters.ContainsKey($key)) { $state[$key] = $PSBoundParameters[$key] }
}
if ($state.AuthMode -notin 'Direct', 'Strategy' -or $state.UdpMode -notin 'Fake', 'Fragment') { throw 'Invalid saved Rocket League settings.' }
if ($state.Payload -notmatch '^[a-zA-Z0-9_.-]+\.bin$' -or !(Test-Path -LiteralPath (Join-Path $root ('bin\' + $state.Payload)))) { throw 'Select an existing .bin payload in bin.' }
foreach ($range in $state.UdpPorts.Split(',')) {
    if ($range -notmatch '^(\d+)(?:-(\d+))?$') { throw 'Invalid UDP port range.' }
    $first = [int]$Matches[1]
    $last = if ($Matches[2]) { [int]$Matches[2] } else { $first }
    if ($first -lt 1 -or $last -gt 65535 -or $first -gt $last) { throw 'UDP ports must be between 1 and 65535.' }
}

# Keep every profile literal in each launcher so upstream service installation
# and strategy tests can parse it without a custom runtime or environment.
$plans = @()
foreach ($file in Get-ChildItem -LiteralPath $root -Filter 'general*.bat') {
    $lines = @(Get-Content -LiteralPath $file.FullName | Where-Object { $_ -notmatch '^--comment=RL_' })
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^start .*winws\.exe') { $start = $i; break } }
    if ($start -lt 0) { throw "No winws command in $($file.Name)" }
    # Use this ALT's own web strategy when login itself needs DPI handling.
    $web = $lines | Where-Object { $_ -match '^--filter-tcp=80,443 --hostlist=' } | Select-Object -First 1
    if (!$web) { $web = $lines | Where-Object { $_ -match '^--filter-l3=ipv4 --filter-tcp=80,443,' } | Select-Object -First 1 }
    if (!$web) { throw "Cannot find the TCP strategy in $($file.Name)" }
    $desync = [regex]::Match($web, '--dpi-desync=.*?(?= --new| \^|$)').Value
    if (!$desync) { throw "Cannot find the TCP desync settings in $($file.Name)" }
    $auth = '--comment=RL_AUTH_TCP --filter-tcp=80,443,5222 --hostlist="%LISTS%list-rocket-league.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt"'
    $quic = '--comment=RL_AUTH_QUIC --filter-udp=443 --hostlist="%LISTS%list-rocket-league.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt"'
    if ($state.AuthMode -eq 'Strategy') {
        $auth += ' ' + $desync
        $quic += ' --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fake-quic="%BIN%quic_initial_www_google_com.bin"'
    }
    $kind = if ($state.UdpMode -eq 'Fragment') { 'fake,ipfrag2' } else { 'fake' }
    $game = '--comment=RL_GAME_UDP --filter-udp=' + $state.UdpPorts + ' --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=' + $kind + ' --dpi-desync-repeats=6 --dpi-desync-any-protocol=1 --dpi-desync-fake-unknown-udp="%BIN%' + $state.Payload + '" --dpi-desync-fake-stun="%BIN%' + $state.Payload + '" --dpi-desync-cutoff=d4'
    # These rules precede IPSet/GameFilter and work even if GameFilter is disabled.
    $lines[$start] = [regex]::Replace($lines[$start], '--wf-tcp=\S+', '--wf-tcp=80,443,5222,2053,2083,2087,2096,8443,%GameFilterTCP%')
    $lines[$start] = [regex]::Replace($lines[$start], '--wf-udp=\S+', ('--wf-udp=443,19294-19344,50000-50100,' + $state.UdpPorts + ',%GameFilterUDP%'))
    $extra = @(
        ($auth + ' --new ^')
        ($quic + ' --new ^')
        ($game + ' --new ^')
    )
    if ($file.Name -eq 'general (ALT9-CS2).bat') {
        $lines[$start] = $lines[$start].Replace(',%GameFilterUDP%', ',4380,27000-27100,%GameFilterUDP%')
        $extra += '--comment=RL_CS2_COMPAT --filter-udp=4380,27000-27100 --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=fake --dpi-desync-repeats=4 --dpi-desync-any-protocol=1 --dpi-desync-fake-unknown-udp="%BIN%ACTIVE_GAME_UDP.bin" --dpi-desync-cutoff=d3 --new ^'
    }
    $output = @($lines[0..$start]) + $extra + @($lines[($start + 1)..($lines.Count - 1)])
    $plans += [pscustomobject]@{ Path = $file.FullName; Content = ($output -join "`r`n") + "`r`n" }
}
foreach ($plan in $plans) { [IO.File]::WriteAllText($plan.Path, $plan.Content, (New-Object Text.UTF8Encoding $false)) }
$state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding ASCII
Write-Host "Updated $($plans.Count) launchers. Login: $($state.AuthMode); UDP: $($state.UdpMode); payload: $($state.Payload)."
Write-Host 'Restart the running strategy (or reinstall its Windows service) to apply changes.'
