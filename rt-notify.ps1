# rt-notify.ps1 - called by the real-time sync sidecar (arsync-rt) to show a toast
# or restart Aronium. Kind is validated (lowercase letters and dashes); Text is shown as-is.
param([Parameter(Mandatory)][string]$Kind, [string]$Text = '', [string]$Buttons = '')
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AroniumSync.psm1') -Force
$cfg = Get-SyncConfig -Path (Join-Path $PSScriptRoot 'config.json')
try {
    $b = @($Buttons.Split(',') | Where-Object { $_ })
    [void](Invoke-RtNotify -Config $cfg -Kind $Kind -Text $Text -Buttons $b)
} catch {
    Write-SyncLog -Config $cfg -Level ERROR -Message ('rt-notify failed: ' + $_.Exception.Message)
    exit 1
}
