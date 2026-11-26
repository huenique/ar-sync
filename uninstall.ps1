# uninstall.ps1 - remove Aronium Sync from THIS laptop (current user).
#   powershell -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\AroniumSync\uninstall.ps1"
#
# Removes: scheduled tasks, the aronium-sync: link, desktop shortcuts, scripts, sqlite3.exe,
#          config, state, sync.log, the pause file, and the BurntToast module (current user).
# Keeps:   %LOCALAPPDATA%\AroniumSync\backups (old pos.db copies), Aronium's own pos.db,
#          and everything in the shared OneDrive folder (latest.db, history\).
param([switch]$KeepBurntToast)
$ErrorActionPreference = 'Stop'
$app = Join-Path $env:LOCALAPPDATA 'AroniumSync'

foreach ($n in @('AroniumSync Publish', 'AroniumSync Check')) {
    Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue
}
$key = 'HKCU:\Software\Classes\aronium-sync'
if (Test-Path $key) { Remove-Item -Path $key -Recurse -Force }

$desk = [Environment]::GetFolderPath('Desktop')
foreach ($n in @('Aronium Sync - Take over.lnk', 'Aronium Sync - Clear pause.lnk')) {
    $p = Join-Path $desk $n
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
}

if (Test-Path -LiteralPath $app) {
    Get-ChildItem -LiteralPath $app -Force | Where-Object { $_.Name -ne 'backups' } | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if (-not $KeepBurntToast -and (Get-Module -ListAvailable -Name BurntToast)) {
    Uninstall-Module -Name BurntToast -AllVersions -Force -ErrorAction SilentlyContinue
}

Write-Host 'Aronium Sync removed. Backups kept in:'
Write-Host "  $(Join-Path $app 'backups')"
