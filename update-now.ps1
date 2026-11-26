# update-now.ps1 - close Aronium politely, load the newest copy, reopen Aronium.
# Never force-kills Aronium. Same as the "Update now" toast button.
param([string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'))
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AroniumSync.psm1') -Force
$cfg = Get-SyncConfig -Path $ConfigPath
[void](Invoke-UpdateNow -Config $cfg)
