# Safe deploy + launch. Never copies while FS25 is up or still shutting down.
param([string]$Expect, [string]$Zip)
# Paths default to the standard locations; override with -Zip and $env:FS25_PROFILE.
$staged = $(if ($Zip) { $Zip } else { Join-Path $PSScriptRoot 'FS25_ADFlyoverEditor.zip' })
$fs25   = $(if ($env:FS25_PROFILE) { $env:FS25_PROFILE } else { Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'My Games\FarmingSimulator2025' })
$dest   = Join-Path $fs25 'mods\FS25_ADFlyoverEditor.zip'
$log    = Join-Path $fs25 'log.txt'
function Up { [bool](Get-Process | Where-Object { $_.ProcessName -match '^FarmingSimulator' }) }
if (Up) { Write-Output 'FS25 is running - waiting for it to exit (nothing is copied until it has)'; while (Up) { Start-Sleep 3 } }
# and until its log has been quiet for 10 s, so a game that is still shutting down is not swapped under
while (((Get-Date) - (Get-Item $log).LastWriteTime).TotalSeconds -lt 10) { Start-Sleep 2 }
if (Up) { Write-Output 'FS25 came back up - aborting'; exit 1 }
Copy-Item -LiteralPath $staged -Destination $dest -Force
if ((Get-FileHash $staged).Hash -ne (Get-FileHash $dest).Hash) { Write-Output 'HASH MISMATCH - deploy failed'; exit 1 }
Write-Output 'deployed, hash verified'
$before = (Get-Item $log).LastWriteTime
Start-Process 'steam://rungameid/2300320'
$ok = $false
for ($i = 0; $i -lt 24; $i++) { Start-Sleep 5; if (Up) { $ok = $true; break } }
if (-not $ok) { Write-Output 'LAUNCH FAILED: no FS25 process after 120 s'; exit 1 }
Write-Output "FS25 process is up: pid $((Get-Process | Where-Object { $_.ProcessName -match '^FarmingSimulator' })[0].Id)"
for ($i = 0; $i -lt 24; $i++) {
  Start-Sleep 5
  if ((Get-Item $log).LastWriteTime -gt $before) {
    # Verified from P.BUILD, not the modDesc version. modDesc is the RELEASE number and stays put
    # across dev builds, so it cannot tell one from the next - and it is read at game startup only,
    # so it can be stale while the Lua is current. P.BUILD lives in Prelude.lua, which FS25 re-sources
    # every load, so it always describes the code actually running. It is also the only one of the two
    # that would catch a stale source() of the editor files.
    $m = Select-String -Path $log -Pattern 'ARMED \(build ([^\s)]+)' | Select-Object -Last 1
    if ($m) { $v = $m.Matches[0].Groups[1].Value; Write-Output "game armed build $v"; if ($Expect -and $v -notlike "$Expect*") { Write-Output "WRONG BUILD - expected $Expect"; exit 1 }; exit 0 }
  }
}
Write-Output 'process is up but the log has not listed the mod yet'
