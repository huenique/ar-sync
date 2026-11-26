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
        baseDir            = '%LOCALAPPDATA%\AroniumSync'
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

function Set-SyncConfigRole {
    # Rewrites only the role field, keeping the rest of config.json as the owner wrote it.
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][ValidateSet('seller', 'reader')][string]$Role)
    $raw = [IO.File]::ReadAllText($Config.configPath) | ConvertFrom-Json
    if ($raw.PSObject.Properties.Name -contains 'role') { $raw.role = $Role }
    else { $raw | Add-Member -NotePropertyName role -NotePropertyValue $Role }
    Write-FileAtomic -Path $Config.configPath -Text ($raw | ConvertTo-Json -Depth 5)
    $Config.role = $Role
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
    foreach ($k in @('notifiedSha', 'notifiedAt', 'laterSha', 'staleToastFor', 'pausedFingerprint', 'ackFingerprint', 'pausedToastAt', 'notWriterToastAt')) {
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
    param([Parameter(Mandatory)][hashtable]$Config)
    $session = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    return @(Get-Process -Name $Config.aroniumProcessName -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session })
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
        Start-Process -FilePath $Config.aroniumExe | Out-Null
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
            $state = Get-SyncState -Config $Config
            $last = ConvertTo-SyncTime $state.notWriterToastAt
            if (-not $last -or ([DateTimeOffset]$Now - $last).TotalMinutes -ge 60) {
                Show-SyncToast -Config $Config -Kind 'not-writer' -Persistent -Text ("This laptop is no longer the selling laptop. Do not sell on it. Call {0}." -f $Config.ownerContact)
                $state.notWriterToastAt = Format-SyncTime $Now
                Save-SyncState -Config $Config -State $state
            }
            return 'not-writer'
        }
        if (-not $writer) {
            Write-JsonFile -Path $share.WriterJson -Object ([pscustomobject]@{ host = $HostName; since = (Format-SyncTime $Now) })
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
    if (@(Get-AroniumProcess -Config $Config).Count -gt 0) { throw 'Aronium is running; restore refused.' }
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

        if (@(Get-AroniumProcess -Config $Config).Count -gt 0) {
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
        $prev = Read-JsonFile $share.WriterJson
        Write-JsonFile -Path $share.WriterJson -Object ([pscustomobject]@{
                host          = $HostName
                since         = (Format-SyncTime $Now)
                previous_host = $(if ($prev) { $prev.host } else { $null })
            })
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
    $triggers = @"
    <TimeTrigger>
      <Repetition><Interval>$interval</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition>
      <StartBoundary>$startStr</StartBoundary>
      <Enabled>true</Enabled>
    </TimeTrigger>
    <LogonTrigger><Enabled>true</Enabled><UserId>$(& $esc $UserId)</UserId></LogonTrigger>
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

Export-ModuleMember -Function *-*
