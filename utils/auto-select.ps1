# Finds the zapret strategy (general*.bat) that works best on this provider.
# Every strategy is started in turn and real HTTPS downloads are made to
# Discord (most important), YouTube and Rocket League/Epic. The winner is saved
# to utils\rl-strategy.txt (used by "Rocket League.cmd") and started.
#
# Full pages are downloaded, not just headers: Russian DPI often lets a TLS
# connection open and then freezes it after 16-20 KB. A frozen download hits
# the time limit and counts as a failure.
#
# Windows 10 1803+ / Windows 11, Windows PowerShell 5.1. Run as administrator.
[CmdletBinding()]
param(
    [switch]$NoStart,
    [ValidateRange(3, 30)][int]$TimeoutSeconds = 7
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$strategyFile = Join-Path $PSScriptRoot 'rl-strategy.txt'
$resultsDir = Join-Path $PSScriptRoot 'test results'

# Weight = how much a working target adds to a strategy's score.
$targets = @(
    [pscustomobject]@{ Group = 'Discord'; Name = 'discord.com';         Url = 'https://discord.com/';                      Weight = 4 }
    [pscustomobject]@{ Group = 'Discord'; Name = 'discord.com/app';     Url = 'https://discord.com/app';                   Weight = 3 }
    [pscustomobject]@{ Group = 'Discord'; Name = 'discord API';         Url = 'https://discord.com/api/v9/gateway';        Weight = 3 }
    [pscustomobject]@{ Group = 'Discord'; Name = 'gateway.discord.gg';  Url = 'https://gateway.discord.gg/';               Weight = 3 }
    [pscustomobject]@{ Group = 'Discord'; Name = 'cdn.discordapp.com';  Url = 'https://cdn.discordapp.com/';               Weight = 3 }
    [pscustomobject]@{ Group = 'Discord'; Name = 'updates.discord.com'; Url = 'https://updates.discord.com/';              Weight = 2 }
    [pscustomobject]@{ Group = 'YouTube'; Name = 'www.youtube.com';     Url = 'https://www.youtube.com/';                  Weight = 1 }
    [pscustomobject]@{ Group = 'YouTube'; Name = 'i.ytimg.com';         Url = 'https://i.ytimg.com/vi/aqz-KE-bpKQ/hqdefault.jpg'; Weight = 1 }
    [pscustomobject]@{ Group = 'RL';      Name = 'psynet (RL)';         Url = 'https://api.rlpp.psynet.gg/';               Weight = 1 }
    [pscustomobject]@{ Group = 'RL';      Name = 'epicgames.com';       Url = 'https://www.epicgames.com/';                Weight = 1 }
)
$discordTotal = @($targets | Where-Object Group -eq 'Discord').Count

# Runs in a separate runspace, one per target, all in parallel.
$probe = {
    param($url, $timeout)
    # --ssl-no-revoke: Windows curl (Schannel) otherwise fails when certificate
    # revocation servers are blocked, which would look like a broken strategy.
    $out = & curl.exe --silent --ssl-no-revoke --noproxy '*' `
        --connect-timeout ([Math]::Min(4, $timeout)) --max-time $timeout `
        --user-agent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' `
        --output NUL --write-out '%{http_code} %{size_download} %{time_total}' $url 2>$null
    $exit = $LASTEXITCODE
    $parts = (@($out) -join '').Trim() -split '\s+'
    $code = 0; $bytes = 0; $time = 0.0
    if ($parts.Count -ge 3) {
        [void][int]::TryParse($parts[0], [ref]$code)
        [void][long]::TryParse($parts[1], [ref]$bytes)
        [void][double]::TryParse($parts[2], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$time)
    }
    [pscustomobject]@{ Ok = ($exit -eq 0 -and $code -ge 100); Exit = $exit; Code = $code; Bytes = $bytes; Time = $time }
}

function Invoke-Probes {
    $pool = [runspacefactory]::CreateRunspacePool(1, $targets.Count)
    $pool.Open()
    $jobs = foreach ($t in $targets) {
        $ps = [powershell]::Create().AddScript($probe).AddArgument($t.Url).AddArgument($TimeoutSeconds)
        $ps.RunspacePool = $pool
        [pscustomobject]@{ Target = $t; PS = $ps; Handle = $ps.BeginInvoke() }
    }
    $results = foreach ($j in $jobs) {
        $r = $null
        try {
            if ($j.Handle.AsyncWaitHandle.WaitOne(($TimeoutSeconds + 10) * 1000)) {
                $r = @($j.PS.EndInvoke($j.Handle))[0]
            } else {
                $j.PS.Stop()
            }
        } catch {}
        $j.PS.Dispose()
        if (!$r) { $r = [pscustomobject]@{ Ok = $false; Exit = -1; Code = 0; Bytes = 0; Time = 0.0 } }
        [pscustomobject]@{ Target = $j.Target; Ok = [bool]$r.Ok; Exit = $r.Exit; Code = $r.Code; Bytes = $r.Bytes; Time = $r.Time }
    }
    $pool.Close()
    $pool.Dispose()
    return @($results)
}

function Measure-Results($results) {
    $ok = @($results | Where-Object Ok)
    [pscustomobject]@{
        DiscordOk = @($ok | Where-Object { $_.Target.Group -eq 'Discord' }).Count
        Points    = [int](($ok | ForEach-Object { $_.Target.Weight } | Measure-Object -Sum).Sum)
        Time      = [double](($ok | ForEach-Object { $_.Time } | Measure-Object -Sum).Sum)
        Summary   = (@('Discord', 'YouTube', 'RL') | ForEach-Object {
                        $g = $_
                        $all = @($results | Where-Object { $_.Target.Group -eq $g })
                        '{0} {1}/{2}' -f $g, @($all | Where-Object Ok).Count, $all.Count
                    }) -join '  '
        Failed    = @($results | Where-Object { !$_.Ok } | ForEach-Object { $_.Target.Name })
    }
}

function Stop-Winws {
    Get-Process -Name winws -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 30 -and (Get-Process -Name winws -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 100 }
}

function Start-Strategy($file) {
    Stop-Winws
    $env:NO_UPDATE_CHECK = '1'
    # cmd /c ""path"" keeps quoting intact for names with spaces and brackets.
    Start-Process -FilePath $env:ComSpec -ArgumentList ('/d /c ""' + $file.FullName + '""') `
        -WorkingDirectory $root -WindowStyle Hidden | Out-Null
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 200
        if (Get-Process -Name winws -ErrorAction SilentlyContinue) {
            # A strategy with bad arguments exits right after starting.
            Start-Sleep -Milliseconds 1500
            return [bool](Get-Process -Name winws -ErrorAction SilentlyContinue)
        }
    }
    return $false
}

function Write-Row($name, $m) {
    $color = if ($m.DiscordOk -eq $discordTotal) { 'Green' } elseif ($m.DiscordOk -gt 0) { 'Yellow' } else { 'Red' }
    Write-Host ('  {0,-34} {1}' -f $name, $m.Summary) -ForegroundColor $color
}

# --- checks ----------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Run this as administrator (use "Auto Select Strategy.cmd").' -ForegroundColor Red
    exit 1
}
if (!(Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    Write-Host 'curl.exe was not found. Update Windows 10 to version 1803 or newer.' -ForegroundColor Red
    exit 1
}
$service = Get-Service -Name zapret -ErrorAction SilentlyContinue
if ($service -and $service.Status -ne 'Stopped') {
    Write-Host 'The zapret Windows service is running. Remove it in service.bat ("Remove Services") first.' -ForegroundColor Red
    exit 1
}

$files = @(Get-ChildItem -LiteralPath $root -Filter 'general*.bat' |
    Where-Object { $_.Extension -eq '.bat' } |
    Sort-Object { [regex]::Replace($_.Name, '\d+', { $args[0].Value.PadLeft(8, '0') }) })
if ($files.Count -eq 0) { Write-Host 'No general*.bat strategies found.' -ForegroundColor Red; exit 1 }

$current = $null
if (Test-Path -LiteralPath $strategyFile) { $current = (Get-Content -LiteralPath $strategyFile -TotalCount 1) }

Write-Host ''
Write-Host "Testing $($files.Count) strategies. This takes a few minutes - do not close this window." -ForegroundColor Cyan
Write-Host 'Small zapret windows will flash in the taskbar; that is expected.' -ForegroundColor DarkGray
Write-Host ''

# --- baseline (no zapret) -----------------------------------------------------
Stop-Winws
$baseline = Measure-Results (Invoke-Probes)
Write-Row '(without zapret)' $baseline
Write-Host ''

# --- round 1: every strategy ------------------------------------------------------
$scores = @{}
$index = 0
foreach ($file in $files) {
    $index++
    Write-Host ('[{0,2}/{1}]' -f $index, $files.Count) -NoNewline -ForegroundColor DarkGray
    if (!(Start-Strategy $file)) {
        Write-Host ('  {0,-34} did not start' -f $file.Name) -ForegroundColor DarkGray
        continue
    }
    $m = Measure-Results (Invoke-Probes)
    Write-Row $file.Name $m
    $scores[$file.Name] = [pscustomobject]@{
        File = $file; DiscordOk = $m.DiscordOk; Points = $m.Points; Time = $m.Time
        Rounds = 1; Summary = $m.Summary; Failed = $m.Failed
    }
}
Stop-Winws

function Get-Ranking {
    @($scores.Values | Sort-Object `
        @{ Expression = { $_.DiscordOk / $_.Rounds }; Descending = $true }, `
        @{ Expression = { $_.Points / $_.Rounds }; Descending = $true }, `
        @{ Expression = { $_.File.Name -eq $current }; Descending = $true }, `
        @{ Expression = { $_.Time / $_.Rounds }; Descending = $false })
}

$ranking = Get-Ranking
if ($ranking.Count -eq 0 -or $ranking[0].Points -eq 0) {
    Write-Host ''
    Write-Host 'No strategy could reach the test sites. Check the internet connection,' -ForegroundColor Red
    Write-Host 'close VPNs / other bypass tools and run service.bat - Run Diagnostics.' -ForegroundColor Red
    exit 2
}

# --- round 2: re-test the top 3 so a lucky single run does not win -------------
Write-Host ''
Write-Host 'Re-checking the best candidates...' -ForegroundColor Cyan
foreach ($entry in @($ranking | Select-Object -First 3)) {
    if (!(Start-Strategy $entry.File)) { $entry.Rounds++; continue }
    $m = Measure-Results (Invoke-Probes)
    Write-Row $entry.File.Name $m
    $entry.DiscordOk += $m.DiscordOk; $entry.Points += $m.Points; $entry.Time += $m.Time; $entry.Rounds++
    $entry.Failed = @($entry.Failed + $m.Failed | Select-Object -Unique)
}
Stop-Winws
$ranking = Get-Ranking
$best = $ranking[0]

# --- result ----------------------------------------------------------------------
Write-Host ''
Write-Host 'Top strategies:' -ForegroundColor Cyan
foreach ($entry in @($ranking | Select-Object -First 5)) {
    Write-Host ('  {0,-34} Discord {1:0.#}/{2}  score {3:0.#}  ({4} run(s))' -f $entry.File.Name,
        ($entry.DiscordOk / $entry.Rounds), $discordTotal, ($entry.Points / $entry.Rounds), $entry.Rounds)
}

New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
$report = Join-Path $resultsDir ('auto-select-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
$lines = @("Auto-select $(Get-Date -Format 'yyyy-MM-dd HH:mm')", "Without zapret: $($baseline.Summary)", '')
$lines += $ranking | ForEach-Object {
    '{0,-34} Discord {1:0.#}/{2}  score {3:0.#}  runs {4}  failed: {5}' -f $_.File.Name,
        ($_.DiscordOk / $_.Rounds), $discordTotal, ($_.Points / $_.Rounds), $_.Rounds, ($_.Failed -join ', ')
}
$lines += '', "Selected: $($best.File.Name)"
$lines | Set-Content -LiteralPath $report -Encoding UTF8

Set-Content -LiteralPath $strategyFile -Value $best.File.Name -Encoding ASCII
Write-Host ''
Write-Host "Selected: $($best.File.Name)" -ForegroundColor Green
if (($best.DiscordOk / $best.Rounds) -lt $discordTotal) {
    Write-Host "Not every Discord check passed even with the best strategy: $($best.Failed -join ', ')" -ForegroundColor Yellow
}
if ($baseline.DiscordOk -eq $discordTotal) {
    Write-Host 'Note: Discord websites also opened WITHOUT zapret on this connection.' -ForegroundColor DarkGray
}
Write-Host 'Discord VOICE (UDP) cannot be tested automatically. If voice hangs on' -ForegroundColor DarkGray
Write-Host '"RTC Connecting", switch the Discord voice fake in Rocket League.cmd.' -ForegroundColor DarkGray
Write-Host "Report: $report" -ForegroundColor DarkGray

if (!$NoStart) {
    if (Start-Strategy $best.File) {
        Write-Host "zapret is running with $($best.File.Name). Restart Discord and Rocket League." -ForegroundColor Green
    } else {
        Write-Host "$($best.File.Name) did not stay running. Run it as administrator to see the error." -ForegroundColor Red
        exit 1
    }
}
exit 0
