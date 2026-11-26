# protocol-handler.ps1 - runs when a toast button (aronium-sync:<action>) is clicked.
# Only update-now, later and takeover are accepted; anything else is logged and ignored.
# The argument is never passed to a shell or evaluated.
param([string]$Uri)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AroniumSync.psm1') -Force
$cfg = Get-SyncConfig -Path (Join-Path $PSScriptRoot 'config.json')
try { [void](Invoke-ProtocolAction -Config $cfg -Uri $Uri) }
catch { Write-SyncLog -Config $cfg -Level ERROR -Message ('Protocol handler failed: ' + $_.Exception.Message) }
