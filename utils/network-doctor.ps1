# Network Doctor: finds out WHERE high ping / lag comes from and fixes what can
# safely be fixed in software.
#
# 1. Hardware and Windows: Wi-Fi vs cable, signal, 2.4/5 GHz, USB adapters,
#    Ethernet link speed (damaged cable), packet errors, connection drops,
#    driver problems, VPN in the path, background downloads, power saving.
# 2. Ping split by segment, all measured at the same time:
#       PC -> router -> ISP -> Moscow -> Europe (Rocket League EU servers)
#    so a slow segment points at Wi-Fi/cable, the ISP line, or ISP routing.
# 3. Bufferbloat: ping while the line is fully loaded by a download.
# 4. Optional, reversible fixes (power saving only). "-Revert" undoes them.
#
# Windows 10 1803+ / Windows 11, Windows PowerShell 5.1, run as administrator.
[CmdletBinding()]
param(
    [switch]$Revert,
    [switch]$NoFix,
    [switch]$SkipLoadTest
)

$ErrorActionPreference = 'Continue'
$utils = $PSScriptRoot
$root = Split-Path -Parent $utils
$backupFile = Join-Path $utils 'network-doctor-backup.json'
$resultsDir = Join-Path $utils 'test results'
$findings = New-Object System.Collections.Generic.List[object]
$report = New-Object System.Collections.Generic.List[string]

function Out-Line([string]$Text = '', [string]$Color = 'Gray') {
    Write-Host $Text -ForegroundColor $Color
    $report.Add($Text)
}
function Out-Head([string]$Text) { Out-Line ''; Out-Line "== $Text ==" 'Cyan' }

# Severity: 3 = very likely a cause of lag, 2 = probably contributes, 1 = minor / info.
function Add-Finding([int]$Severity, [string]$Problem, [string]$Fix) {
    $findings.Add([pscustomobject]@{ Severity = $Severity; Problem = $Problem; Fix = $Fix })
}

function Get-Stats($Samples) {
    $all = @($Samples)
    if ($all.Count -eq 0) { return $null }
    $ok = @($all | Where-Object { $_ -ge 0 })
    $loss = [Math]::Round(100.0 * ($all.Count - $ok.Count) / $all.Count, 1)
    if ($ok.Count -eq 0) {
        return [pscustomobject]@{ Avg = $null; Min = $null; Median = $null; Max = $null; Jitter = $null; Loss = $loss }
    }
    $jitter = 0.0
    for ($i = 1; $i -lt $ok.Count; $i++) { $jitter += [Math]::Abs($ok[$i] - $ok[$i - 1]) }
    if ($ok.Count -gt 1) { $jitter = $jitter / ($ok.Count - 1) }
    $sorted = @($ok | Sort-Object)
    [pscustomobject]@{
        Avg    = [Math]::Round(($ok | Measure-Object -Average).Average, 1)
        Min    = [Math]::Round($sorted[0], 1)
        Median = [Math]::Round($sorted[[int][Math]::Floor($sorted.Count / 2)], 1)
        Max    = [Math]::Round($sorted[-1], 1)
        Jitter = [Math]::Round($jitter, 1)
        Loss   = $loss
    }
}

# Pings every target in the same rounds so the segments are comparable.
# Returns name -> stats. Lost replies count as -1.
function Measure-Icmp([System.Collections.Specialized.OrderedDictionary]$Targets, [int]$Rounds, [int]$IntervalMs) {
    $names = @($Targets.Keys)
    $samples = @{}
    $pingers = @{}
    foreach ($n in $names) {
        $samples[$n] = New-Object System.Collections.Generic.List[double]
        $pingers[$n] = New-Object System.Net.NetworkInformation.Ping
    }
    for ($r = 0; $r -lt $Rounds; $r++) {
        $tasks = @{}
        foreach ($n in $names) { $tasks[$n] = $pingers[$n].SendPingAsync([string]$Targets[$n], 1000) }
        foreach ($n in $names) {
            $value = -1.0
            try {
                $reply = $tasks[$n].Result
                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { $value = [double]$reply.RoundtripTime }
            } catch {}
            $samples[$n].Add($value)
        }
        Start-Sleep -Milliseconds $IntervalMs
    }
    foreach ($p in $pingers.Values) { $p.Dispose() }
    $result = @{}
    foreach ($n in $names) { $result[$n] = Get-Stats $samples[$n] }
    return $result
}

# TCP handshake time = network round trip; works for servers that drop ping.
function Measure-Tcp([string]$HostName, [int]$Count = 8) {
    $ip = $null
    try { $ip = [Net.Dns]::GetHostAddresses($HostName) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1 } catch {}
    if (!$ip) { return $null }
    $samples = New-Object System.Collections.Generic.List[double]
    for ($i = 0; $i -lt $Count; $i++) {
        $client = New-Object System.Net.Sockets.TcpClient
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $value = -1.0
        try {
            $task = $client.ConnectAsync($ip, 443)
            if ($task.Wait(2500) -and $client.Connected) { $value = $watch.Elapsed.TotalMilliseconds }
        } catch {} finally { $client.Close() }
        $samples.Add($value)
        Start-Sleep -Milliseconds 150
    }
    return Get-Stats $samples
}

function Format-Stats($Stats, [switch]$Tcp) {
    if (!$Stats) { return 'n/a' }
    if ($null -eq $Stats.Avg) { return 'no reply' }
    if ($Tcp) { return ('{0,6} ms   (best {1} ms, loss {2}%)' -f $Stats.Median, $Stats.Min, $Stats.Loss) }
    return ('{0,6} ms   (min {1}, max {2}, jitter {3}, loss {4}%)' -f $Stats.Avg, $Stats.Min, $Stats.Max, $Stats.Jitter, $Stats.Loss)
}

function Get-ActiveScheme {
    $text = (& powercfg.exe /getactivescheme) -join ' '
    if ($text -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { return $matches[1] }
    return $null
}

# Reads AC/DC values of a power setting. The output is localized, but the two
# current values are always the last two hex numbers.
function Get-PowerValue([string]$Scheme, [string]$Sub, [string]$Setting) {
    $out = & powercfg.exe /query $Scheme $Sub $Setting 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    $hex = @(([regex]::Matches(($out -join "`n"), '0x([0-9a-fA-F]{8})')) | ForEach-Object { $_.Groups[1].Value })
    if ($hex.Count -lt 2) { return $null }
    return [pscustomobject]@{ AC = [Convert]::ToInt32($hex[-2], 16); DC = [Convert]::ToInt32($hex[-1], 16) }
}

function Set-PowerValue([string]$Scheme, [string]$Sub, [string]$Setting, [int]$AC, [int]$DC) {
    & powercfg.exe /setacvalueindex $Scheme $Sub $Setting $AC | Out-Null
    & powercfg.exe /setdcvalueindex $Scheme $Sub $Setting $DC | Out-Null
}

# -RegistryKeyword takes wildcards ('*EEE' would also match 'AdvancedEEE'),
# so properties are always matched exactly.
function Get-AdvProp([string]$AdapterName, [string]$Keyword) {
    @(Get-NetAdapterAdvancedProperty -Name $AdapterName -AllProperties -ErrorAction SilentlyContinue |
        Where-Object { $_.RegistryKeyword -eq $Keyword }) | Select-Object -First 1
}

function Set-AdvProp([string]$AdapterName, [string]$Keyword, [string]$Value) {
    $prop = Get-AdvProp $AdapterName $Keyword
    if (!$prop) { throw "setting $Keyword not found" }
    $prop | Set-NetAdapterAdvancedProperty -RegistryValue $Value -NoRestart -ErrorAction Stop
}

function Get-AdapterClassKey($Adapter) {
    $classRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
    foreach ($key in @(Get-ChildItem -LiteralPath $classRoot -ErrorAction SilentlyContinue)) {
        $id = (Get-ItemProperty -LiteralPath $key.PSPath -Name NetCfgInstanceId -ErrorAction SilentlyContinue).NetCfgInstanceId
        if ($id -and $id -eq $Adapter.InterfaceGuid) { return $key.PSPath }
    }
    return $null
}

function Get-WifiInfo {
    $info = [pscustomobject]@{ Signal = $null; Radio = $null; Channel = $null; Band = $null }
    $prevOut = [Console]::OutputEncoding
    $prevIn = [Console]::InputEncoding
    $text = ''
    try {
        # netsh output is localized; read it as UTF-8 so Russian labels parse.
        [Console]::OutputEncoding = [Text.Encoding]::UTF8
        $text = (& cmd.exe /d /c 'chcp 65001 >nul & netsh wlan show interfaces') -join "`n"
    } catch {} finally {
        try { [Console]::OutputEncoding = $prevOut; [Console]::InputEncoding = $prevIn } catch {}
    }
    if ($text -match '(?m):\s*(\d{1,3})\s*%\s*$') { $info.Signal = [int]$matches[1] }
    if ($text -match '(?m):\s*802\.11\s?([a-z]+)\s*$') { $info.Radio = '802.11' + $matches[1] }
    # "Channel" / Russian "Kanal"
    if ($text -match '(?im)^\s*(Channel|\u041a\u0430\u043d\u0430\u043b)\s*:\s*(\d+)') { $info.Channel = [int]$matches[2] }
    # "GHz" / Russian "GGts" (Windows 11 prints the band)
    if ($text -match '(?m):\s*(\d+(?:[.,]\d+)?)\s*(GHz|\u0413\u0413\u0446)\s*$') { $info.Band = $matches[1].Replace(',', '.') }
    elseif ($info.Channel) { $info.Band = if ($info.Channel -le 14) { '2.4' } else { '5' } }
    return $info
}

# Power settings (current power plan). Value 0 = no power saving.
$powerSettings = @(
    [pscustomobject]@{ Name = 'USB selective suspend';            Sub = '2a737441-1930-4402-8d77-b2bebba308a3'; Setting = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'; Want = 0; WifiOnly = $false }
    [pscustomobject]@{ Name = 'PCI Express link power saving';    Sub = '501a4d13-42af-4429-9fd1-a8218c268e20'; Setting = 'ee12f906-d277-404b-b6da-e5fa1a576df5'; Want = 0; WifiOnly = $false }
    [pscustomobject]@{ Name = 'Wi-Fi adapter power saving';       Sub = '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'; Setting = '12bbebe6-58d6-4636-95bb-3217ef867c1a'; Want = 0; WifiOnly = $true }
)
# Driver power-saving options (only changed if the driver has them).
$advancedSettings = @(
    [pscustomobject]@{ Keyword = '*EEE';                Want = '0'; Name = 'Energy Efficient Ethernet' }
    [pscustomobject]@{ Keyword = 'EEE';                 Want = '0'; Name = 'Energy Efficient Ethernet' }
    [pscustomobject]@{ Keyword = 'AdvancedEEE';         Want = '0'; Name = 'Advanced EEE' }
    [pscustomobject]@{ Keyword = 'EnableGreenEthernet'; Want = '0'; Name = 'Green Ethernet' }
    [pscustomobject]@{ Keyword = 'GigaLite';            Want = '0'; Name = 'Gigabit Lite' }
    [pscustomobject]@{ Keyword = 'PowerSavingMode';     Want = '0'; Name = 'Power Saving Mode' }
    [pscustomobject]@{ Keyword = 'AutoDisableGigabit';  Want = '0'; Name = 'Auto Disable Gigabit' }
    [pscustomobject]@{ Keyword = 'ULPMode';             Want = '0'; Name = 'Ultra Low Power Mode' }
    [pscustomobject]@{ Keyword = '*SelectiveSuspend';   Want = '0'; Name = 'USB selective suspend (adapter)' }
    [pscustomobject]@{ Keyword = 'RoamAggressiveness';  Want = '0'; Name = 'Wi-Fi roaming aggressiveness (scans cause spikes)' }
)

# ---------------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Run this as administrator (use "Network Doctor.cmd").' -ForegroundColor Red
    exit 1
}

# --- revert ----------------------------------------------------------------
if ($Revert) {
    if (!(Test-Path -LiteralPath $backupFile)) { Write-Host 'Nothing to undo: no changes were made by Network Doctor.' -ForegroundColor Yellow; exit 0 }
    $backup = Get-Content -LiteralPath $backupFile -Raw | ConvertFrom-Json
    foreach ($p in @($backup.Power)) {
        Set-PowerValue $p.Scheme $p.Sub $p.Setting $p.AC $p.DC
        Write-Host "Restored power setting: $($p.Name)"
    }
    if (@($backup.Power).Count -gt 0) { & powercfg.exe /setactive (Get-ActiveScheme) | Out-Null }
    $restart = @{}
    foreach ($a in @($backup.Advanced)) {
        try {
            Set-AdvProp $a.Adapter $a.Keyword ([string]$a.Value)
            $restart[$a.Adapter] = $true
            Write-Host "Restored $($a.Adapter): $($a.Name)"
        } catch { Write-Host "Could not restore $($a.Adapter): $($a.Name)" -ForegroundColor Yellow }
    }
    foreach ($k in @($backup.PnP)) {
        if ($k.Existed) { Set-ItemProperty -LiteralPath $k.Key -Name PnPCapabilities -Value ([int]$k.Value) -Type DWord }
        else { Remove-ItemProperty -LiteralPath $k.Key -Name PnPCapabilities -ErrorAction SilentlyContinue }
        Write-Host "Restored 'allow Windows to turn off' for $($k.Adapter)"
    }
    foreach ($name in $restart.Keys) {
        Write-Host "Restarting adapter $name (internet drops for a few seconds)..."
        Restart-NetAdapter -Name $name -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $backupFile -Force
    Write-Host 'All Network Doctor changes were undone. Reboot to finish.' -ForegroundColor Green
    exit 0
}

if (!(Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    Write-Host 'curl.exe was not found. Update Windows 10 to version 1803 or newer.' -ForegroundColor Red
    exit 1
}

Out-Line "Network Doctor - $(Get-Date -Format 'yyyy-MM-dd HH:mm')" 'Cyan'
Out-Line 'Takes about 1-2 minutes. Do not download or stream anything meanwhile.' 'DarkGray'

if (Get-Process -Name RocketLeague -ErrorAction SilentlyContinue) {
    Write-Host ''
    Write-Host 'Rocket League is running. The speed test will make a match lag for ~15 s.' -ForegroundColor Yellow
    $answer = Read-Host 'Continue anyway? [Y/N]'
    if ($answer -notmatch '^[Yy]') { exit 0 }
}

# --- 1. connection --------------------------------------------------------------
Out-Head 'Connection'
$route = @(Find-NetRoute -RemoteIPAddress '77.88.8.8' -ErrorAction SilentlyContinue) |
    Where-Object { $_.PSObject.Properties.Name -contains 'NextHop' } | Select-Object -First 1
if (!$route) {
    Out-Line 'No route to the internet. Check that the PC is connected.' 'Red'
    exit 1
}
$vpnPattern = '(?i)vpn|tap-|wireguard|wintun|openvpn|\btun\b|hamachi|radmin|zerotier|amnezia|outline|proton|nord|warp|v2ray|xray|sing-?box|hiddify|clash|tailscale|happ'
$routeAdapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
$adapter = $routeAdapter
$gateway = $route.NextHop
$viaVpn = $routeAdapter -and (("$($routeAdapter.Name) $($routeAdapter.InterfaceDescription)") -match $vpnPattern)
if ($viaVpn -or !$adapter) {
    # Inspect the real Wi-Fi/Ethernet card underneath the tunnel.
    $defaultRoutes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
    $physical = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
    $pick = @($physical | Where-Object { $defaultRoutes.InterfaceIndex -contains $_.ifIndex }) + $physical | Select-Object -First 1
    if ($pick) {
        $adapter = $pick
        $gateway = ($defaultRoutes | Where-Object { $_.InterfaceIndex -eq $pick.ifIndex } | Select-Object -First 1).NextHop
    }
}
if (!$gateway -or $gateway -eq '0.0.0.0') { $gateway = $null }
$isWifi = $adapter -and ($adapter.PhysicalMediaType -match '802\.11' -or $adapter.NdisPhysicalMedium -eq 9)
$isUsb = $adapter -and ([string]$adapter.PnPDeviceID -like 'USB*')

if ($adapter) {
    Out-Line ('Adapter : {0} ({1})' -f $adapter.Name, $adapter.InterfaceDescription)
    Out-Line ('Type    : {0}{1}, link {2}' -f $(if ($isWifi) { 'Wi-Fi' } else { $adapter.PhysicalMediaType }), $(if ($isUsb) { ', USB adapter' } else { '' }), $adapter.LinkSpeed)
    Out-Line ('Driver  : {0} {1} ({2})' -f $adapter.DriverProvider, $adapter.DriverVersionString, $adapter.DriverDate)
}
Out-Line ('Router  : {0}' -f $(if ($gateway) { $gateway } else { 'not detected (PPPoE / VPN)' }))

if ($viaVpn) {
    Add-Finding 3 "Internet traffic goes through a VPN/tunnel adapter ($($routeAdapter.InterfaceDescription)). Every packet of the game travels to the VPN server and back, which adds its distance to your ping." 'Turn the VPN off while playing, or exclude RocketLeague.exe from it (split tunneling). zapret does not need a VPN.'
}
$otherVpn = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and !$viaVpn -and ("$($_.Name) $($_.InterfaceDescription)" -match $vpnPattern) })
foreach ($v in $otherVpn) {
    Add-Finding 1 "A VPN/tunnel adapter is connected: $($v.InterfaceDescription)." 'If game traffic is routed through it, ping rises. Disconnect it while playing to compare.'
}

if ($isWifi) {
    $wifi = Get-WifiInfo
    Out-Line ('Wi-Fi   : signal {0}%, {1}, channel {2}, {3} GHz' -f $wifi.Signal, $wifi.Radio, $wifi.Channel, $wifi.Band)
    Add-Finding 2 'The PC uses Wi-Fi. Wi-Fi shares the air with neighbours and other devices and causes ping spikes and packet loss in games.' 'Best fix of all: an Ethernet cable to the router. If impossible: 5 GHz network, router in line of sight, or a powerline/mesh adapter with Ethernet.'
    if ($wifi.Signal -and $wifi.Signal -lt 60) {
        Add-Finding 3 "Weak Wi-Fi signal ($($wifi.Signal)%). Weak signal means retransmissions: high and unstable ping." 'Move the router or PC closer, remove obstacles, put a USB Wi-Fi adapter on an extension cable on the desk.'
    } elseif ($wifi.Signal -and $wifi.Signal -lt 80) {
        Add-Finding 2 "Medium Wi-Fi signal ($($wifi.Signal)%)." 'Better placement of router/antenna will make ping more stable.'
    }
    if ($wifi.Band -eq '2.4') {
        Add-Finding 2 '2.4 GHz Wi-Fi band. It is crowded by neighbours, Bluetooth and USB 3.0 devices.' 'Connect to the 5 GHz network of your router (often named *_5G).'
    }
    if ($isUsb) {
        Add-Finding 2 'USB Wi-Fi adapter. Front-panel ports, hubs and nearby USB 3.0 devices (2.4 GHz noise) hurt it.' 'Plug it into a rear USB port on the motherboard, ideally through a USB extension cable placed on the desk, away from USB 3.0 drives.'
    }
} elseif ($adapter) {
    if ($adapter.FullDuplex -eq $false) {
        Add-Finding 3 'Ethernet link runs in HALF duplex. That causes collisions, packet loss and lag.' 'Replace the cable, try another router port; set Speed & Duplex to Auto in the adapter settings.'
    }
    if ($adapter.Speed -gt 0 -and $adapter.Speed -le 100000000) {
        $speedProp = Get-AdvProp $adapter.Name '*SpeedDuplex'
        if ($speedProp -and (($speedProp.ValidDisplayValues -join ' ') -match 'Gbps|1000')) {
            Add-Finding 2 "Ethernet connected at only $($adapter.LinkSpeed) although the network card supports 1 Gbps. Usually a damaged cable/plug (broken wire pair) or bad port." 'Try another cable (Cat5e or Cat6) and another router port. A damaged cable also causes packet errors.'
        }
    }
    if ($isUsb) {
        Add-Finding 1 'USB Ethernet adapter.' 'Use a rear USB 3.0 port directly on the motherboard, not a hub or front panel.'
    }
}

# Packet errors on the adapter since boot: bad cable, port, USB connection or driver.
if ($adapter) {
    $st = Get-NetAdapterStatistics -Name $adapter.Name -ErrorAction SilentlyContinue
    if ($st) {
        $packets = [double]$st.ReceivedUnicastPackets + $st.ReceivedBroadcastPackets + $st.ReceivedMulticastPackets + $st.SentUnicastPackets
        $errors = [double]$st.ReceivedPacketErrors + $st.OutboundPacketErrors
        Out-Line ('Errors  : {0} packet errors, {1} discarded since boot' -f $errors, ($st.ReceivedDiscardedPackets + $st.OutboundDiscardedPackets))
        if ($packets -gt 10000 -and $errors -gt 50 -and ($errors / $packets) -gt 0.001) {
            Add-Finding 3 ('The adapter reports {0} packet errors ({1:0.##}% of traffic). That means a bad cable/plug, bad port, loose USB connection or a faulty driver.' -f $errors, (100 * $errors / $packets)) 'Replace the cable / move the USB adapter to another rear port, then update the network driver from the motherboard or adapter maker.'
        }
    }
}

# Connection drops in the last 7 days (sleep and reboots count too).
$drops = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-NetworkProfile/Operational'; Id = 10001; StartTime = (Get-Date).AddDays(-7) } -ErrorAction SilentlyContinue).Count
Out-Line "Drops   : $drops network disconnects in the last 7 days"
if ($drops -ge 20) {
    Add-Finding 2 "The network disconnected $drops times in 7 days. Besides sleep/restarts this points to a loose cable or USB adapter, Wi-Fi dropouts or router reboots." 'Check plugs and USB connection, router power/overheating; see Event Viewer > NetworkProfile for times.'
}

# Devices with driver problems.
$badDevices = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.Status -in 'Error', 'Degraded', 'Unknown' -and $_.Class -in 'Net', 'USB' })
foreach ($d in $badDevices) {
    Add-Finding 2 "Device with a driver problem: $($d.FriendlyName) [$($d.Class)]." 'Open Device Manager, update or reinstall its driver; for USB devices try another port.'
}
if ($adapter -and $adapter.DriverProvider -eq 'Microsoft' -and $adapter.InterfaceDescription -match 'Realtek|Intel|Killer|MediaTek|Qualcomm|Broadcom') {
    Add-Finding 1 'The network card uses a generic Windows driver.' 'Install the latest driver from the motherboard/laptop maker or Realtek/Intel site.'
}

# Background traffic right now.
if ($adapter) {
    $s1 = Get-NetAdapterStatistics -Name $adapter.Name -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    $s2 = Get-NetAdapterStatistics -Name $adapter.Name -ErrorAction SilentlyContinue
    if ($s1 -and $s2) {
        $bgDown = (($s2.ReceivedBytes - $s1.ReceivedBytes) * 8 / 3 / 1e6)
        $bgUp = (($s2.SentBytes - $s1.SentBytes) * 8 / 3 / 1e6)
        Out-Line ('Traffic : {0:0.0} Mbit/s down, {1:0.0} Mbit/s up right now (should be ~0 when idle)' -f $bgDown, $bgUp)
        $hogNames = 'steam', 'EpicGamesLauncher', 'qbittorrent', 'utorrent', 'BitTorrent', 'transmission-qt', 'deluge', 'tixati', 'OneDrive', 'Dropbox', 'GoogleDriveFS', 'YandexDisk2', 'MEGAsync', 'Battle.net', 'EADesktop', 'upc', 'GalaxyClient', 'obs64'
        $hogs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $hogNames -contains $_.ProcessName } | Select-Object -ExpandProperty ProcessName -Unique)
        if ($bgDown -gt 2 -or $bgUp -gt 1) {
            $who = if ($hogs.Count) { ' Running now: ' + ($hogs -join ', ') + '.' } else { ' (Windows Update, browser, cloud sync?)' }
            Add-Finding 3 ('Something is using the internet while idle: {0:0.0} down / {1:0.0} up Mbit/s.{2}' -f $bgDown, $bgUp, $who) 'Pause downloads, torrents, cloud sync and updates while playing. Uploads hurt ping the most.'
        } elseif ($hogs.Count) {
            Add-Finding 1 ('Programs that may download/upload in the background are running: {0}.' -f ($hogs -join ', ')) 'Close them or pause their downloads while playing.'
        }
    }
}

# zapret settings that send more traffic through winws.
$gameFilterFile = Join-Path $utils 'game_filter.enabled'
if ((Test-Path -LiteralPath $gameFilterFile) -and ((Get-Content -LiteralPath $gameFilterFile -Raw) -match '(?im)^(mode=)?(all|udp|tcp)\s*$')) {
    Add-Finding 1 'zapret Game Filter is enabled: many game ports go through winws for every IPSet address.' 'Rocket League does not need it (it has its own rule). Turn it off in service.bat if nothing else needs it.'
}

# Power saving.
$scheme = Get-ActiveScheme
$planned = New-Object System.Collections.Generic.List[object]
foreach ($ps in $powerSettings) {
    if ($ps.WifiOnly -and !$isWifi) { continue }
    $v = if ($scheme) { Get-PowerValue $scheme $ps.Sub $ps.Setting } else { $null }
    if ($v -and ($v.AC -ne $ps.Want -or $v.DC -ne $ps.Want)) {
        $planned.Add([pscustomobject]@{ Kind = 'Power'; Name = $ps.Name; Scheme = $scheme; Sub = $ps.Sub; Setting = $ps.Setting; AC = $v.AC; DC = $v.DC; Want = $ps.Want })
    }
}
$pnpKey = $null
if ($adapter -and !(("$($adapter.Name) $($adapter.InterfaceDescription)") -match $vpnPattern)) {
    foreach ($as in $advancedSettings) {
        $prop = Get-AdvProp $adapter.Name $as.Keyword
        if ($prop -and (@($prop.ValidRegistryValues) -contains $as.Want) -and ([string](@($prop.RegistryValue)[0]) -ne $as.Want)) {
            $planned.Add([pscustomobject]@{ Kind = 'Advanced'; Name = $as.Name; Adapter = $adapter.Name; Keyword = $as.Keyword; Value = [string](@($prop.RegistryValue)[0]); Want = $as.Want })
        }
    }
    $pnpKey = Get-AdapterClassKey $adapter
    if ($pnpKey) {
        $cur = (Get-ItemProperty -LiteralPath $pnpKey -Name PnPCapabilities -ErrorAction SilentlyContinue).PnPCapabilities
        if ($null -eq $cur -or (([int]$cur -band 0x18) -ne 0x18)) {
            $planned.Add([pscustomobject]@{ Kind = 'PnP'; Name = 'Allow Windows to turn off the network adapter'; Adapter = $adapter.Name; Key = $pnpKey; Existed = ($null -ne $cur); Value = $cur })
        }
    }
}
if ($planned.Count) {
    Add-Finding 1 ('Power saving is active on: ' + (($planned | ForEach-Object { $_.Name } | Select-Object -Unique) -join '; ') + '. It can add delay spikes when the adapter wakes up.') 'Network Doctor can switch these off for you at the end (reversible).'
}

# --- 2. ping by segment ------------------------------------------------------
Out-Head 'Ping by segment (idle line)'
Out-Line 'Measuring, about 15 seconds...' 'DarkGray'
$ispHop = $null
$probe = New-Object System.Net.NetworkInformation.Ping
$buffer = New-Object byte[] 32
for ($ttl = 1; $ttl -le 6; $ttl++) {
    try { $reply = $probe.Send('77.88.8.8', 1000, $buffer, (New-Object System.Net.NetworkInformation.PingOptions($ttl, $true))) } catch { continue }
    if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { break }
    if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::TtlExpired -and $reply.Address) {
        $hop = $reply.Address.ToString()
        if ($hop -ne $gateway -and $hop -notlike '192.168.*') { $ispHop = $hop; break }
    }
}
$probe.Dispose()

$icmpTargets = New-Object System.Collections.Specialized.OrderedDictionary
if ($gateway) { $icmpTargets['Router'] = $gateway }
if ($ispHop) { $icmpTargets['ISP'] = $ispHop }
$icmpTargets['Moscow'] = '77.88.8.8'
$idle = Measure-Icmp $icmpTargets 50 250
$tcpMoscow = Measure-Tcp 'ya.ru'
$tcpFrankfurt = Measure-Tcp 'dynamodb.eu-central-1.amazonaws.com'
$tcpStockholm = Measure-Tcp 'dynamodb.eu-north-1.amazonaws.com'

if ($gateway) { Out-Line ('PC -> router ({0,-15}) {1}' -f $gateway, (Format-Stats $idle['Router'])) }
if ($ispHop) { Out-Line ('PC -> ISP    ({0,-15}) {1}' -f $ispHop, (Format-Stats $idle['ISP'])) }
Out-Line ('PC -> Moscow (Yandex)          {0}' -f (Format-Stats $idle['Moscow']))
Out-Line ('PC -> Moscow (TCP, ya.ru)      {0}' -f (Format-Stats $tcpMoscow -Tcp))
Out-Line ('PC -> Frankfurt (TCP, AWS)     {0}' -f (Format-Stats $tcpFrankfurt -Tcp))
Out-Line ('PC -> Stockholm (TCP, AWS)     {0}' -f (Format-Stats $tcpStockholm -Tcp))
Out-Line 'Rocket League EU servers are in Western Europe: the Frankfurt value is close to' 'DarkGray'
Out-Line 'the best in-game ping your connection can reach on the Europe region.' 'DarkGray'

$r = $idle['Router']; $i = $idle['ISP']; $m = $idle['Moscow']
if ($r -and $null -ne $r.Avg) {
    if ($r.Avg -gt 10 -or $r.Jitter -gt 5 -or $r.Loss -gt 1 -or $r.Max -gt 100) {
        Add-Finding 3 ('Lag starts INSIDE your home: PC -> router ping is {0} ms avg, {1} ms max, jitter {2}, loss {3}% (should be ~1-3 ms, no loss).' -f $r.Avg, $r.Max, $r.Jitter, $r.Loss) $(if ($isWifi) { 'Wi-Fi is the problem: use a cable, 5 GHz, better placement. Also check other devices on the network that download.' } else { 'Check the cable and the router (reboot it, check it is not overheating), and other devices that download.' })
    }
}
if ($i -and $null -ne $i.Avg -and $r -and $null -ne $r.Avg) {
    $delta = $i.Avg - $r.Avg
    if ($delta -gt 15 -or ($i.Loss -gt 2 -and $m -and $m.Loss -gt 2)) {
        Add-Finding 3 ('The ISP access line is slow/unstable: router -> ISP adds {0:0} ms (loss {1}%). Normal is under 5-10 ms.' -f $delta, $i.Loss) 'Reboot the router/ONT/modem. If it stays, call the ISP with this report (evening congestion is common).'
    }
}
if ($m -and $null -ne $m.Avg) {
    if ($m.Avg -gt 60) {
        Add-Finding 2 ("Ping to Moscow is $($m.Avg) ms. If you live in the Moscow/St Petersburg area this is too high and the ISP network is slow; if you are in the Urals/Siberia/Far East it is mostly distance.") 'Compare with another ISP or mobile internet at the same time of day.'
    }
    if ($m.Jitter -gt 10 -or $m.Loss -gt 2) {
        Add-Finding 2 ('Unstable ping to Moscow: jitter {0} ms, loss {1}%. Unstable ping feels laggier than high ping.' -f $m.Jitter, $m.Loss) 'If the router segment is clean, this is the ISP. Test again in the morning; if it is fine then, the ISP is congested in the evening.'
    }
}
if ($tcpFrankfurt -and $null -ne $tcpFrankfurt.Median -and $tcpMoscow -and $null -ne $tcpMoscow.Median) {
    $eu = $tcpFrankfurt.Median - $tcpMoscow.Median
    if ($eu -gt 60) {
        Add-Finding 2 ('Route from your ISP to Europe is long: Moscow -> Frankfurt adds {0:0} ms (usually 30-45 ms). The ISP sends international traffic a long way round.' -f $eu) 'Nothing on the PC fixes routing. Options: another ISP, or ask the ISP support about the route to Europe (send the report).'
    }
    Add-Finding 1 ("Your line reaches Frankfurt in about $($tcpFrankfurt.Median) ms: that is roughly the best ping Rocket League EU servers can show on this connection.") 'If the game shows much more: select only the Europe region in Rocket League, turn VPNs off and watch the in-game network graph for packet loss.'
}
if ($m -and $m.Loss -ge 100 -and (!$tcpMoscow -or $null -eq $tcpMoscow.Median)) {
    Add-Finding 3 'No connection to Moscow test servers at all.' 'Check the internet connection, firewall or VPN.'
}

# --- 3. bufferbloat ----------------------------------------------------------
if (!$SkipLoadTest) {
    Out-Head 'Ping while the line is busy (bufferbloat)'
    $urls = 'https://speedtest.selectel.ru/1GB', 'https://mirror.yandex.ru/ubuntu/ls-lR.gz', 'https://speed.cloudflare.com/__down?bytes=1000000000'
    $url = $null
    foreach ($u in $urls) {
        $code = & curl.exe --silent --ssl-no-revoke --noproxy '*' --range 0-99999 --max-time 6 --output NUL --write-out '%{http_code}' $u
        if ($code -match '^(200|206)$') { $url = $u; break }
    }
    if (!$url) {
        Out-Line 'Skipped: no speed-test server reachable.' 'Yellow'
    } else {
        Out-Line "Downloading from $(([uri]$url).Host) for ~12 s and pinging meanwhile..." 'DarkGray'
        $temp = [IO.Path]::GetTempPath()
        $procs = @()
        $outs = @()
        for ($n = 0; $n -lt 4; $n++) {
            $outFile = Join-Path $temp ("netdoctor-$PID-$n.txt")
            $outs += $outFile
            $procs += Start-Process -FilePath 'curl.exe' -NoNewWindow -PassThru -RedirectStandardOutput $outFile `
                -ArgumentList @('--silent', '--ssl-no-revoke', '--noproxy', '*', '--max-time', '12', '--output', 'NUL', '--write-out', '"%{size_download} %{time_total}"', ('"' + $url + '"'))
        }
        Start-Sleep -Seconds 2
        $loadTargets = New-Object System.Collections.Specialized.OrderedDictionary
        if ($gateway) { $loadTargets['Router'] = $gateway }
        $loadTargets['Moscow'] = '77.88.8.8'
        $loaded = Measure-Icmp $loadTargets 30 250
        $procs | Wait-Process -Timeout 20 -ErrorAction SilentlyContinue
        $procs | Where-Object { !$_.HasExited } | Stop-Process -Force -ErrorAction SilentlyContinue
        $bytes = 0.0; $secs = 0.1
        foreach ($f in $outs) {
            $parts = ([string](Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue)).Trim() -split '\s+'
            if ($parts.Count -ge 2) {
                $bytes += [double]$parts[0]
                $t = 0.0
                if ([double]::TryParse($parts[1], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$t)) { $secs = [Math]::Max($secs, $t) }
            }
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        }
        $mbps = $bytes * 8 / $secs / 1e6
        Out-Line ('Download speed: {0:0} Mbit/s' -f $mbps)
        if ($gateway) { Out-Line ('PC -> router under load: {0}' -f (Format-Stats $loaded['Router'])) }
        Out-Line ('PC -> Moscow under load: {0}' -f (Format-Stats $loaded['Moscow']))
        $lm = $loaded['Moscow']
        if ($lm -and $null -ne $lm.Avg -and $m -and $null -ne $m.Avg) {
            $rise = $lm.Avg - $m.Avg
            Out-Line ('Ping rise under load: +{0:0} ms (good: under 20 ms)' -f $rise)
            $lr = $loaded['Router']
            $localRise = if ($lr -and $null -ne $lr.Avg -and $r -and $null -ne $r.Avg) { $lr.Avg - $r.Avg } else { 0 }
            if ($rise -gt 20) {
                $sev = if ($rise -gt 60) { 3 } else { 2 }
                if ($localRise -gt [Math]::Max(15, $rise / 2)) {
                    Add-Finding $sev ('When something downloads, ping rises by {0:0} ms and most of it is between PC and router: the Wi-Fi/local link gets saturated.' -f $rise) 'Use a cable or 5 GHz, and make sure nobody else at home downloads/streams while you play.'
                } else {
                    Add-Finding $sev ('Bufferbloat: when anything downloads (Steam, updates, someone else at home), ping rises by {0:0} ms.' -f $rise) 'Enable SQM / Smart QoS / "gaming" QoS in the router settings, or limit download speeds (Steam, torrents) to ~80% of the line. Avoid downloads while playing.'
                }
            }
            if ($mbps -gt 0 -and $mbps -lt 10) {
                Add-Finding 2 ('Low internet speed ({0:0} Mbit/s). Any background download fills the line and raises ping.' -f $mbps) 'Check your tariff; avoid downloads while playing.'
            }
        }
    }
}

# zapret note.
if (Get-Process -Name winws -ErrorAction SilentlyContinue) {
    Out-Line ''
    Out-Line 'zapret is running. It only touches the first packets of each Rocket League' 'DarkGray'
    Out-Line 'UDP flow (cutoff d4), so it does not add ping during a match.' 'DarkGray'
}

# --- 4. verdict -----------------------------------------------------------------
Out-Head 'Result'
$sorted = @($findings | Sort-Object Severity -Descending)
if ($sorted.Count -eq 0) {
    Out-Line 'No problems found on the PC or the line. If the game still lags, check the' 'Green'
    Out-Line 'Rocket League region (Europe) and the in-game network graph.' 'Green'
} else {
    $labels = @{ 3 = 'MAJOR'; 2 = 'LIKELY'; 1 = 'MINOR' }
    $colors = @{ 3 = 'Red'; 2 = 'Yellow'; 1 = 'Gray' }
    $n = 0
    foreach ($f in $sorted) {
        $n++
        Out-Line ('{0}. [{1}] {2}' -f $n, $labels[$f.Severity], $f.Problem) $colors[$f.Severity]
        Out-Line ('   Fix: {0}' -f $f.Fix) 'DarkGray'
    }
}

New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
$reportFile = Join-Path $resultsDir ('network-doctor-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
$report | Set-Content -LiteralPath $reportFile -Encoding UTF8
Write-Host ''
Write-Host "Report saved: $reportFile" -ForegroundColor DarkGray
Write-Host 'Run it in the evening and in the morning: if only the evening is bad, the ISP is congested.' -ForegroundColor DarkGray

# --- 5. fixes ----------------------------------------------------------------------
if ($NoFix -or $planned.Count -eq 0) {
    if ($planned.Count -eq 0) { Write-Host 'No power-saving settings left to fix on this PC.' -ForegroundColor DarkGray }
    exit 0
}
Write-Host ''
Write-Host 'Safe fixes available (turn off network power saving, undo any time with Network Doctor option 2):' -ForegroundColor Cyan
foreach ($p in $planned) { Write-Host "  - $($p.Name)" }
if (@($planned | Where-Object Kind -eq 'Advanced').Count) {
    Write-Host 'The network adapter will restart: internet drops for ~5-10 seconds.' -ForegroundColor Yellow
}
$answer = Read-Host 'Apply them now? [Y/N]'
if ($answer -notmatch '^[Yy]') { exit 0 }

# Keep the ORIGINAL values if fixes were already applied earlier.
$backup = [pscustomobject]@{ Power = @(); Advanced = @(); PnP = @() }
if (Test-Path -LiteralPath $backupFile) {
    try {
        $old = Get-Content -LiteralPath $backupFile -Raw | ConvertFrom-Json
        $backup = [pscustomobject]@{ Power = @($old.Power); Advanced = @($old.Advanced); PnP = @($old.PnP) }
    } catch {}
}
$restartAdapter = $false
foreach ($p in $planned) {
    try {
        switch ($p.Kind) {
            'Power' {
                if (!(@($backup.Power) | Where-Object { $_.Scheme -eq $p.Scheme -and $_.Setting -eq $p.Setting })) {
                    $backup.Power = @($backup.Power) + [pscustomobject]@{ Name = $p.Name; Scheme = $p.Scheme; Sub = $p.Sub; Setting = $p.Setting; AC = $p.AC; DC = $p.DC }
                }
                Set-PowerValue $p.Scheme $p.Sub $p.Setting $p.Want $p.Want
            }
            'Advanced' {
                if (!(@($backup.Advanced) | Where-Object { $_.Adapter -eq $p.Adapter -and $_.Keyword -eq $p.Keyword })) {
                    $backup.Advanced = @($backup.Advanced) + [pscustomobject]@{ Name = $p.Name; Adapter = $p.Adapter; Keyword = $p.Keyword; Value = $p.Value }
                }
                Set-AdvProp $p.Adapter $p.Keyword $p.Want
                $restartAdapter = $true
            }
            'PnP' {
                if (!(@($backup.PnP) | Where-Object { $_.Key -eq $p.Key })) {
                    $backup.PnP = @($backup.PnP) + [pscustomobject]@{ Adapter = $p.Adapter; Key = $p.Key; Existed = $p.Existed; Value = $p.Value }
                }
                # 0x18: Windows may not turn the device off to save power.
                $value = if ($p.Existed) { [int]$p.Value -bor 0x18 } else { 0x18 }
                Set-ItemProperty -LiteralPath $p.Key -Name PnPCapabilities -Value $value -Type DWord
            }
        }
        Write-Host "  done: $($p.Name)" -ForegroundColor Green
    } catch {
        Write-Host "  failed: $($p.Name) ($($_.Exception.Message))" -ForegroundColor Yellow
    }
    # Save after every change so an interrupted run can still be undone.
    $backup | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $backupFile -Encoding UTF8
}
if (@($planned | Where-Object Kind -eq 'Power').Count) { & powercfg.exe /setactive $scheme | Out-Null }
if ($restartAdapter) {
    Write-Host "Restarting adapter $($adapter.Name)..."
    Restart-NetAdapter -Name $adapter.Name -ErrorAction SilentlyContinue
}
Write-Host 'Fixes applied. Reboot the PC to finish, then run Network Doctor again to compare.' -ForegroundColor Green
exit 0
