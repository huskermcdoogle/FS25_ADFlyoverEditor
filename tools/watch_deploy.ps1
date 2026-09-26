# Wait for Farming Simulator 25 to close, then build the mod from this checkout, install it and relaunch.
#
#   powershell -ExecutionPolicy Bypass -File tools\watch_deploy.ps1
#
# Building happens AFTER the game closes, so whatever is committed or on disk by then is what ships.
# Never copy the zip while the game runs: FS25 holds the archive open and a hot swap breaks the next
# load of the editor files.

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$zip = Join-Path $env:TEMP "FS25_ADFlyoverEditor.zip"
$mods = Join-Path $env:USERPROFILE "OneDrive\Documents\My Games\FarmingSimulator2025\mods"
if (-not (Test-Path $mods)) { $mods = Join-Path $env:USERPROFILE "Documents\My Games\FarmingSimulator2025\mods" }

# Armed right after a launch, the game may not be up yet - wait for it to START first (up to 5
# minutes), or this would see "not running" and build and launch a second copy straight away.
$waited = 0
while (-not (Get-Process FarmingSimulator2025Game -ErrorAction SilentlyContinue)) {
    if ($waited -ge 300) { Write-Output "game never started - not deploying"; exit 1 }
    Start-Sleep -Seconds 2
    $waited += 2
}
Write-Output "watching: waiting for FarmingSimulator2025Game to close"
while (Get-Process FarmingSimulator2025Game -ErrorAction SilentlyContinue) { Start-Sleep -Seconds 2 }
Write-Output "game closed - building"
Start-Sleep -Seconds 3   # let the game release the archive

Push-Location $repo
try {
    $out = & python tools/build_zip.py $zip 2>&1
    $out | Select-Object -Last 2 | ForEach-Object { Write-Output "build: $_" }
    if ($LASTEXITCODE -ne 0) { Write-Output "BUILD FAILED - not deploying"; exit 1 }
} finally { Pop-Location }

Copy-Item $zip (Join-Path $mods "FS25_ADFlyoverEditor.zip") -Force
Write-Output "installed - launching"
Start-Process "steam://rungameid/2300320"
Write-Output "launched"
