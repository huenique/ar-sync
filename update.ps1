# update.ps1 - update Aronium Sync from the published GitHub releases of huenique/ar-sync.
# Run by Task Scheduler daily at 03:00 and 10 minutes after logon. Never runs during a sync step.
#
#   Newest release:      powershell -ExecutionPolicy Bypass -File update.ps1
#   One exact release:   powershell -ExecutionPolicy Bypass -File update.ps1 -Version v1.2.0
#                        (pins it: scheduled runs leave it alone; also how to roll back)
#   Follow releases again after a pin:  update.ps1 -Unpin
#
# Set "autoUpdate": false in config.json to stop the scheduled checks.
param(
    [string]$Version,
    [switch]$Unpin,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AroniumSync.psm1') -Force
$cfg = Get-SyncConfig -Path $ConfigPath
$r = Invoke-SelfUpdate -Config $cfg -AppDir $PSScriptRoot -Version $Version -Unpin:$Unpin
Write-Host "Update: $r"
if ($r -eq 'failed') { exit 1 }
exit 0
