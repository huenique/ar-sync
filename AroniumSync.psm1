# AroniumSync.psm1 - one-writer file sync for Aronium Lite between two laptops.
# Windows PowerShell 5.1. Keep this file ASCII-only (5.1 reads BOM-less files as ANSI).
#
# Shared (OneDrive) folder:  latest.db, latest.json, writer.json, history\
# Per-laptop folder (baseDir): config.json, state\, backups\, sync.log, SYNC-PAUSED.txt
#
# Every side effect that touches the desktop (toasts, the Aronium process, message boxes,
# scheduled tasks, the registry) goes through a small function so tests can mock it.

Set-StrictMode -Version 2.0

$script:FingerprintTables = @('Document', 'DocumentItem', 'Payment', 'Product', 'Customer', 'Stock', 'StartingCash', 'ZReport')
$script:PerPcTables = @('ApplicationProperty', 'PosPrinterSelection', 'PosPrinterSelectionSettings', 'PosPrinterSettings',
    'PrintStation', 'PrintStationPosPrinterSelection', 'SecurityKey')
$script:Actions = @('update-now', 'later', 'takeover')
$script:CounterBump = 500
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding $false

# ---------------------------------------------------------------- config / files / log

function Get-SyncConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Config not found: $Path" }
    $raw = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    $cfg = @{}
    foreach ($p in $raw.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
    $defaults = @{
        role               = 'reader'
        oneDriveFolder     = '%OneDrive%\aronium'
        dbPath             = '%LOCALAPPDATA%\Aronium\Data\pos.db'
        aroniumExe         = ''
        aroniumProcessName = 'Aronium'
        staleMinutes       = 60
        ownerContact       = 'the owner'
        historyDays        = 30
        keepBackups        = 10
        autoUpdate         = $true
        baseDir           = '%LOCALAPPDATA%\AroniumSync'
        mutexName          = 'Local\AroniumSync'
    }
    foreach ($k in $defaults.Keys) { if (-not $cfg.ContainsKey($k) -or $null -eq $cfg[$k]) { $cfg[$k] = $defaults[$k] } }
    if (-not $cfg.ContainsKey('shopHours') -or $null -eq $cfg['shopHours']) {
        $cfg['shopHours'] = [pscustomobject]@{ open = '08:00'; close = '21:00'; days = @('Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun') }
    }
    foreach ($k in @('oneDriveFolder', 'dbPath', 'aroniumExe', 'baseDir')) {
        $cfg[$k] = [Environment]::ExpandEnvironmentVariables([string]$cfg[$k])
    }
    $base = $cfg['baseDir']
    $derived = @{
        stateDir   = Join-Path $base 'state'
        backupDir  = Join-Path $base 'backups'
        logPath    = Join-Path $base 'sync.log'
        pauseFlag  = Join-Path $base 'SYNC-PAUSED.txt'
        sqlitePath = Join-Path $base 'bin\sqlite3.exe'
    }
    foreach ($k in $derived.Keys) {
        if (-not $cfg.ContainsKey($k) -or [string]::IsNullOrEmpty([string]$cfg[$k])) { $cfg[$k] = $derived[$k] }
        else { $cfg[$k] = [Environment]::ExpandEnvironmentVariables([string]$cfg[$k]) }
    }
    $cfg['configPath'] = (Resolve-Path -LiteralPath $Path).ProviderPath
    return $cfg
}

function Set-SyncConfigField {
    # Rewrites one top-level field, keeping the rest of config.json as the owner wrote it.
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Value)
    $raw = [IO.File]::ReadAllText($Config.configPath) | ConvertFrom-Json
    if ($raw.PSObject.Properties.Name -contains $Name) { $raw.$Name = $Value }
    else { $raw | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
    Write-FileAtomic -Path $Config.configPath -Text ($raw | ConvertTo-Json -Depth 5)
    $Config[$Name] = $Value
}

function Set-SyncConfigRole {
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][ValidateSet('seller', 'reader')][string]$Role)
    Set-SyncConfigField -Config $Config -Name 'role' -Value $Role
}

function Write-SyncLog {
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$Message, [string]$Level = 'INFO')
    try {
        $dir = Split-Path -Parent $Config.logPath
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $line = '{0} [{1}] {2} {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $env:COMPUTERNAME, $Level, $Message
        [IO.File]::AppendAllText($Config.logPath, $line + "`r`n", $script:Utf8NoBom)
    } catch { }
}

function Write-FileAtomic {
    # Write to a temp name in the same folder, then swap it in, so a reader never sees half a file.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp = Join-Path $dir ('.' + (Split-Path -Leaf $Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllText($tmp, $Text, $script:Utf8NoBom)
    Move-FileReplace -Source $tmp -Destination $Path
}

function Move-FileReplace {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)
    if (Test-Path -LiteralPath $Destination) { [IO.File]::Replace($Source, $Destination, [NullString]::Value) }
    else { [IO.File]::Move($Source, $Destination) }
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json) } catch { return $null }
}

function Write-JsonFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Object)
    Write-FileAtomic -Path $Path -Text ($Object | ConvertTo-Json -Depth 6)
}

function Get-SharePaths {
    param([Parameter(Mandatory)][hashtable]$Config)
    $s = $Config.oneDriveFolder
    return @{
        Dir        = $s
        LatestDb   = Join-Path $s 'latest.db'
        LatestJson = Join-Path $s 'latest.json'
        WriterJson = Join-Path $s 'writer.json'
        History    = Join-Path $s 'history'
    }
}

function Get-SyncState {
    param([Parameter(Mandatory)][hashtable]$Config)
    $o = Read-JsonFile (Join-Path $Config.stateDir 'state.json')
    $h = @{}
    if ($o) { foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value } }
    foreach ($k in @('notifiedSha', 'notifiedAt', 'laterSha', 'staleToastFor', 'pausedFingerprint', 'ackFingerprint', 'pausedToastAt', 'notWriterToastAt',
            'lastPublishedAt', 'supersededPublishedAt', 'updatePin')) {
        if (-not $h.ContainsKey($k)) { $h[$k] = $null }
    }
    return $h
}

function Save-SyncState {
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][hashtable]$State)
    Write-JsonFile -Path (Join-Path $Config.stateDir 'state.json') -Object ([pscustomobject]$State)
}

function Get-RestoreStamp {
    param([Parameter(Mandatory)][hashtable]$Config)
    return Read-JsonFile (Join-Path $Config.stateDir 'restore-stamp.json')
}

function Save-RestoreStamp {
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)]$Stamp)
    Write-JsonFile -Path (Join-Path $Config.stateDir 'restore-stamp.json') -Object $Stamp
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function ConvertTo-SyncTime {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTimeOffset]) { return $Value }
    if ($Value -is [datetime]) { return [DateTimeOffset]$Value }
    return [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture)
}

function Format-SyncTime {
    param([Parameter(Mandatory)][datetime]$Now)
    return ([DateTimeOffset]$Now).ToString('yyyy-MM-ddTHH:mm:sszzz', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-SyncMutex {
    # Returns an acquired mutex or $null if another sync step is running.
    param([Parameter(Mandatory)][hashtable]$Config, [int]$WaitSeconds = 0)
    $m = New-Object System.Threading.Mutex($false, $Config.mutexName)
    try {
        if ($m.WaitOne([TimeSpan]::FromSeconds($WaitSeconds))) { return $m }
    } catch [System.Threading.AbandonedMutexException] { return $m }
    $m.Dispose()
    return $null
}

function Exit-SyncMutex {
    param($Mutex)
    if ($Mutex) { try { $Mutex.ReleaseMutex() } catch { }; $Mutex.Dispose() }
}

# ---------------------------------------------------------------- sqlite

function Invoke-Sqlite {
    # Runs sqlite3.exe with the script on stdin (avoids PowerShell 5.1 argument-quoting bugs).
    # Returns stdout lines. Throws on a non-zero exit code or any stderr output.
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$Sql,
        [switch]$ReadOnly
    )
    if (-not (Test-Path -LiteralPath $Config.sqlitePath)) { throw "sqlite3.exe not found at $($Config.sqlitePath)" }
    if ($Database.Contains('"')) { throw 'Database path may not contain a double quote' }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Config.sqlitePath
    $flags = '-batch -bail -noheader -list'
    if ($ReadOnly) { $flags += ' -readonly' }
    $psi.Arguments = $flags + ' "' + $Database + '"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $script:Utf8NoBom
    $psi.StandardErrorEncoding = $script:Utf8NoBom
    # .NET Framework opens stdin with Console.InputEncoding; when that is UTF-8 (code page 65001,
    # e.g. launched from pwsh or with Windows' "Beta: UTF-8" setting) it writes a BOM first and
    # sqlite3 rejects the script. Force BOM-less UTF-8 for the duration of the start.
    $oldIn = $null
    try { $oldIn = [Console]::InputEncoding; [Console]::InputEncoding = $script:Utf8NoBom } catch { $oldIn = $null }
    try { $p = [System.Diagnostics.Process]::Start($psi) }
    finally { if ($oldIn) { try { [Console]::InputEncoding = $oldIn } catch { } } }
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $bytes = $script:Utf8NoBom.GetBytes(".timeout 5000`n" + $Sql + "`n")
    $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $p.StandardInput.BaseStream.Flush()
    $p.StandardInput.Close()
    $p.WaitForExit()
    $out = $outTask.Result
    $err = $errTask.Result
    $code = $p.ExitCode
    $p.Dispose()
    if ($code -ne 0 -or -not [string]::IsNullOrWhiteSpace($err)) {
        throw ("sqlite3 failed (exit {0}): {1}" -f $code, ($err.Trim() -replace '\s+', ' '))
    }
    return @($out -split "`r?`n" | Where-Object { $_ -ne '' })
}

function ConvertTo-SqlLiteral {
    param([Parameter(Mandatory)][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function ConvertTo-DotPath {
    # Path for a sqlite3 dot-command: forward slashes inside double quotes (no backslash escapes).
    param([Parameter(Mandatory)][string]$Path)
    if ($Path.Contains('"')) { throw 'Path may not contain a double quote' }
    return '"' + $Path.Replace('\', '/') + '"'
}

function Backup-SqliteDb {
    # Online backup of a live database. Safe while Aronium is open; retries if the DB is busy.
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination, [int]$Attempts = 3)
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force }
            Invoke-Sqlite -Config $Config -Database $Source -ReadOnly -Sql ('.backup ' + (ConvertTo-DotPath $Destination)) | Out-Null
            return
        } catch {
            if ($i -ge $Attempts -or $_.Exception.Message -notmatch 'locked|busy') { throw }
            Start-Sleep -Seconds 2
        }
    }
}

function Test-SqliteIntegrity {
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$Database)
    try {
        $r = @(Invoke-Sqlite -Config $Config -Database $Database -ReadOnly -Sql 'PRAGMA integrity_check;')
        return ($r.Count -eq 1 -and $r[0] -eq 'ok')
    } catch { return $false }
}

function Get-TableColumns {
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$Database, [Parameter(Mandatory)][string[]]$Tables)
    $list = ($Tables | ForEach-Object { ConvertTo-SqlLiteral $_ }) -join ','
    $sql = "SELECT m.name || '|' || p.name FROM sqlite_master m JOIN pragma_table_info(m.name) p WHERE m.type = 'table' AND m.name IN ($list) ORDER BY m.name, p.cid;"
    $cols = @{}
    foreach ($line in (Invoke-Sqlite -Config $Config -Database $Database -ReadOnly -Sql $sql)) {
        $t, $c = $line.Split('|', 2)
        if (-not $cols.ContainsKey($t)) { $cols[$t] = New-Object System.Collections.Generic.List[string] }
        $cols[$t].Add($c)
    }
    return $cols
}

function Get-DataFingerprint {
    # count + max(Id) + newest date for each sales/stock/master table. Per-PC tables are excluded.
    # Returns one canonical string, e.g. "Document=13810/14100/2025-01-14 05:59:01;DocumentItem=...".
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$Database)
    $cols = Get-TableColumns -Config $Config -Database $Database -Tables $script:FingerprintTables
    $parts = @()
    foreach ($t in $script:FingerprintTables) {
        if (-not $cols.ContainsKey($t)) { $parts += "SELECT '$t=missing'"; continue }
        $c = $cols[$t]
        $idExpr = if ($c.Contains('Id')) { "coalesce(max(Id), '')" } else { "''" }
        $dates = @(@('DateUpdated', 'DateCreated', 'Date') | Where-Object { $c.Contains($_) })
        if (@($dates).Count -eq 0) { $dateExpr = "''" }
        elseif (@($dates).Count -eq 1) { $dateExpr = "coalesce(max($($dates[0])), '')" }
        else { $dateExpr = "coalesce(max(max(" + ((@($dates) | ForEach-Object { "coalesce($_, '')" }) -join ', ') + ")), '')" }
        $parts += "SELECT '$t=' || count(*) || '/' || $idExpr || '/' || $dateExpr FROM [$t]"
    }
    $lines = Invoke-Sqlite -Config $Config -Database $Database -ReadOnly -Sql (($parts -join "`nUNION ALL`n") + ';')
    $map = @{}
    foreach ($l in $lines) { $k = $l.Split('=', 2)[0]; $map[$k] = $l }
    return (($script:FingerprintTables | ForEach-Object { $map[$_] }) -join ';')
}

# ---------------------------------------------------------------- desktop side effects (mocked in tests)

function Get-AroniumProcess {
    # Aronium processes in this session: by configured name, or by the configured exe path
    # (so a wrong process name in config.json does not hide a running Aronium).
    param([Parameter(Mandatory)][hashtable]$Config)
    $session = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    $found = @(Get-Process -Name $Config.aroniumProcessName -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session })
    if ($Config.aroniumExe) {
        foreach ($p in @(Get-Process -ErrorAction Stop | Where-Object { $_.SessionId -eq $session })) {
            $path = $null
            try { $path = $p.Path } catch { }
            if ($path -and $path -eq $Config.aroniumExe -and -not ($found | Where-Object { $_.Id -eq $p.Id })) { $found += $p }
        }
    }
    return $found
}

function Test-FileOpenElsewhere {
    # 'open' if another process holds the file (exclusive open fails with a sharing violation),
    # 'free' if not, 'unknown' if Windows would not say (e.g. no write access), 'missing' if absent.
    param([Parameter(Mandatory)][string]$Path, [ValidateSet('Read', 'ReadWrite')][string]$Access = 'ReadWrite')
    if (-not (Test-Path -LiteralPath $Path)) { return 'missing' }
    try {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]$Access, [IO.FileShare]::None)
        $fs.Dispose()
        return 'free'
    } catch {
        $e = $_.Exception
        while ($e.InnerException) { $e = $e.InnerException }
        if ($e -is [UnauthorizedAccessException]) { return 'unknown' }
        if ($e -is [IO.IOException]) { return 'open' }
        return 'unknown'
    }
}

function Get-AroniumRunningReason {
    # Fail-safe "is Aronium running?" for anything that replaces pos.db.
    # Returns $null only when every check says no; otherwise a short reason.
    param([Parameter(Mandatory)][hashtable]$Config)
    try {
        if (@(Get-AroniumProcess -Config $Config).Count -gt 0) { return 'process found' }
    } catch {
        return 'could not list processes (' + $_.Exception.Message + ')'
    }
    if ($Config.aroniumExe -and (Test-FileOpenElsewhere -Path $Config.aroniumExe) -eq 'open') {
        return 'the Aronium program file is in use'
    }
    if ((Test-FileOpenElsewhere -Path $Config.dbPath) -eq 'open') { return 'pos.db is open in another program' }
    return $null
}

function Test-AroniumProcessName {
    # Install-time check of aroniumProcessName against what is actually running.
    # Status: 'ok' (a live process has that name), 'mismatch' (Aronium runs under another name),
    # 'not-running' (nothing to compare against).
    param([Parameter(Mandatory)][hashtable]$Config)
    $session = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    $all = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session })
    if (@($all | Where-Object { $_.ProcessName -eq $Config.aroniumProcessName }).Count -gt 0) {
        return @{ Status = 'ok'; Names = @($Config.aroniumProcessName) }
    }
    $hits = @()
    foreach ($p in $all) {
        $path = $null
        try { $path = $p.Path } catch { }
        if (-not $path) { continue }
        if (($Config.aroniumExe -and $path -eq $Config.aroniumExe) -or ((Split-Path -Leaf $path) -like 'Aronium*')) { $hits += $p.ProcessName }
    }
    if ($hits.Count -gt 0) { return @{ Status = 'mismatch'; Names = @($hits | Sort-Object -Unique) } }
    return @{ Status = 'not-running'; Names = @() }
}

function Close-AroniumGracefully {
    # Asks Aronium to close (same as clicking X) and waits. NEVER force-kills: it may be mid-sale.
    param([Parameter(Mandatory)][hashtable]$Config, [int]$TimeoutSeconds = 30)
    $procs = @(Get-AroniumProcess -Config $Config)
    foreach ($p in $procs) { try { [void]$p.CloseMainWindow() } catch { } }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    foreach ($p in $procs) {
        $left = [int][Math]::Max(0, ($deadline - (Get-Date)).TotalMilliseconds)
        try { [void]$p.WaitForExit($left) } catch { }
    }
    return (@(Get-AroniumProcess -Config $Config).Count -eq 0)
}

function Start-Aronium {
    param([Parameter(Mandatory)][hashtable]$Config)
    if ($Config.aroniumExe -and (Test-Path -LiteralPath $Config.aroniumExe)) {
        # Aronium loads Lang\ (and other files) relative to its working directory. Started from
        # System32 or the script folder it shows raw keys like "Order.Subtotal", so start it in its own folder.
        Start-Process -FilePath $Config.aroniumExe -WorkingDirectory (Split-Path -Parent $Config.aroniumExe) | Out-Null
        return $true
    }
    Write-SyncLog -Config $Config -Level WARN -Message 'Aronium exe path not set or missing; not relaunching.'
    return $false
}

function Show-ConfirmBox {
    # Yes/No box, topmost, with No as the default button. Returns $true only on Yes.
    param([Parameter(Mandatory)][string]$Text)
    Add-Type -AssemblyName System.Windows.Forms
    $owner = New-Object System.Windows.Forms.Form
    $owner.TopMost = $true
    try {
        $r = [System.Windows.Forms.MessageBox]::Show($owner, $Text, 'Aronium Sync',
            [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
        return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
    } finally { $owner.Dispose() }
}

function Show-SyncToast {
    # Every toast is also written to sync.log (Focus Assist can hide toasts).
    # Kind doubles as the toast id, so a repeat replaces the old toast instead of stacking.
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Text,
        [string[]]$Buttons = @(),
        [switch]$Persistent
    )
    Write-SyncLog -Config $Config -Level TOAST -Message ("[{0}] {1}" -f $Kind, $Text)
    if (-not (Get-Module -ListAvailable -Name BurntToast)) {
        Write-SyncLog -Config $Config -Level WARN -Message 'BurntToast not installed; toast written to log only.'
        return
    }
    try {
        Import-Module BurntToast -ErrorAction Stop
        $texts = @((New-BTText -Text 'Aronium Sync'), (New-BTText -Text $Text))
        $binding = New-BTBinding -Children $texts
        $visual = New-BTVisual -BindingGeneric $binding
        $labels = @{ 'update-now' = 'Update now'; 'later' = 'Later'; 'takeover' = 'Take over' }
        $btns = @()
        foreach ($b in $Buttons) {
            if ($script:Actions -notcontains $b) { continue }
            $btns += New-BTButton -Content $labels[$b] -Arguments ('aronium-sync:' + $b) -ActivationType Protocol
        }
        # A Reminder toast stays on screen until dismissed, but Windows wants a button, so add Dismiss.
        if ($Persistent) { $btns += New-BTButton -Dismiss }
        $contentArgs = @{ Visual = $visual }
        if ($btns.Count -gt 0) { $contentArgs.Actions = New-BTAction -Buttons $btns }
        if ($Persistent) { $contentArgs.Scenario = 'Reminder' }
        $content = New-BTContent @contentArgs
        Submit-BTNotification -Content $content -UniqueIdentifier ('aronium-sync-' + $Kind)
    } catch {
        Write-SyncLog -Config $Config -Level WARN -Message ("Toast failed: " + $_.Exception.Message)
    }
}

# ---------------------------------------------------------------- shop hours

function Test-ShopHours {
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][datetime]$Now)
    $h = $Config.shopHours
    $day = $Now.DayOfWeek.ToString().Substring(0, 3)
    if (@($h.days) -notcontains $day) { return $false }
    $open = [TimeSpan]::Parse($h.open); $close = [TimeSpan]::Parse($h.close)
    $t = $Now.TimeOfDay
    return ($t -ge $open -and $t -lt $close)
}

# ---------------------------------------------------------------- publish (seller)

function Invoke-Publish {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [datetime]$Now = (Get-Date),
        [string]$HostName = $env:COMPUTERNAME
    )
    $mutex = Get-SyncMutex -Config $Config -WaitSeconds 60
    if (-not $mutex) { Write-SyncLog -Config $Config -Message 'Publish skipped: another sync step is running.'; return 'busy' }
    $share = Get-SharePaths -Config $Config
    $tmp = $null
    try {
        if (-not (Test-Path -LiteralPath (Split-Path -Parent $share.Dir))) {
            throw "OneDrive folder not found ($(Split-Path -Parent $share.Dir)). Is OneDrive signed in?"
        }
        foreach ($d in @($share.Dir, $share.History, $Config.stateDir)) {
            if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
        }

        # Only the writer publishes. After a takeover on the other laptop, this one must stop.
        $writer = Read-JsonFile $share.WriterJson
        if ($writer -and $writer.host -and $writer.host -ne $HostName) {
            Write-SyncLog -Config $Config -Level WARN -Message "Not publishing: writer is now $($writer.host)."
            Show-NotWriterToast -Config $Config -Now $Now
            return 'not-writer'
        }
        if (-not $writer) {
            Write-JsonFile -Path $share.WriterJson -Object ([pscustomobject]@{ host = $HostName; since = (Format-SyncTime $Now) })
        }
        # writer.json can arrive after latest.json (OneDrive syncs files in any order), e.g. when this
        # laptop boots after the other one took over. A copy from another laptop that is newer than
        # anything this laptop published or knowingly replaced means someone else is selling now.
        $current = Read-JsonFile $share.LatestJson
        if ($current -and $current.host -and $current.host -ne $HostName -and $current.published_at) {
            $state = Get-SyncState -Config $Config
            $floor = $null
            foreach ($t in @($state.lastPublishedAt, $state.supersededPublishedAt)) {
                $v = ConvertTo-SyncTime $t
                if ($v -and (-not $floor -or $v -gt $floor)) { $floor = $v }
            }
            if (-not $floor -or (ConvertTo-SyncTime $current.published_at) -gt $floor) {
                Write-SyncLog -Config $Config -Level WARN -Message ("Not publishing: latest.json is from {0} ({1}), newer than this laptop's last publish." -f $current.host, $current.published_at)
                Show-NotWriterToast -Config $Config -Now $Now
                return 'not-writer'
            }
        }

        if (-not (Test-Path -LiteralPath $Config.dbPath)) { throw "Aronium database not found at $($Config.dbPath)" }
        $tmp = Join-Path $Config.stateDir ('publish-' + [guid]::NewGuid().ToString('N') + '.db')
        Backup-SqliteDb -Config $Config -Source $Config.dbPath -Destination $tmp
        if (-not (Test-SqliteIntegrity -Config $Config -Database $tmp)) { throw 'integrity check failed on the backup copy' }
        $sha = Get-FileSha256 $tmp
        $fp = Get-DataFingerprint -Config $Config -Database $tmp

        $prev = Read-JsonFile $share.LatestJson
        $changed = (-not $prev) -or ($prev.sha256 -ne $sha) -or -not (Test-Path -LiteralPath $share.LatestDb)
        if ($changed) {
            $up = Join-Path $share.Dir ('.latest.db.' + [guid]::NewGuid().ToString('N') + '.uploading')
            Copy-Item -LiteralPath $tmp -Destination $up -Force
            Move-FileReplace -Source $up -Destination $share.LatestDb
            $hist = Join-Path $share.History ('pos-' + $Now.ToString('yyyyMMdd-HHmmss') + '.db')
            Copy-Item -LiteralPath $tmp -Destination $hist -Force
        }
        # latest.json is rewritten every run so readers can tell the seller is alive.
        Write-JsonFile -Path $share.LatestJson -Object ([pscustomobject]@{
                published_at = (Format-SyncTime $Now)
                host         = $HostName
                sha256       = $sha
                fingerprint  = $fp
                size         = (Get-Item -LiteralPath $tmp).Length
            })
        $state = Get-SyncState -Config $Config
        $state.lastPublishedAt = Format-SyncTime $Now
        Save-SyncState -Config $Config -State $state
        Remove-OldHistory -Config $Config -Now $Now
        Write-SyncLog -Config $Config -Message ("Published {0} (sha {1})" -f $(if ($changed) { 'new copy' } else { 'heartbeat, data unchanged' }), $sha.Substring(0, 12))
        return $(if ($changed) { 'published' } else { 'unchanged' })
    } catch {
        $reason = $_.Exception.Message
        if ($reason.Length -gt 150) { $reason = $reason.Substring(0, 150) + '...' }
        Write-SyncLog -Config $Config -Level ERROR -Message "Publish failed: $reason"
        Show-SyncToast -Config $Config -Kind 'publish-failed' -Text ("Backup failed at {0}: {1}" -f $Now.ToString('HH:mm'), $reason)
        return 'failed'
    } finally {
        if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        Exit-SyncMutex $mutex
    }
}

function Show-NotWriterToast {
    # At most once an hour.
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][datetime]$Now)
    $state = Get-SyncState -Config $Config
    $last = ConvertTo-SyncTime $state.notWriterToastAt
    if (-not $last -or ([DateTimeOffset]$Now - $last).TotalMinutes -ge 60) {
        Show-SyncToast -Config $Config -Kind 'not-writer' -Persistent -Text ("This laptop is no longer the selling laptop. Do not sell on it. Call {0}." -f $Config.ownerContact)
        $state.notWriterToastAt = Format-SyncTime $Now
        Save-SyncState -Config $Config -State $state
    }
}

function Set-WriterClaim {
    # Makes this laptop the writer in writer.json and remembers which published copy it replaced,
    # so its own first publish is not mistaken for an old seller waking up (see Invoke-Publish).
    param([Parameter(Mandatory)][hashtable]$Config, [datetime]$Now = (Get-Date), [string]$HostName = $env:COMPUTERNAME)
    $share = Get-SharePaths -Config $Config
    if (-not (Test-Path -LiteralPath $share.Dir)) { New-Item -ItemType Directory -Force -Path $share.Dir | Out-Null }
    $prev = Read-JsonFile $share.WriterJson
    $latest = Read-JsonFile $share.LatestJson
    Write-JsonFile -Path $share.WriterJson -Object ([pscustomobject]@{
            host          = $HostName
            since         = (Format-SyncTime $Now)
            previous_host = $(if ($prev -and $prev.host -ne $HostName) { $prev.host } else { $null })
        })
    $state = Get-SyncState -Config $Config
    $state.supersededPublishedAt = $null
    if ($latest -and $latest.published_at) {
        $state.supersededPublishedAt = (ConvertTo-SyncTime $latest.published_at).ToString('yyyy-MM-ddTHH:mm:sszzz', [Globalization.CultureInfo]::InvariantCulture)
    }
    $state.notWriterToastAt = $null
    Save-SyncState -Config $Config -State $state
}

function Get-SellerSwitchBlock {
    # Why this laptop must not become the seller, or $null. Blocks when OneDrive holds a copy from
    # another laptop with different data that is newer than this laptop's pos.db: publishing would
    # throw away that laptop's sales and roll receipt numbers back.
    param([Parameter(Mandatory)][hashtable]$Config, [string]$HostName = $env:COMPUTERNAME)
    $latest = Read-JsonFile (Get-SharePaths -Config $Config).LatestJson
    if (-not $latest -or -not $latest.host -or $latest.host -eq $HostName -or -not $latest.published_at) { return $null }
    if (-not (Test-Path -LiteralPath $Config.dbPath)) { return $null }
    if ($latest.fingerprint -and $latest.fingerprint -eq (Get-DataFingerprint -Config $Config -Database $Config.dbPath)) { return $null }
    $theirs = ConvertTo-SyncTime $latest.published_at
    $mine = [DateTimeOffset](Get-Item -LiteralPath $Config.dbPath).LastWriteTime
    if ($theirs -le $mine) { return $null }
    return ("OneDrive has a newer copy from {0} (published {1}) than this laptop's data (last changed {2}). " +
        "Making this laptop the seller would overwrite that laptop's sales. See 'Give the selling role back' in README.md, " +
        "or use -Force if you are sure.") -f $latest.host, $theirs.LocalDateTime.ToString('yyyy-MM-dd HH:mm'), $mine.LocalDateTime.ToString('yyyy-MM-dd HH:mm')
}

function Remove-OldHistory {
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][datetime]$Now)
    $share = Get-SharePaths -Config $Config
    if (-not (Test-Path -LiteralPath $share.History)) { return }
    $cutoff = $Now.AddDays( - [int]$Config.historyDays)
    foreach ($f in Get-ChildItem -LiteralPath $share.History -Filter 'pos-*.db' -File) {
        $m = [regex]::Match($f.Name, '^pos-(\d{8}-\d{6})\.db$')
        if (-not $m.Success) { continue }
        $when = [datetime]::ParseExact($m.Groups[1].Value, 'yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
        if ($when -lt $cutoff) { Remove-Item -LiteralPath $f.FullName -Force }
    }
}

# ---------------------------------------------------------------- divergence (reader)

function Set-BaselineStamp {
    # Used at install on the reader: "whatever is in pos.db now is not local sales".
    param([Parameter(Mandatory)][hashtable]$Config, [datetime]$Now = (Get-Date))
    if (-not (Test-Path -LiteralPath $Config.dbPath)) { return }
    Save-RestoreStamp -Config $Config -Stamp ([pscustomobject]@{
            kind        = 'baseline'
            sha256      = $null
            published_at = $null
            restored_at = (Format-SyncTime $Now)
            fingerprint = (Get-DataFingerprint -Config $Config -Database $Config.dbPath)
        })
}

function Test-Divergence {
    # Returns @{ Diverged = bool; Fingerprint = local fingerprint; Reason = text }.
    param([Parameter(Mandatory)][hashtable]$Config, $Latest)
    if (-not (Test-Path -LiteralPath $Config.dbPath)) { return @{ Diverged = $false; Fingerprint = $null; Reason = 'no local database' } }
    $fp = Get-DataFingerprint -Config $Config -Database $Config.dbPath
    $stamp = Get-RestoreStamp -Config $Config
    if ($stamp -and $stamp.fingerprint) {
        if ($stamp.fingerprint -eq $fp) { return @{ Diverged = $false; Fingerprint = $fp; Reason = 'matches last restore' } }
        return @{ Diverged = $true; Fingerprint = $fp; Reason = 'local data changed since last restore' }
    }
    # No stamp: only safe if local already equals the published copy.
    if ($Latest -and $Latest.fingerprint -eq $fp) { return @{ Diverged = $false; Fingerprint = $fp; Reason = 'matches published copy' } }
    return @{ Diverged = $true; Fingerprint = $fp; Reason = 'no restore stamp and local data differs from the published copy' }
}

function Test-SyncPaused {
    # Checks the pause flag and divergence. Pauses (flag + persistent toast) when needed.
    # Returns $true if sync must not touch pos.db this run.
    param([Parameter(Mandatory)][hashtable]$Config, $Latest, [datetime]$Now = (Get-Date))
    $state = Get-SyncState -Config $Config
    $msg = "Sales were recorded on this laptop. Sync is paused so they aren't lost. Call {0}." -f $Config.ownerContact
    if (Test-Path -LiteralPath $Config.pauseFlag) {
        $last = ConvertTo-SyncTime $state.pausedToastAt
        if (-not $last -or ([DateTimeOffset]$Now - $last).TotalMinutes -ge 60) {
            Show-SyncToast -Config $Config -Kind 'diverged' -Persistent -Text $msg
            $state.pausedToastAt = Format-SyncTime $Now
            Save-SyncState -Config $Config -State $state
        }
        Write-SyncLog -Config $Config -Message 'Sync paused (SYNC-PAUSED.txt present).'
        return $true
    }
    $d = Test-Divergence -Config $Config -Latest $Latest
    if (-not $d.Diverged) { return $false }

    # The flag was cleared by a person: accept the current local data as handled, once.
    if ($state.pausedFingerprint -and $state.pausedFingerprint -eq $d.Fingerprint) {
        $state.ackFingerprint = $d.Fingerprint
        $state.pausedFingerprint = $null
        Save-SyncState -Config $Config -State $state
        Write-SyncLog -Config $Config -Message 'Pause cleared by a person; next restore will replace local data (old file kept in backups).'
        return $false
    }
    if ($state.ackFingerprint -and $state.ackFingerprint -eq $d.Fingerprint) { return $false }

    $flagText = @(
        'Aronium Sync is PAUSED on this laptop.',
        ('Paused at: ' + $Now.ToString('yyyy-MM-dd HH:mm')),
        ('Reason: ' + $d.Reason + '.'),
        '',
        'Sales or changes were made in Aronium on this (viewing) laptop. If sync carried on,',
        'they would be overwritten by the main laptop''s copy.',
        '',
        'What to do:',
        ' 1. Write down or re-enter on the main laptop any sales made here.',
        ' 2. Delete this file (or run clear-pause.ps1). The next sync replaces this laptop''s',
        '    data with the main laptop''s copy. The old file is kept in the backups folder.'
    ) -join "`r`n"
    Write-FileAtomic -Path $Config.pauseFlag -Text $flagText
    $state.pausedFingerprint = $d.Fingerprint
    $state.ackFingerprint = $null
    $state.pausedToastAt = Format-SyncTime $Now
    Save-SyncState -Config $Config -State $state
    Write-SyncLog -Config $Config -Level WARN -Message ("Divergence: " + $d.Reason + '. Sync paused.')
    Show-SyncToast -Config $Config -Kind 'diverged' -Persistent -Text $msg
    return $true
}

# ---------------------------------------------------------------- restore

function Copy-PerPcTables {
    # Copies the per-PC tables from the old local DB into the incoming copy (printers, app id, keys).
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$Into)
    $oldCols = Get-TableColumns -Config $Config -Database $From -Tables $script:PerPcTables
    $newCols = Get-TableColumns -Config $Config -Database $Into -Tables $script:PerPcTables
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('ATTACH DATABASE ' + (ConvertTo-SqlLiteral $From) + ' AS old;')
    [void]$sb.AppendLine('BEGIN;')
    foreach ($t in $script:PerPcTables) {
        if (-not $newCols.ContainsKey($t) -or -not $oldCols.ContainsKey($t)) { continue }
        $common = @($newCols[$t] | Where-Object { $oldCols[$t].Contains($_) } | ForEach-Object { '[' + $_ + ']' })
        if ($common.Count -eq 0) { continue }
        $c = $common -join ', '
        [void]$sb.AppendLine("DELETE FROM main.[$t];")
        [void]$sb.AppendLine("INSERT INTO main.[$t] ($c) SELECT $c FROM old.[$t];")
    }
    [void]$sb.AppendLine('COMMIT;')
    [void]$sb.AppendLine('DETACH DATABASE old;')
    Invoke-Sqlite -Config $Config -Database $Into -Sql $sb.ToString() | Out-Null
}

function Invoke-Restore {
    # Swaps a verified copy of latest.db into pos.db. Callers check divergence first.
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$IncomingPath,
        [Parameter(Mandatory)][string]$ExpectedSha,
        $Latest,
        [datetime]$Now = (Get-Date)
    )
    $running = Get-AroniumRunningReason -Config $Config
    if ($running) { throw "Aronium is running ($running); restore refused." }
    foreach ($suffix in @('-journal', '-wal')) {
        if (Test-Path -LiteralPath ($Config.dbPath + $suffix)) { throw "pos.db$suffix exists (Aronium may have crashed mid-save); restore refused." }
    }
    if ((Get-FileSha256 $IncomingPath) -ne $ExpectedSha) { throw 'Incoming copy does not match latest.json sha256; restore refused.' }
    if (-not (Test-SqliteIntegrity -Config $Config -Database $IncomingPath)) { throw 'Incoming copy failed integrity check; restore refused.' }

    $dbDir = Split-Path -Parent $Config.dbPath
    if (-not (Test-Path -LiteralPath $dbDir)) { New-Item -ItemType Directory -Force -Path $dbDir | Out-Null }
    $work = $Config.dbPath + '.incoming'
    Copy-Item -LiteralPath $IncomingPath -Destination $work -Force
    (Get-Item -LiteralPath $work).IsReadOnly = $false
    try {
        $hadLocal = Test-Path -LiteralPath $Config.dbPath
        if ($hadLocal) {
            Copy-PerPcTables -Config $Config -From $Config.dbPath -Into $work
            if (-not (Test-SqliteIntegrity -Config $Config -Database $work)) { throw 'Merged copy failed integrity check; restore refused.' }
            if (-not (Test-Path -LiteralPath $Config.backupDir)) { New-Item -ItemType Directory -Force -Path $Config.backupDir | Out-Null }
            $bak = Join-Path $Config.backupDir ('pos-' + $Now.ToString('yyyyMMdd-HHmmss') + '.bak')
            Copy-Item -LiteralPath $Config.dbPath -Destination $bak -Force
            Remove-OldBackups -Config $Config
            Move-FileReplace -Source $work -Destination $Config.dbPath
        } else {
            [IO.File]::Move($work, $Config.dbPath)
        }
    } finally {
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Force -ErrorAction SilentlyContinue }
    }

    Save-RestoreStamp -Config $Config -Stamp ([pscustomobject]@{
            kind         = 'restore'
            sha256       = $ExpectedSha
            published_at = $(if ($Latest) { $Latest.published_at } else { $null })
            restored_at  = (Format-SyncTime $Now)
            fingerprint  = (Get-DataFingerprint -Config $Config -Database $Config.dbPath)
        })
    $state = Get-SyncState -Config $Config
    $state.ackFingerprint = $null; $state.pausedFingerprint = $null; $state.laterSha = $null; $state.notifiedSha = $null
    Save-SyncState -Config $Config -State $state
    Write-SyncLog -Config $Config -Message ("Restored copy {0} published {1}." -f $ExpectedSha.Substring(0, 12), $(if ($Latest) { $Latest.published_at } else { '?' }))
}

function Remove-OldBackups {
    param([Parameter(Mandatory)][hashtable]$Config)
    $all = @(Get-ChildItem -LiteralPath $Config.backupDir -Filter 'pos-*.bak' -File | Sort-Object Name -Descending)
    if ($all.Count -gt [int]$Config.keepBackups) {
        $all | Select-Object -Skip ([int]$Config.keepBackups) | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
    }
}

function Get-VerifiedIncoming {
    # Copies latest.db to a local temp file and checks it against latest.json.
    # Returns the temp path, or $null if OneDrive is still syncing (sha mismatch).
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)]$Latest)
    $share = Get-SharePaths -Config $Config
    if (-not (Test-Path -LiteralPath $share.LatestDb)) { return $null }
    if (-not (Test-Path -LiteralPath $Config.stateDir)) { New-Item -ItemType Directory -Force -Path $Config.stateDir | Out-Null }
    $tmp = Join-Path $Config.stateDir 'incoming.db'
    try { Copy-Item -LiteralPath $share.LatestDb -Destination $tmp -Force -ErrorAction Stop } catch { return $null }
    (Get-Item -LiteralPath $tmp).IsReadOnly = $false
    if ((Get-FileSha256 $tmp) -ne [string]$Latest.sha256) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return $null
    }
    return $tmp
}

# ---------------------------------------------------------------- check (reader, every 5 min)

function Invoke-Check {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [datetime]$Now = (Get-Date),
        [string]$HostName = $env:COMPUTERNAME
    )
    $mutex = Get-SyncMutex -Config $Config -WaitSeconds 0
    if (-not $mutex) { Write-SyncLog -Config $Config -Message 'Check skipped: another sync step is running.'; return 'busy' }
    $incoming = $null
    try {
        $share = Get-SharePaths -Config $Config
        $latest = Read-JsonFile $share.LatestJson

        if (Test-SyncPaused -Config $Config -Latest $latest -Now $Now) { return 'paused' }
        if (-not $latest -or -not $latest.sha256) { Write-SyncLog -Config $Config -Message 'No published copy yet (latest.json missing).'; return 'no-copy' }

        $state = Get-SyncState -Config $Config
        $published = ConvertTo-SyncTime $latest.published_at
        # Age counts from opening time at the earliest, so a seller that is simply not on yet
        # at opening does not raise the alarm straight away.
        $opened = [DateTimeOffset]($Now.Date + [TimeSpan]::Parse($Config.shopHours.open))
        $since = if ($published -gt $opened) { $published } else { $opened }
        $ageMin = ([DateTimeOffset]$Now - $since).TotalMinutes
        if ($ageMin -gt [double]$Config.staleMinutes -and (Test-ShopHours -Config $Config -Now $Now)) {
            if ($state.staleToastFor -ne [string]$latest.published_at) {
                $local = $published.LocalDateTime
                $when = if ($local.Date -eq $Now.Date) { $local.ToString('HH:mm') } else { $local.ToString('ddd HH:mm', [Globalization.CultureInfo]::InvariantCulture) }
                Show-SyncToast -Config $Config -Kind 'stale' -Buttons @('takeover') `
                    -Text ("Main laptop last synced at {0}. If it's down, use Take over." -f $when)
                $state.staleToastFor = [string]$latest.published_at
                Save-SyncState -Config $Config -State $state
            }
        }

        # A person cleared a pause (ackFingerprint set): restore even if the sha has not changed.
        $stamp = Get-RestoreStamp -Config $Config
        if ($stamp -and $stamp.sha256 -eq $latest.sha256 -and -not $state.ackFingerprint) { return 'up-to-date' }

        $incoming = Get-VerifiedIncoming -Config $Config -Latest $latest
        if (-not $incoming) {
            Write-SyncLog -Config $Config -Message 'latest.db does not match latest.json yet (OneDrive still syncing); will retry next run.'
            return 'waiting'
        }

        if (Get-AroniumRunningReason -Config $Config) {
            if ($state.laterSha -eq $latest.sha256) { return 'later' }
            $notifiedAt = ConvertTo-SyncTime $state.notifiedAt
            if ($state.notifiedSha -eq $latest.sha256 -and $notifiedAt -and ([DateTimeOffset]$Now - $notifiedAt).TotalMinutes -lt 60) { return 'notified' }
            Show-SyncToast -Config $Config -Kind 'update' -Buttons @('update-now', 'later') `
                -Text ("New data from the main laptop (as of {0}). Restart Aronium to see it." -f $published.LocalDateTime.ToString('HH:mm'))
            $state.notifiedSha = [string]$latest.sha256
            $state.notifiedAt = Format-SyncTime $Now
            Save-SyncState -Config $Config -State $state
            return 'notified'
        }

        Invoke-Restore -Config $Config -IncomingPath $incoming -ExpectedSha $latest.sha256 -Latest $latest -Now $Now
        return 'restored'
    } catch {
        Write-SyncLog -Config $Config -Level ERROR -Message ('Check failed: ' + $_.Exception.Message)
        return 'failed'
    } finally {
        if ($incoming -and (Test-Path -LiteralPath $incoming)) { Remove-Item -LiteralPath $incoming -Force -ErrorAction SilentlyContinue }
        Exit-SyncMutex $mutex
    }
}

# ---------------------------------------------------------------- toast actions

function Invoke-UpdateNow {
    param([Parameter(Mandatory)][hashtable]$Config, [datetime]$Now = (Get-Date))
    $mutex = Get-SyncMutex -Config $Config -WaitSeconds 60
    if (-not $mutex) { return 'busy' }
    $incoming = $null
    $relaunch = $false
    try {
        $share = Get-SharePaths -Config $Config
        $latest = Read-JsonFile $share.LatestJson
        if (Test-SyncPaused -Config $Config -Latest $latest -Now $Now) { return 'paused' }
        if (-not $latest -or -not $latest.sha256) { return 'no-copy' }
        $incoming = Get-VerifiedIncoming -Config $Config -Latest $latest
        if (-not $incoming) {
            Show-SyncToast -Config $Config -Kind 'update' -Text 'The new data is still downloading. Try again in a few minutes.'
            return 'waiting'
        }
        if (@(Get-AroniumProcess -Config $Config).Count -gt 0) {
            if (-not (Close-AroniumGracefully -Config $Config -TimeoutSeconds 30)) {
                Show-SyncToast -Config $Config -Kind 'update' -Text 'Please close Aronium, then click Update now again.'
                Write-SyncLog -Config $Config -Level WARN -Message 'Update now: Aronium did not close within 30s; left it running.'
                return 'aronium-open'
            }
        }
        $relaunch = $true
        try {
            Invoke-Restore -Config $Config -IncomingPath $incoming -ExpectedSha $latest.sha256 -Latest $latest -Now $Now
        } catch {
            Write-SyncLog -Config $Config -Level ERROR -Message ('Update now failed: ' + $_.Exception.Message)
            Show-SyncToast -Config $Config -Kind 'update' -Text ('Update failed: ' + $_.Exception.Message)
            return 'failed'
        }
        return 'restored'
    } finally {
        if ($incoming -and (Test-Path -LiteralPath $incoming)) { Remove-Item -LiteralPath $incoming -Force -ErrorAction SilentlyContinue }
        Exit-SyncMutex $mutex
        if ($relaunch) { [void](Start-Aronium -Config $Config) }
    }
}

function Set-LaterAction {
    param([Parameter(Mandatory)][hashtable]$Config)
    $latest = Read-JsonFile (Get-SharePaths -Config $Config).LatestJson
    $state = Get-SyncState -Config $Config
    $state.laterSha = $(if ($latest) { [string]$latest.sha256 } else { $state.notifiedSha })
    Save-SyncState -Config $Config -State $state
    Write-SyncLog -Config $Config -Message 'Later: will ask again when the next new copy arrives.'
}

function Invoke-Takeover {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [datetime]$Now = (Get-Date),
        [string]$HostName = $env:COMPUTERNAME
    )
    # Already the selling laptop: a second takeover would just skip 500 more receipt numbers.
    $writerNow = Read-JsonFile (Get-SharePaths -Config $Config).WriterJson
    if ($Config.role -eq 'seller' -and $writerNow -and $writerNow.host -eq $HostName) {
        Show-SyncToast -Config $Config -Kind 'takeover' -Text 'This laptop is already the selling laptop. Nothing to do.'
        return 'already-seller'
    }
    # Never runs from one click: the confirm box comes first, with No as default.
    if (-not (Show-ConfirmBox -Text 'This makes THIS laptop the selling laptop. Receipt numbers jump by 500. Continue?')) {
        Write-SyncLog -Config $Config -Message 'Take over cancelled at the confirm box.'
        return 'cancelled'
    }
    $mutex = Get-SyncMutex -Config $Config -WaitSeconds 60
    if (-not $mutex) { return 'busy' }
    $incoming = $null
    try {
        $share = Get-SharePaths -Config $Config
        if (@(Get-AroniumProcess -Config $Config).Count -gt 0) {
            if (-not (Close-AroniumGracefully -Config $Config -TimeoutSeconds 30)) {
                Show-SyncToast -Config $Config -Kind 'takeover' -Text 'Please close Aronium, then click Take over again.'
                return 'aronium-open'
            }
        }
        if (-not (Test-Path -LiteralPath $Config.dbPath)) { throw "Aronium database not found at $($Config.dbPath)" }

        # Restore the newest copy first, unless this laptop has its own sales (then keep them).
        $latest = Read-JsonFile $share.LatestJson
        $note = ''
        $d = Test-Divergence -Config $Config -Latest $latest
        $state = Get-SyncState -Config $Config
        $acked = $state.ackFingerprint -and $state.ackFingerprint -eq $d.Fingerprint
        if ((Test-Path -LiteralPath $Config.pauseFlag) -or ($d.Diverged -and -not $acked)) {
            $note = ' Kept this laptop''s own data (it has sales the main laptop did not publish).'
            Write-SyncLog -Config $Config -Level WARN -Message 'Takeover: local data diverged; skipping restore and keeping local data.'
        } elseif ($latest -and $latest.sha256) {
            $stamp = Get-RestoreStamp -Config $Config
            if ($acked -or -not ($stamp -and $stamp.sha256 -eq $latest.sha256)) {
                $incoming = Get-VerifiedIncoming -Config $Config -Latest $latest
                if ($incoming) { Invoke-Restore -Config $Config -IncomingPath $incoming -ExpectedSha $latest.sha256 -Latest $latest -Now $Now }
                else {
                    $note = ' The newest copy was still downloading, so this laptop continues from its last copy.'
                    Write-SyncLog -Config $Config -Level WARN -Message 'Takeover: latest.db does not match latest.json; continuing from the last restored copy.'
                }
            }
        }

        if ((Get-TableColumns -Config $Config -Database $Config.dbPath -Tables @('Counter')).ContainsKey('Counter')) {
            Invoke-Sqlite -Config $Config -Database $Config.dbPath -Sql "BEGIN; UPDATE Counter SET Value = Value + $($script:CounterBump); COMMIT;" | Out-Null
        }
        Set-WriterClaim -Config $Config -Now $Now -HostName $HostName
        Set-SyncConfigRole -Config $Config -Role 'seller'
        Register-SyncTasks -Config $Config -Role 'seller'
        if (Test-Path -LiteralPath $Config.pauseFlag) { Remove-Item -LiteralPath $Config.pauseFlag -Force }
        Write-SyncLog -Config $Config -Message "Takeover: $HostName is now the selling laptop; Counter +$($script:CounterBump)."
    } catch {
        Write-SyncLog -Config $Config -Level ERROR -Message ('Take over failed: ' + $_.Exception.Message)
        Show-SyncToast -Config $Config -Kind 'takeover' -Text ('Take over failed: ' + $_.Exception.Message)
        return 'failed'
    } finally {
        if ($incoming -and (Test-Path -LiteralPath $incoming)) { Remove-Item -LiteralPath $incoming -Force -ErrorAction SilentlyContinue }
        Exit-SyncMutex $mutex
    }
    [void](Invoke-Publish -Config $Config -Now $Now -HostName $HostName)
    [void](Start-Aronium -Config $Config)
    Show-SyncToast -Config $Config -Kind 'takeover' -Text ('This laptop is now the selling laptop. Receipt numbers jumped by 500.' + $note)
    return 'taken-over'
}

# ---------------------------------------------------------------- protocol handler

function ConvertTo-SyncAction {
    # Strict whitelist. Returns 'update-now' | 'later' | 'takeover', or $null for anything else.
    param([AllowNull()][AllowEmptyString()][string]$Uri)
    if ([string]::IsNullOrEmpty($Uri) -or $Uri.Length -gt 64) { return $null }
    $m = [regex]::Match($Uri, '^(?i:aronium-sync):(?://)?([a-z-]+)/?$')
    if (-not $m.Success) { return $null }
    $a = $m.Groups[1].Value
    if ($script:Actions -ccontains $a) { return $a }
    return $null
}

function Invoke-ProtocolAction {
    param([Parameter(Mandatory)][hashtable]$Config, [AllowNull()][AllowEmptyString()][string]$Uri)
    $action = ConvertTo-SyncAction -Uri $Uri
    if (-not $action) {
        $safe = if ($Uri) { ($Uri -replace '[^A-Za-z0-9:/._-]', '?') } else { '' }
        if ($safe.Length -gt 64) { $safe = $safe.Substring(0, 64) }
        Write-SyncLog -Config $Config -Level WARN -Message "Ignored unknown protocol action '$safe'."
        return 'rejected'
    }
    Write-SyncLog -Config $Config -Message "Toast button: $action"
    switch ($action) {
        'update-now' { [void](Invoke-UpdateNow -Config $Config) }
        'later' { Set-LaterAction -Config $Config }
        'takeover' { [void](Invoke-Takeover -Config $Config) }
    }
    return $action
}

# ---------------------------------------------------------------- install helpers (tasks, protocol)

function Get-PowerShellExe { return (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') }

function Get-ProtocolCommand {
    param([Parameter(Mandatory)][string]$HandlerScript)
    return ('"{0}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" "%1"' -f (Get-PowerShellExe), $HandlerScript)
}

function Register-SyncProtocol {
    param([Parameter(Mandatory)][string]$HandlerScript)
    $key = 'HKCU:\Software\Classes\aronium-sync'
    New-Item -Path $key -Force | Out-Null
    Set-ItemProperty -Path $key -Name '(default)' -Value 'URL:Aronium Sync'
    Set-ItemProperty -Path $key -Name 'URL Protocol' -Value ''
    New-Item -Path "$key\shell\open\command" -Force | Out-Null
    Set-ItemProperty -Path "$key\shell\open\command" -Name '(default)' -Value (Get-ProtocolCommand -HandlerScript $HandlerScript)
}

function Unregister-SyncProtocol {
    $key = 'HKCU:\Software\Classes\aronium-sync'
    if (Test-Path $key) { Remove-Item -Path $key -Recurse -Force }
}

$script:TaskNames = @{ seller = 'AroniumSync Publish'; reader = 'AroniumSync Check' }

function Get-SyncTaskXml {
    # Task Scheduler XML: runs as the logged-on user, only when logged on (InteractiveToken),
    # so toasts can show. Seller: every 15 min + at logon + at shutdown/restart (event 1074).
    # Reader: every 5 min + at logon.
    param(
        [Parameter(Mandatory)][ValidateSet('seller', 'reader')][string]$Role,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$UserId,
        [datetime]$Start = (Get-Date).Date,
        [switch]$NoEventTrigger
    )
    $esc = { param($s) [System.Security.SecurityElement]::Escape([string]$s) }
    $interval = if ($Role -eq 'seller') { 'PT15M' } else { 'PT5M' }
    $startStr = $Start.ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    # The seller waits 3 min after logon so OneDrive can bring down writer.json / latest.json first.
    $logonDelay = if ($Role -eq 'seller') { '<Delay>PT3M</Delay>' } else { '' }
    $triggers = @"
    <TimeTrigger>
      <Repetition><Interval>$interval</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition>
      <StartBoundary>$startStr</StartBoundary>
      <Enabled>true</Enabled>
    </TimeTrigger>
    <LogonTrigger><Enabled>true</Enabled><UserId>$(& $esc $UserId)</UserId>$logonDelay</LogonTrigger>
"@
    if ($Role -eq 'seller' -and -not $NoEventTrigger) {
        $query = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name=''User32''] and EventID=1074]]</Select></Query></QueryList>'
        $triggers += @"

    <EventTrigger><Enabled>true</Enabled><Subscription>$(& $esc $query)</Subscription></EventTrigger>
"@
    }
    $cmdArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $ScriptPath
    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Aronium Sync ($Role)</Description></RegistrationInfo>
  <Triggers>
$triggers
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$(& $esc $UserId)</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <ExecutionTimeLimit>PT10M</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$(& $esc (Get-PowerShellExe))</Command>
      <Arguments>$(& $esc $cmdArgs)</Arguments>
    </Exec>
  </Actions>
</Task>
"@
}

function Register-SyncTasks {
    # Registers the task for this role and removes the other role's task.
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][ValidateSet('seller', 'reader')][string]$Role)
    $appDir = Split-Path -Parent $Config.configPath
    $script = if ($Role -eq 'seller') { Join-Path $appDir 'publish.ps1' } else { Join-Path $appDir 'check.ps1' }
    $user = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
    $other = if ($Role -eq 'seller') { 'reader' } else { 'seller' }
    Unregister-ScheduledTask -TaskName $script:TaskNames[$other] -Confirm:$false -ErrorAction SilentlyContinue
    $xml = Get-SyncTaskXml -Role $Role -ScriptPath $script -UserId $user
    try {
        Register-ScheduledTask -TaskName $script:TaskNames[$Role] -Xml $xml -Force -ErrorAction Stop | Out-Null
    } catch {
        if ($Role -ne 'seller') { throw }
        # The shutdown (event 1074) trigger is a nice-to-have; register without it if Windows refuses.
        Write-SyncLog -Config $Config -Level WARN -Message ('Shutdown trigger refused (' + $_.Exception.Message + '); publishing every 15 min and at logon only.')
        $xml = Get-SyncTaskXml -Role $Role -ScriptPath $script -UserId $user -NoEventTrigger
        Register-ScheduledTask -TaskName $script:TaskNames[$Role] -Xml $xml -Force -ErrorAction Stop | Out-Null
    }
}

function Unregister-SyncTasks {
    foreach ($n in $script:TaskNames.Values) { Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue }
}

function Set-SyncShortcuts {
    # Desktop icons: Clear pause on both laptops, Take over on the viewing laptop only.
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][ValidateSet('seller', 'reader')][string]$Role)
    $appDir = Split-Path -Parent $Config.configPath
    $desk = [Environment]::GetFolderPath('Desktop')
    $wsh = New-Object -ComObject WScript.Shell
    $want = @(@{ Name = 'Aronium Sync - Clear pause'; Script = 'clear-pause.ps1' })
    if ($Role -eq 'reader') { $want += @{ Name = 'Aronium Sync - Take over'; Script = 'takeover.ps1' } }
    else {
        $old = Join-Path $desk 'Aronium Sync - Take over.lnk'
        if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force }
    }
    foreach ($s in $want) {
        $lnk = $wsh.CreateShortcut((Join-Path $desk ($s.Name + '.lnk')))
        $lnk.TargetPath = Get-PowerShellExe
        $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $appDir $s.Script)
        $lnk.WorkingDirectory = $appDir
        $lnk.Save()
    }
}

function Set-SyncRole {
    # Switches this laptop between seller and reader in place (no uninstall, no downloads).
    # Returns @{ Status = 'reader' | 'seller' | 'already' | 'refused' | 'busy'; Message = text }.
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][ValidateSet('seller', 'reader')][string]$Role,
        [switch]$Force,
        [datetime]$Now = (Get-Date),
        [string]$HostName = $env:COMPUTERNAME
    )
    $share = Get-SharePaths -Config $Config
    $writer = Read-JsonFile $share.WriterJson
    if ($Role -eq 'seller' -and $Config.role -eq 'seller' -and $writer -and $writer.host -eq $HostName) {
        return @{ Status = 'already'; Message = 'This laptop is already the selling laptop.' }
    }
    if ($Role -eq 'reader' -and $Config.role -eq 'reader') {
        return @{ Status = 'already'; Message = 'This laptop is already the viewing laptop.' }
    }
    if ($Role -eq 'seller' -and -not $Force) {
        $block = Get-SellerSwitchBlock -Config $Config -HostName $HostName
        if ($block) { return @{ Status = 'refused'; Message = $block } }
        if ($writer -and $writer.host -and $writer.host -ne $HostName) {
            return @{ Status = 'refused'; Message = ("OneDrive says {0} is the selling laptop. Use Take over if it is down, or -Force if you are sure." -f $writer.host) }
        }
    }
    $mutex = Get-SyncMutex -Config $Config -WaitSeconds 60
    if (-not $mutex) { return @{ Status = 'busy'; Message = 'Another sync step is running. Try again in a minute.' } }
    try {
        if ($Role -eq 'seller') { Set-WriterClaim -Config $Config -Now $Now -HostName $HostName }
        else {
            # Whatever is in pos.db now is not "sales made here": the next check loads the seller's copy
            # (the current file is kept in backups).
            Set-BaselineStamp -Config $Config -Now $Now
        }
        Set-SyncConfigRole -Config $Config -Role $Role
        Register-SyncTasks -Config $Config -Role $Role
        Set-SyncShortcuts -Config $Config -Role $Role
        Write-SyncLog -Config $Config -Message "Role changed to $Role with set-role."
    } finally { Exit-SyncMutex $mutex }
    if ($Role -eq 'seller') {
        [void](Invoke-Publish -Config $Config -Now $Now -HostName $HostName)
        return @{ Status = 'seller'; Message = 'This laptop is now the selling laptop.' }
    }
    return @{ Status = 'reader'; Message = 'This laptop is now the viewing laptop. It loads the selling laptop''s copy within 5 minutes.' }
}

# ---------------------------------------------------------------- sqlite3.exe download (pinned)

# sqlite.org publishes SHA3-256, which .NET Framework / PowerShell 5.1 cannot compute.
# So the version is pinned and its SHA-256 recorded here. The SHA3-256 published on
# sqlite.org/download.html (e171f399...ab987) was checked when this pin was set (2026-11-26).
$script:SqliteZipUrl = 'https://www.sqlite.org/2026/sqlite-tools-win-x64-3540100.zip'
$script:SqliteZipSha256 = 'fb20997ade5583a5fbf1e36db7bc3c82c9416b3f314f16961e1572aa4e49487d'

function Install-PinnedSqlite {
    param([Parameter(Mandatory)][string]$DestinationDir)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $work = Join-Path $env:TEMP ('aronium-sync-dl-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    try {
        $zip = Join-Path $work 'sqlite-tools.zip'
        $old = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        try { Invoke-WebRequest -Uri $script:SqliteZipUrl -OutFile $zip -UseBasicParsing } finally { $ProgressPreference = $old }
        $got = Get-FileSha256 $zip
        if ($got -ne $script:SqliteZipSha256) { throw "sqlite download hash mismatch (got $got). Not installing it." }
        Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $work 'x') -Force
        if (-not (Test-Path -LiteralPath $DestinationDir)) { New-Item -ItemType Directory -Force -Path $DestinationDir | Out-Null }
        Copy-Item -LiteralPath (Join-Path $work 'x\sqlite3.exe') -Destination (Join-Path $DestinationDir 'sqlite3.exe') -Force
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------- self-update from GitHub Releases
#
# Clients have no git. update.ps1 asks the GitHub Releases API for the latest published release
# (drafts and plain pushes never show up there), downloads ar-sync-<tag>.zip and its .sha256,
# checks the hash, stages and checks the package, then copies it over the install folder.
# Only files that are in the package are touched, so config.json, state\, backups\, bin\,
# sync.log and SYNC-PAUSED.txt are never overwritten. Any failure after the copy rolls back.

$script:UpdateRepo = 'huenique/ar-sync'
# release-assets.githubusercontent.com is where GitHub now redirects release downloads.
$script:UpdateHosts = @('api.github.com', 'github.com', 'objects.githubusercontent.com', 'release-assets.githubusercontent.com')
$script:UpdateTaskName = 'AroniumSync Update'
$script:VersionPattern = '^v\d+\.\d+\.\d+$'
$script:ReleaseRequired = @('AroniumSync.psm1', 'update.ps1', 'publish.ps1', 'check.ps1', 'VERSION')

function Test-UpdateUrl {
    # Only HTTPS on the default port, only GitHub's own hosts.
    param([AllowNull()][AllowEmptyString()][string]$Url)
    $u = $null
    if ([string]::IsNullOrEmpty($Url) -or -not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$u)) { return $false }
    return ($u.Scheme -eq 'https' -and $u.IsDefaultPort -and $script:UpdateHosts -contains $u.Host.ToLowerInvariant())
}

function Invoke-UpdateHttp {
    # GET with redirects followed by hand, so every hop is checked against Test-UpdateUrl.
    # Returns the body as text, or writes it to OutFile.
    param([Parameter(Mandatory)][string]$Url, [string]$OutFile)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $next = $Url
    for ($hop = 0; $hop -lt 6; $hop++) {
        if (-not (Test-UpdateUrl $next)) { throw "Refusing to download from $next (only GitHub over HTTPS)" }
        $req = [Net.HttpWebRequest]::Create($next)
        $req.AllowAutoRedirect = $false
        $req.UserAgent = 'ar-sync-updater'
        $req.Accept = $(if ($OutFile) { 'application/octet-stream' } else { 'application/vnd.github+json' })
        $req.Timeout = 60000
        $resp = $null
        try { $resp = $req.GetResponse() } catch {
            $e = $_.Exception
            while ($e.InnerException -and -not ($e -is [Net.WebException])) { $e = $e.InnerException }
            if ($e -is [Net.WebException] -and $e.Response) { $resp = $e.Response } else { throw }
        }
        $code = [int]$resp.StatusCode
        if ($code -ge 300 -and $code -lt 400) {
            $loc = $resp.Headers['Location']
            $resp.Close()
            if (-not $loc) { throw "Redirect without a Location from $next" }
            $next = ([Uri]::new([Uri]$next, $loc)).AbsoluteUri
            continue
        }
        try {
            if ($code -ne 200) { throw "HTTP $code from $next" }
            $stream = $resp.GetResponseStream()
            if ($OutFile) {
                $fs = [IO.File]::Create($OutFile)
                try { $stream.CopyTo($fs) } finally { $fs.Dispose() }
                return
            }
            $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
            return $reader.ReadToEnd()
        } finally { $resp.Close() }
    }
    throw "Too many redirects from $Url"
}

function Invoke-UpdateApi {
    param([Parameter(Mandatory)][string]$Url)
    return ((Invoke-UpdateHttp -Url $Url) | ConvertFrom-Json)
}

function Invoke-UpdateDownload {
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$OutFile)
    Invoke-UpdateHttp -Url $Url -OutFile $OutFile
}

function Get-UpdateRelease {
    # The latest published release, or the one with this tag.
    param([string]$Version)
    $base = 'https://api.github.com/repos/' + $script:UpdateRepo + '/releases/'
    if ($Version) { return (Invoke-UpdateApi -Url ($base + 'tags/' + $Version)) }
    return (Invoke-UpdateApi -Url ($base + 'latest'))
}

function ConvertTo-SyncVersion {
    param([Parameter(Mandatory)][string]$Tag)
    if ($Tag -notmatch $script:VersionPattern) { throw "'$Tag' is not a version like v1.2.3" }
    return [version]$Tag.Substring(1)
}

function Get-InstalledVersion {
    # Installs from before the updater have no VERSION file: treat them as v0.0.0.
    param([Parameter(Mandatory)][string]$AppDir)
    $p = Join-Path $AppDir 'VERSION'
    if (-not (Test-Path -LiteralPath $p)) { return 'v0.0.0' }
    $v = ([IO.File]::ReadAllText($p)).Trim()
    if ($v -notmatch $script:VersionPattern) { return 'v0.0.0' }
    return $v
}

function Assert-ReleaseFiles {
    # Throws if a package (or a release being built) would carry shop data or per-laptop files.
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Paths)
    $bad = @()
    foreach ($p in $Paths) {
        $n = $p.Replace('\', '/').TrimStart('./')
        $leaf = ($n -split '/')[-1]
        $top = ($n -split '/')[0]
        if ($leaf -like '*.db' -or $leaf -like '*.db-*' -or $leaf -like '*.bak' -or $leaf -like '*.log' -or $leaf -eq 'config.json' -or
            $leaf -eq 'SYNC-PAUSED.txt' -or @('fixtures', 'state', 'backups', 'bin', 'update-backup') -contains $top) { $bad += $p }
    }
    if ($bad.Count -gt 0) { throw ('Refusing to package: ' + ($bad -join ', ')) }
}

function Invoke-PowerShellChild {
    # Runs a script in a fresh Windows PowerShell, so a staged module can be loaded without
    # touching the one this process is running. Returns @{ Code; Out }.
    param([Parameter(Mandatory)][string]$Script)
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    $out = & (Get-PowerShellExe) -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $enc 2>&1
    return @{ Code = $LASTEXITCODE; Out = @($out | ForEach-Object { [string]$_ }) }
}

function ConvertTo-PsQuoted {
    param([Parameter(Mandatory)][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Get-SyncDefinitionHash {
    # Hash of what install registers (role task, update task, toast link). If an update changes
    # it, the update re-registers them; otherwise it leaves Task Scheduler and the registry alone.
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$AppDir)
    $user = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
    $fixed = [datetime]'2000-01-01'
    $script = if ($Config.role -eq 'seller') { Join-Path $AppDir 'publish.ps1' } else { Join-Path $AppDir 'check.ps1' }
    $s = (Get-SyncTaskXml -Role $Config.role -ScriptPath $script -UserId $user -Start $fixed) + "`n" +
    (Get-ProtocolCommand -HandlerScript (Join-Path $AppDir 'protocol-handler.ps1')) + "`n" +
    (Get-UpdateTaskXml -ScriptPath (Join-Path $AppDir 'update.ps1') -UserId $user -Start $fixed)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))) -replace '-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Test-ModuleImport {
    # Imports the module at Path in a child PowerShell. With ConfigPath/AppDir, also returns that
    # module's definition hash; otherwise returns 'ok'. Throws if the module will not load.
    param([Parameter(Mandatory)][string]$ModulePath, [string]$ConfigPath, [string]$AppDir)
    $body = "Import-Module $(ConvertTo-PsQuoted $ModulePath) -Force -ErrorAction Stop`n"
    if ($ConfigPath) {
        $body += "`$c = Get-SyncConfig -Path $(ConvertTo-PsQuoted $ConfigPath)`n"
        $body += "Write-Output ('DEFS=' + (Get-SyncDefinitionHash -Config `$c -AppDir $(ConvertTo-PsQuoted $AppDir)))`n"
    } else { $body += "Write-Output 'DEFS=ok'`n" }
    $script = "`$ErrorActionPreference = 'Stop'`ntry {`n$body exit 0`n} catch { [Console]::Error.WriteLine(`$_.Exception.Message); exit 1 }"
    $r = Invoke-PowerShellChild -Script $script
    $line = @($r.Out | Where-Object { $_ -like 'DEFS=*' } | Select-Object -Last 1)
    if ($r.Code -ne 0 -or $line.Count -eq 0) { throw ('Module does not load: ' + (($r.Out -join ' ') -replace '\s+', ' ').Trim()) }
    return $line[0].Substring(5)
}

function Test-UpdatePackage {
    # Checks an unpacked release before it goes anywhere near the install folder.
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$ExpectedVersion, [string]$ConfigPath, [string]$AppDir)
    $root = (Resolve-Path -LiteralPath $Dir).ProviderPath.TrimEnd('\')
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File)
    Assert-ReleaseFiles -Paths @($files | ForEach-Object { $_.FullName.Substring($root.Length + 1) })
    foreach ($f in $script:ReleaseRequired) {
        if (-not (Test-Path -LiteralPath (Join-Path $root $f))) { throw "Package is missing $f" }
    }
    if ((Get-InstalledVersion -AppDir $root) -ne $ExpectedVersion) { throw "Package VERSION does not say $ExpectedVersion" }
    foreach ($f in @($files | Where-Object { $_.Extension -in @('.ps1', '.psm1') })) {
        $errs = $null
        [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
        if (@($errs).Count -gt 0) { throw ("{0} does not parse: {1}" -f $f.Name, $errs[0].Message) }
    }
    return (Test-ModuleImport -ModulePath (Join-Path $root 'AroniumSync.psm1') -ConfigPath $ConfigPath -AppDir $AppDir)
}

function Copy-PackageIntoInstall {
    # Copies every package file into AppDir. Before overwriting, saves the old file in BackupDir;
    # files that did not exist yet are listed in BackupDir\added.txt so a rollback can remove them.
    param([Parameter(Mandatory)][string]$Stage, [Parameter(Mandatory)][string]$AppDir, [Parameter(Mandatory)][string]$BackupDir)
    $root = (Resolve-Path -LiteralPath $Stage).ProviderPath.TrimEnd('\')
    $added = New-Object System.Collections.Generic.List[string]
    $addedPath = Join-Path $BackupDir 'added.txt'
    foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -File)) {
        $rel = $f.FullName.Substring($root.Length + 1)
        $dest = Join-Path $AppDir $rel
        $destDir = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
        if (Test-Path -LiteralPath $dest) {
            $bak = Join-Path (Join-Path $BackupDir 'files') $rel
            $bakDir = Split-Path -Parent $bak
            if (-not (Test-Path -LiteralPath $bakDir)) { New-Item -ItemType Directory -Force -Path $bakDir | Out-Null }
            Copy-Item -LiteralPath $dest -Destination $bak -Force
        } else {
            $added.Add($rel)
            [IO.File]::WriteAllLines($addedPath, $added.ToArray())
        }
        Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
        Unblock-File -LiteralPath $dest -ErrorAction SilentlyContinue
    }
}

function Restore-InstallFromBackup {
    param([Parameter(Mandatory)][string]$AppDir, [Parameter(Mandatory)][string]$BackupDir)
    $files = Join-Path $BackupDir 'files'
    if (Test-Path -LiteralPath $files) {
        $root = (Resolve-Path -LiteralPath $files).ProviderPath.TrimEnd('\')
        foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -File)) {
            Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $AppDir $f.FullName.Substring($root.Length + 1)) -Force
        }
    }
    $addedPath = Join-Path $BackupDir 'added.txt'
    if (Test-Path -LiteralPath $addedPath) {
        foreach ($rel in [IO.File]::ReadAllLines($addedPath)) {
            if (-not $rel) { continue }
            $p = Join-Path $AppDir $rel
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
        }
    }
}

function Update-SyncRegistrations {
    # Re-registers the role task, the update task and the toast link using the NEW module,
    # in a child PowerShell (this process still has the old module loaded).
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$AppDir)
    $psm = Join-Path $AppDir 'AroniumSync.psm1'
    $script = "`$ErrorActionPreference = 'Stop'`ntry {`nImport-Module $(ConvertTo-PsQuoted $psm) -Force`n" +
    "`$c = Get-SyncConfig -Path $(ConvertTo-PsQuoted $Config.configPath)`n" +
    "Register-SyncProtocol -HandlerScript $(ConvertTo-PsQuoted (Join-Path $AppDir 'protocol-handler.ps1'))`n" +
    "Register-SyncTasks -Config `$c -Role `$c.role`nRegister-UpdateTask -Config `$c`nexit 0`n" +
    "} catch { [Console]::Error.WriteLine(`$_.Exception.Message); exit 1 }"
    $r = Invoke-PowerShellChild -Script $script
    if ($r.Code -ne 0) { throw ('Re-registering tasks failed: ' + (($r.Out -join ' ') -replace '\s+', ' ').Trim()) }
}

function Invoke-SelfUpdate {
    # Returns 'updated' | 'up-to-date' | 'disabled' | 'pinned' | 'busy' | 'failed'.
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [string]$AppDir,
        [string]$Version,
        [switch]$Unpin,
        [int]$MutexWaitSeconds = 60
    )
    if (-not $AppDir) { $AppDir = Split-Path -Parent $Config.configPath }
    if ($Version -and $Version -notmatch $script:VersionPattern) {
        Write-SyncLog -Config $Config -Level ERROR -Message "Update: '$Version' is not a version like v1.2.3."
        return 'failed'
    }
    $state = Get-SyncState -Config $Config
    if (-not $Version -and -not $Unpin) {
        if ($Config.ContainsKey('autoUpdate') -and $Config.autoUpdate -eq $false) {
            Write-SyncLog -Config $Config -Message 'Update: autoUpdate is off in config.json; not checking.'
            return 'disabled'
        }
        if ($state.updatePin) {
            Write-SyncLog -Config $Config -Message "Update: pinned to $($state.updatePin); not checking. Run update.ps1 -Unpin to follow new releases."
            return 'pinned'
        }
    }
    $mutex = Get-SyncMutex -Config $Config -WaitSeconds $MutexWaitSeconds
    if (-not $mutex) { Write-SyncLog -Config $Config -Message 'Update skipped: a sync step is running.'; return 'busy' }
    $work = $null
    $backup = Join-Path $AppDir 'update-backup'
    $copied = $false
    $registered = $false
    $tag = $(if ($Version) { $Version } else { 'latest' })
    try {
        $installed = Get-InstalledVersion -AppDir $AppDir
        $rel = Get-UpdateRelease -Version $Version
        $tag = [string]$rel.tag_name
        if ($tag -notmatch $script:VersionPattern) { throw "release tag '$tag' is not a version like v1.2.3" }
        if ($Version -and $tag -ne $Version) { throw "asked for $Version but GitHub returned $tag" }
        $cmp = (ConvertTo-SyncVersion $tag).CompareTo((ConvertTo-SyncVersion $installed))
        if (($Version -and $cmp -eq 0) -or (-not $Version -and $cmp -le 0)) {
            $state = Get-SyncState -Config $Config
            $state.updatePin = $(if ($Version) { $Version } else { $null })
            Save-SyncState -Config $Config -State $state
            Write-SyncLog -Config $Config -Message "Update: $installed is installed; release $tag is not newer. Nothing to do."
            return 'up-to-date'
        }

        $zipName = "ar-sync-$tag.zip"
        $zipAsset = @($rel.assets | Where-Object { $_.name -eq $zipName }) | Select-Object -First 1
        $shaAsset = @($rel.assets | Where-Object { $_.name -eq "$zipName.sha256" }) | Select-Object -First 1
        if (-not $zipAsset -or -not $shaAsset) { throw "release $tag is missing $zipName or $zipName.sha256" }
        foreach ($a in @($zipAsset, $shaAsset)) {
            if (-not (Test-UpdateUrl ([string]$a.browser_download_url))) { throw "refusing download from $($a.browser_download_url)" }
        }

        $work = Join-Path $env:TEMP ('ar-sync-update-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        $zip = Join-Path $work $zipName
        $shaFile = $zip + '.sha256'
        Invoke-UpdateDownload -Url ([string]$zipAsset.browser_download_url) -OutFile $zip
        Invoke-UpdateDownload -Url ([string]$shaAsset.browser_download_url) -OutFile $shaFile
        if (-not (Test-Path -LiteralPath $zip) -or -not (Test-Path -LiteralPath $shaFile)) { throw 'download did not produce both files' }
        $expected = (([IO.File]::ReadAllText($shaFile).Trim() -split '\s+')[0]).ToLowerInvariant()
        if ($expected -notmatch '^[0-9a-f]{64}$') { throw "$zipName.sha256 does not hold a SHA-256 hash" }
        if ((Get-FileSha256 $zip) -ne $expected) { throw "hash mismatch on $zipName; not installing it" }

        $stage = Join-Path $work 'stage'
        Expand-Archive -LiteralPath $zip -DestinationPath $stage -Force
        $newDefs = Test-UpdatePackage -Dir $stage -ExpectedVersion $tag -ConfigPath $Config.configPath -AppDir $AppDir
        $oldDefs = Get-SyncDefinitionHash -Config $Config -AppDir $AppDir

        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $backup | Out-Null
        $copied = $true
        Copy-PackageIntoInstall -Stage $stage -AppDir $AppDir -BackupDir $backup
        if ((Get-InstalledVersion -AppDir $AppDir) -ne $tag) { throw 'VERSION in the install folder does not match after copying' }
        [void](Test-ModuleImport -ModulePath (Join-Path $AppDir 'AroniumSync.psm1'))
        if ($newDefs -ne $oldDefs) {
            $registered = $true
            Update-SyncRegistrations -Config $Config -AppDir $AppDir
            Write-SyncLog -Config $Config -Message 'Update: task or link definitions changed; re-registered them.'
        }

        $state = Get-SyncState -Config $Config
        $state.updatePin = $(if ($Version) { $Version } else { $null })
        Save-SyncState -Config $Config -State $state
        Write-SyncLog -Config $Config -Message "Update: $installed -> $tag installed."
        Show-SyncToast -Config $Config -Kind 'tool-update' -Text "Sync tool updated to $tag."
        return 'updated'
    } catch {
        $reason = $_.Exception.Message
        if ($copied) {
            try {
                Restore-InstallFromBackup -AppDir $AppDir -BackupDir $backup
                if ($registered) {
                    Register-SyncProtocol -HandlerScript (Join-Path $AppDir 'protocol-handler.ps1')
                    Register-SyncTasks -Config $Config -Role $Config.role
                    Register-UpdateTask -Config $Config
                }
                $reason += ' Rolled back to the previous version.'
            } catch { $reason += ' ROLLBACK FAILED: ' + $_.Exception.Message }
        }
        Write-SyncLog -Config $Config -Level ERROR -Message "Update to $tag failed: $reason"
        Show-SyncToast -Config $Config -Kind 'tool-update' -Text "Sync tool update to $tag failed: $reason"
        return 'failed'
    } finally {
        if ($work -and (Test-Path -LiteralPath $work)) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
        Exit-SyncMutex $mutex
    }
}

function Get-UpdateTaskXml {
    # Daily at 03:00 (or as soon as the laptop is on after that) and 10 minutes after logon.
    param([Parameter(Mandatory)][string]$ScriptPath, [Parameter(Mandatory)][string]$UserId, [datetime]$Start = (Get-Date).Date)
    $esc = { param($s) [System.Security.SecurityElement]::Escape([string]$s) }
    $startStr = $Start.Date.AddHours(3).ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    $cmdArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $ScriptPath
    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Aronium Sync (update from GitHub releases)</Description></RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>$startStr</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay>
    </CalendarTrigger>
    <LogonTrigger><Enabled>true</Enabled><UserId>$(& $esc $UserId)</UserId><Delay>PT10M</Delay></LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$(& $esc $UserId)</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>true</RunOnlyIfNetworkAvailable>
    <ExecutionTimeLimit>PT30M</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$(& $esc (Get-PowerShellExe))</Command>
      <Arguments>$(& $esc $cmdArgs)</Arguments>
    </Exec>
  </Actions>
</Task>
"@
}

function Register-UpdateTask {
    param([Parameter(Mandatory)][hashtable]$Config)
    $appDir = Split-Path -Parent $Config.configPath
    $user = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
    $xml = Get-UpdateTaskXml -ScriptPath (Join-Path $appDir 'update.ps1') -UserId $user
    Register-ScheduledTask -TaskName $script:UpdateTaskName -Xml $xml -Force -ErrorAction Stop | Out-Null
}

function New-ReleasePackage {
    # Builds ar-sync-<tag>.zip (files at the zip root) and ar-sync-<tag>.zip.sha256 in OutDir.
    # Files are paths relative to Root. Returns @{ Zip; Sha256File; Hash }.
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string[]]$Files,
        [Parameter(Mandatory)][string]$OutDir
    )
    if ($Version -notmatch $script:VersionPattern) { throw "'$Version' is not a version like v1.2.3" }
    Assert-ReleaseFiles -Paths $Files
    foreach ($f in $script:ReleaseRequired) { if ($Files -notcontains $f) { throw "Release must include $f" } }
    if ((Get-InstalledVersion -AppDir $Root) -ne $Version) { throw "VERSION says $(Get-InstalledVersion -AppDir $Root), not $Version" }
    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
    $zip = Join-Path $OutDir "ar-sync-$Version.zip"
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($f in $Files) {
            $src = Join-Path $Root $f
            if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { throw "Missing file: $f" }
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $src, $f.Replace('\', '/'))
        }
    } finally { $archive.Dispose() }
    $hash = Get-FileSha256 $zip
    $shaFile = $zip + '.sha256'
    [IO.File]::WriteAllText($shaFile, ("{0}  ar-sync-{1}.zip`n" -f $hash, $Version), (New-Object Text.UTF8Encoding $false))
    return @{ Zip = $zip; Sha256File = $shaFile; Hash = $hash }
}

Export-ModuleMember -Function *-*
