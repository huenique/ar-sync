# install.ps1 - set up Aronium Sync on THIS laptop, for the current Windows user. No admin needed.
#
#   Selling laptop:  powershell -ExecutionPolicy Bypass -File install.ps1 -Role seller
#   Viewing laptop:  powershell -ExecutionPolicy Bypass -File install.ps1 -Role reader
#
# What it does:
#   1. Copies the scripts to %LOCALAPPDATA%\AroniumSync
#   2. Installs BurntToast 1.1.0 (toasts) for this user from the PowerShell Gallery
#   3. Downloads sqlite3.exe 3.54.1 from sqlite.org and checks its hash
#   4. Writes config.json (asks for anything it cannot detect)
#   5. Registers the aronium-sync: link used by toast buttons (HKCU only)
#   6. Registers the scheduled task: publish every 15 min (seller) or check every 5 min (reader)
#   7. Puts "Aronium Sync - Clear pause" (and on the reader "Aronium Sync - Take over") on the desktop
#
# -AroniumProcessName: the name Get-Process shows for Aronium (default: the exe file name).
#   It is checked against the running Aronium; leave Aronium open during install to verify it.
# -Force: become the seller even if OneDrive has newer data from the other laptop (see README).
# To switch an installed laptop between seller and reader, use set-role.ps1 instead.
param(
    [Parameter(Mandatory)][ValidateSet('seller', 'reader')][string]$Role,
    [string]$OneDriveFolder,
    [string]$DbPath,
    [string]$AroniumExe,
    [string]$AroniumProcessName,
    [string]$OwnerContact,
    [string]$ShopOpen,
    [string]$ShopClose,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$app = Join-Path $env:LOCALAPPDATA 'AroniumSync'

function Read-Default {
    param([string]$Prompt, [string]$Default)
    $v = Read-Host ("{0} [{1}]" -f $Prompt, $Default)
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default } else { return $v.Trim().Trim('"') }
}

function Find-AroniumExe {
    # Unverified on a real install: looks for Aronium*.exe under the usual install folders.
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA 'Programs'), $env:LOCALAPPDATA) |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    $found = @()
    foreach ($r in $roots) {
        foreach ($d in Get-ChildItem -LiteralPath $r -Directory -Filter '*Aronium*' -ErrorAction SilentlyContinue) {
            if ($d.FullName -eq $app) { continue }
            $found += Get-ChildItem -LiteralPath $d.FullName -Filter '*.exe' -File -Recurse -Depth 2 -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like 'Aronium*.exe' -and $_.Name -notmatch 'unins|update|setup|install' }
        }
    }
    return @($found | Sort-Object FullName -Unique)
}

Write-Host "Installing Aronium Sync ($Role) for $env:USERNAME ..."

# 1. scripts
New-Item -ItemType Directory -Force -Path $app, (Join-Path $app 'bin'), (Join-Path $app 'backups'), (Join-Path $app 'state') | Out-Null
foreach ($f in @('AroniumSync.psm1', 'publish.ps1', 'check.ps1', 'takeover.ps1', 'update-now.ps1', 'protocol-handler.ps1',
        'clear-pause.ps1', 'set-role.ps1', 'uninstall.ps1', 'README.md', 'VERIFY.md')) {
    $p = Join-Path $src $f
    if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination $app -Force }
}
Get-ChildItem -LiteralPath $app -File | Unblock-File
Import-Module (Join-Path $app 'AroniumSync.psm1') -Force

# 2. BurntToast (MIT), current user only
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
if (-not (Get-Module -ListAvailable -Name BurntToast | Where-Object { $_.Version -eq [version]'1.1.0' })) {
    Write-Host 'Installing BurntToast 1.1.0 (current user) ...'
    if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue | Where-Object { $_.Version -ge [version]'2.8.5.201' })) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
    }
    Install-Module -Name BurntToast -RequiredVersion 1.1.0 -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
}

# 3. sqlite3.exe, pinned version, hash-checked
$sqlite = Join-Path $app 'bin\sqlite3.exe'
if (-not (Test-Path -LiteralPath $sqlite)) {
    Write-Host 'Downloading sqlite3.exe from sqlite.org ...'
    Install-PinnedSqlite -DestinationDir (Join-Path $app 'bin')
}

# 4. config.json (kept if it already exists, except for the role)
$cfgPath = Join-Path $app 'config.json'
if (Test-Path -LiteralPath $cfgPath) {
    Write-Host "Keeping existing $cfgPath"
    $cfg = Get-SyncConfig -Path $cfgPath
    if ($AroniumProcessName) { Set-SyncConfigField -Config $cfg -Name 'aroniumProcessName' -Value $AroniumProcessName }
} else {
    $od = $env:OneDrive; if (-not $od) { $od = $env:OneDriveConsumer }; if (-not $od) { $od = $env:OneDriveCommercial }
    if (-not $OneDriveFolder) {
        $def = if ($od) { Join-Path $od 'aronium' } else { '' }
        $OneDriveFolder = Read-Default 'Shared OneDrive folder for the copies (same OneDrive account on both laptops)' $def
    }
    if (-not $DbPath) {
        $def = Join-Path $env:LOCALAPPDATA 'Aronium\Data\pos.db'
        if (-not (Test-Path -LiteralPath $def)) { Write-Warning "Aronium database not found at $def" }
        $DbPath = Read-Default 'Aronium database (pos.db)' $def
    }
    if (-not $AroniumExe) {
        $c = Find-AroniumExe
        if ($c.Count -eq 1) { $AroniumExe = $c[0].FullName; Write-Host "Found Aronium: $AroniumExe" }
        else {
            if ($c.Count -gt 1) { Write-Host 'Several candidates:'; $c | ForEach-Object { Write-Host "  $($_.FullName)" } }
            $AroniumExe = Read-Default 'Full path to Aronium .exe (leave empty to skip relaunching)' $(if ($c.Count -gt 0) { $c[0].FullName } else { '' })
        }
    }
    $procName = if ($AroniumProcessName) { $AroniumProcessName }
    elseif ($AroniumExe) { [IO.Path]::GetFileNameWithoutExtension($AroniumExe) } else { 'Aronium' }
    if (-not $OwnerContact) { $OwnerContact = Read-Default 'Who to call when something is wrong (shown in alerts)' 'the owner' }
    if (-not $ShopOpen) { $ShopOpen = Read-Default 'Shop opens at (HH:MM)' '08:00' }
    if (-not $ShopClose) { $ShopClose = Read-Default 'Shop closes at (HH:MM)' '21:00' }
    $obj = [ordered]@{
        role               = 'reader'
        oneDriveFolder     = $OneDriveFolder
        dbPath             = $DbPath
        aroniumExe         = $AroniumExe
        aroniumProcessName = $procName
        shopHours          = [ordered]@{ open = $ShopOpen; close = $ShopClose; days = @('Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun') }
        staleMinutes       = 60
        ownerContact       = $OwnerContact
        historyDays        = 30
        keepBackups        = 10
    }
    [IO.File]::WriteAllText($cfgPath, ($obj | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
    $cfg = Get-SyncConfig -Path $cfgPath
}

# shared folder; keep it downloaded on this PC (not an online-only placeholder)
$share = Get-SharePaths -Config $cfg
New-Item -ItemType Directory -Force -Path $share.Dir, $share.History | Out-Null
try { & attrib.exe +P -U "$($share.Dir)" /S /D 2>&1 | Out-Null } catch { Write-Warning 'Could not pin the OneDrive folder; set "Always keep on this device" by hand.' }

# The restore guard looks for Aronium by this process name (and by exe path): check it now.
$pn = Test-AroniumProcessName -Config $cfg
switch ($pn.Status) {
    'ok' { Write-Host "Aronium is running as '$($cfg.aroniumProcessName)': process name OK." }
    'mismatch' {
        throw ("Aronium is running as '{0}', but the process name is set to '{1}'. Run install again with -AroniumProcessName {0}" -f ($pn.Names -join "', '"), $cfg.aroniumProcessName)
    }
    default {
        Write-Host ''
        Write-Warning ("COULD NOT CHECK the Aronium process name '{0}': Aronium is not running." -f $cfg.aroniumProcessName)
        Write-Warning 'Open Aronium and run:  Get-Process | Where-Object { $_.Path -like ''*Aronium*'' } | Select-Object ProcessName, Path'
        Write-Warning 'If ProcessName is different, run install again with -AroniumProcessName <that name>.'
        Write-Host ''
    }
}

if ($Role -eq 'seller') {
    if (-not $Force) {
        $block = Get-SellerSwitchBlock -Config $cfg
        if ($block) { throw "Install stopped. $block" }
        $w = Read-JsonFile $share.WriterJson
        if ($w -and $w.host -and $w.host -ne $env:COMPUTERNAME) {
            $ans = Read-Host "OneDrive says '$($w.host)' is the selling laptop. Make THIS laptop the seller instead? (y/N)"
            if ($ans -notmatch '^[yY]') { throw 'Install stopped: another laptop is the selling laptop. Install this one as reader, or use Take over.' }
        }
    }
    Set-WriterClaim -Config $cfg
} else {
    # Whatever is in this laptop's pos.db now is not counted as "sales made here".
    Set-BaselineStamp -Config $cfg
}
Set-SyncConfigRole -Config $cfg -Role $Role

# 5. toast button link, 6. scheduled task
Register-SyncProtocol -HandlerScript (Join-Path $app 'protocol-handler.ps1')
Register-SyncTasks -Config $cfg -Role $Role

# 7. desktop shortcuts
Set-SyncShortcuts -Config $cfg -Role $Role

Write-SyncLog -Config $cfg -Message "Installed as $Role."
Show-SyncToast -Config $cfg -Kind 'install' -Text ("Aronium Sync is set up. This laptop is the {0} laptop." -f $(if ($Role -eq 'seller') { 'selling' } else { 'viewing' }))
if ($Role -eq 'seller') { Write-Host 'Running a first publish ...'; Write-Host (Invoke-Publish -Config $cfg) }
else { Write-Host 'Running a first check ...'; Write-Host (Invoke-Check -Config $cfg) }
Write-Host "Done. Log: $($cfg.logPath)"
