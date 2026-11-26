# check.ps1 - VIEWING laptop. Run by Task Scheduler every 5 min (and at logon).
# Pulls the newest copy from OneDrive if it is safe, or shows a toast saying why not.
param([string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'))
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AroniumSync.psm1') -Force
$cfg = Get-SyncConfig -Path $ConfigPath
if ($cfg.role -ne 'reader') { Write-SyncLog -Config $cfg -Message 'check.ps1 called but role is not reader; nothing to do.'; exit 0 }
$r = Invoke-Check -Config $cfg
if ($r -eq 'failed') { exit 1 }
exit 0
