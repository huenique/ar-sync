# uninstall.ps1 - remove Aronium Sync from THIS laptop (current user).
#   powershell -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\AroniumSync\uninstall.ps1"
#
# Removes: scheduled tasks, the aronium-sync: link, desktop shortcuts, scripts,
#          config, state, sync.log and the pause file.
# Keeps:   %LOCALAPPDATA%\AroniumSync\backups (old pos.db copies), Aronium's own pos.db,
#          everything in the shared OneDrive folder (latest.db, history\), and the two
#          downloads (bin\sqlite3.exe and the BurntToast module) so a reinstall works offline.
# -Purge:  also removes bin\sqlite3.exe and the BurntToast module (current user).
#
# To switch between selling and viewing laptop, use set-role.ps1 instead of uninstalling.
param([switch]$Purge)
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

$keep = @('backups')
if (-not $Purge) { $keep += 'bin' }
if (Test-Path -LiteralPath $app) {
    Get-ChildItem -LiteralPath $app -Force | Where-Object { $keep -notcontains $_.Name } | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($Purge -and (Get-Module -ListAvailable -Name BurntToast)) {
    Uninstall-Module -Name BurntToast -AllVersions -Force -ErrorAction SilentlyContinue
}

Write-Host 'Aronium Sync removed. Backups kept in:'
Write-Host "  $(Join-Path $app 'backups')"
if (-not $Purge) { Write-Host 'sqlite3.exe and BurntToast kept for a reinstall (use -Purge to remove them).' }
