# clear-pause.ps1 - lift a sync pause after the sales made on this laptop have been dealt with.
# Same as deleting SYNC-PAUSED.txt. On the next check the main laptop's copy replaces this
# laptop's data; the old file is kept in the backups folder.
param([string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'))
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AroniumSync.psm1') -Force
$cfg = Get-SyncConfig -Path $ConfigPath
if (Test-Path -LiteralPath $cfg.pauseFlag) {
    Remove-Item -LiteralPath $cfg.pauseFlag -Force
    Write-SyncLog -Config $cfg -Message 'Pause cleared with clear-pause.ps1.'
    Write-Host 'Sync pause cleared. The next check (within 5 minutes) will load the main laptop''s copy.'
} else {
    Write-Host 'Sync is not paused.'
}
