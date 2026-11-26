# publish.ps1 - SELLING laptop. Run by Task Scheduler every 15 min (and at logon / shutdown).
# Backs up pos.db, checks it, and puts it in the OneDrive folder for the viewing laptop.
param([string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'))
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AroniumSync.psm1') -Force
$cfg = Get-SyncConfig -Path $ConfigPath
if ($cfg.role -ne 'seller') { Write-SyncLog -Config $cfg -Message 'publish.ps1 called but role is not seller; nothing to do.'; exit 0 }
$r = Invoke-Publish -Config $cfg
if ($r -eq 'failed') { exit 1 }
exit 0
