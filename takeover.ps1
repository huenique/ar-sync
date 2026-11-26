# takeover.ps1 - make THIS laptop the selling laptop (the main one is down).
# Asks Yes/No first. Restores the newest copy if safe, bumps receipt counters by 500,
# writes writer.json, switches this laptop to the seller role and scheduled task.
param([string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'))
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AroniumSync.psm1') -Force
$cfg = Get-SyncConfig -Path $ConfigPath
$r = Invoke-Takeover -Config $cfg
if ($r -eq 'failed') { exit 1 }
exit 0
