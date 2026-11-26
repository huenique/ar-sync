# set-role.ps1 - switch THIS laptop between selling and viewing without uninstalling.
# No downloads: keeps BurntToast, sqlite3.exe, config.json and the backups.
#
#   Viewing laptop:  powershell -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\AroniumSync\set-role.ps1" -Role reader
#   Selling laptop:  powershell -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\AroniumSync\set-role.ps1" -Role seller
#
# -Role seller refuses if OneDrive holds newer data from the other laptop, or if the other laptop is
# the seller; to give the selling role back, see "Give the selling role back" in README.md.
# -Force skips those checks.
param(
    [Parameter(Mandatory)][ValidateSet('seller', 'reader')][string]$Role,
    [switch]$Force,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AroniumSync.psm1') -Force
$cfg = Get-SyncConfig -Path $ConfigPath
$r = Set-SyncRole -Config $cfg -Role $Role -Force:$Force
Write-Host $r.Message
if ($r.Status -in @('refused', 'busy')) { exit 1 }
exit 0
