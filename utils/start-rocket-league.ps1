param([string]$Strategy = 'general (ALT9-RL).bat')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$file = Get-ChildItem -LiteralPath $root -Filter 'general*.bat' | Where-Object Name -eq $Strategy | Select-Object -First 1
if (!$file) { throw 'Select an existing general*.bat strategy from this folder.' }
if (Get-Process winws -ErrorAction SilentlyContinue) { throw 'Zapret is already running. Close its window or stop its service before switching strategies.' }
$service = Get-Service zapret -ErrorAction SilentlyContinue
if ($service -and $service.Status -eq 'Running') { throw 'The zapret service is already running. Stop it before starting another strategy.' }
# WinDivert requires administrator rights. Windows displays its usual UAC prompt.
Start-Process -FilePath $env:ComSpec -ArgumentList ('/d /c ""' + $file.FullName + '""') -WorkingDirectory $root -Verb RunAs -WindowStyle Hidden
for ($attempt = 0; $attempt -lt 15; $attempt++) {
    Start-Sleep -Seconds 1
    if (Get-Process winws -ErrorAction SilentlyContinue) {
        Write-Host "Running $($file.Name). Restart Rocket League to test login."
        exit 0
    }
}
throw 'winws did not stay running. Check the zapret window for its error.'
