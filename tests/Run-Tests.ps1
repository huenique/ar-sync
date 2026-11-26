# Run the test suite under Windows PowerShell 5.1:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
# Needs Pester 5 (Install-Module Pester -Scope CurrentUser -MinimumVersion 5.0 -SkipPublisherCheck)
# and tools\sqlite3.exe (downloaded here, pinned and hash-checked, if missing).
# If fixtures\real.db exists (a gitignored copy of a real backup), every DB test also runs on it.
param([string]$Output = 'Detailed')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module Pester -MinimumVersion 5.0 -Force
Import-Module (Join-Path $root 'AroniumSync.psm1') -Force
if (-not (Test-Path (Join-Path $root 'tools\sqlite3.exe'))) { Install-PinnedSqlite -DestinationDir (Join-Path $root 'tools') }
$cfg = New-PesterConfiguration
$cfg.Run.Path = $PSScriptRoot
$cfg.Run.Exit = $true
$cfg.Output.Verbosity = $Output
Invoke-Pester -Configuration $cfg
