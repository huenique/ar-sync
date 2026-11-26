# Test helpers. Dot-source in BeforeAll. ASCII only.
# Two simulated laptops (A = seller, B = reader) share one fake OneDrive folder under $TestDrive.
# Nothing here prints table contents: assertions use counts, hashes and fingerprints only.

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:SqliteExe = Join-Path $script:RepoRoot 'tools\sqlite3.exe'
$script:SchemaSql = Join-Path $PSScriptRoot 'schema.sql'
$script:RealFixture = Join-Path $script:RepoRoot 'fixtures\real.db'

function New-TestLaptop {
    # Creates config.json for one laptop and returns the loaded config hashtable.
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('seller', 'reader')][string]$Role,
        [string]$MutexName = ('Local\AroniumSyncTest-' + [guid]::NewGuid().ToString('N'))
    )
    $base = Join-Path $Root $Name
    New-Item -ItemType Directory -Force -Path (Join-Path $base 'Aronium') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $Root 'OneDrive') | Out-Null
    $cfg = [ordered]@{
        role               = $Role
        oneDriveFolder     = (Join-Path $Root 'OneDrive\aronium')
        dbPath             = (Join-Path $base 'Aronium\pos.db')
        aroniumExe         = ''
        aroniumProcessName = 'AroniumDoesNotExist'
        shopHours          = @{ open = '08:00'; close = '21:00'; days = @('Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun') }
        staleMinutes       = 60
        ownerContact       = 'Owner 0917-000-0000'
        historyDays        = 30
        keepBackups        = 10
        baseDir            = $base
        sqlitePath         = $script:SqliteExe
        mutexName          = $MutexName
    }
    $path = Join-Path $base 'config.json'
    [IO.File]::WriteAllText($path, ($cfg | ConvertTo-Json -Depth 5))
    return (Get-SyncConfig -Path $path)
}

function Invoke-TestSql {
    param([Parameter(Mandatory)][string]$Database, [Parameter(Mandatory)][string]$Sql)
    $cfg = @{ sqlitePath = $script:SqliteExe }
    return (Invoke-Sqlite -Config $cfg -Database $Database -Sql $Sql)
}

function Get-TestScalar {
    param([Parameter(Mandatory)][string]$Database, [Parameter(Mandatory)][string]$Sql)
    return (@(Invoke-TestSql -Database $Database -Sql $Sql) | Select-Object -First 1)
}

function New-SyntheticDb {
    # Builds a small DB from the real Aronium schema (no real rows) plus a few fake rows.
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    $schema = ([IO.File]::ReadAllLines($script:SchemaSql) | Where-Object { $_ -notmatch '^CREATE TABLE sqlite_sequence' }) -join "`n"
    $rows = @"
INSERT INTO Warehouse (Id, Name) VALUES (1, 'Main');
INSERT INTO User (Id, Username, Password) VALUES (1, 'cashier', 'x');
INSERT INTO Customer (Id, Code, Name, DateCreated, DateUpdated) VALUES (1, 'C1', 'Test Customer', '2026-01-01 08:00:00', '2026-01-01 08:00:00');
INSERT INTO Product (Id, Name, Price, DateCreated, DateUpdated) VALUES (1, 'Widget', 10, '2026-01-01 08:00:00', '2026-01-01 08:00:00');
INSERT INTO Product (Id, Name, Price, DateCreated, DateUpdated) VALUES (2, 'Gadget', 25, '2026-01-01 08:00:00', '2026-01-01 08:00:00');
INSERT INTO Stock (Id, ProductId, WarehouseId, Quantity) VALUES (1, 1, 1, 100);
INSERT INTO Stock (Id, ProductId, WarehouseId, Quantity) VALUES (2, 2, 1, 50);
INSERT INTO Document (Id, Number, UserId, Date, StockDate, Total, DocumentTypeId, WarehouseId, DateCreated, DateUpdated) VALUES (1, '26-200-000001', 1, '2026-01-02', '2026-01-02 09:00:00', 10, 1, 1, '2026-01-02 09:00:00', '2026-01-02 09:00:00');
INSERT INTO DocumentItem (Id, DocumentId, ProductId, Quantity, Price) VALUES (1, 1, 1, 1, 10);
INSERT INTO Payment (Id, DocumentId, PaymentTypeId, Amount, Date) VALUES (1, 1, 1, 10, '2026-01-02');
INSERT INTO StartingCash (Id, UserId, Amount, DateCreated) VALUES (1, 1, 500, '2026-01-02 08:00:00');
INSERT INTO ZReport (Id, Number, FromDocumentId, ToDocumentId, DateCreated) VALUES (1, 1, 1, 1, '2026-01-02 21:00:00');
INSERT INTO Counter (Name, Value) VALUES ('Receipt', 100);
INSERT INTO Counter (Name, Value) VALUES ('Document.200.2026', 41);
INSERT INTO ApplicationProperty (Name, Value) VALUES ('Application.Id', 'synthetic');
INSERT INTO SecurityKey (Name, Level) VALUES ('Test.Key', 1);
INSERT INTO PosPrinterSelection (Id, Key, PrinterName, IsEnabled) VALUES (1, 'Receipt', 'Synthetic Printer', 1);
"@
    Invoke-TestSql -Database $Path -Sql ($schema + "`n" + $rows) | Out-Null
}

function Copy-RealDb {
    param([Parameter(Mandatory)][string]$Path)
    Copy-Item -LiteralPath $script:RealFixture -Destination $Path -Force
    (Get-Item -LiteralPath $Path).IsReadOnly = $false
}

function New-FixtureDb {
    param([Parameter(Mandatory)][ValidateSet('synthetic', 'real')][string]$Kind, [Parameter(Mandatory)][string]$Path)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if ($Kind -eq 'real') { Copy-RealDb -Path $Path } else { New-SyntheticDb -Path $Path }
}

function Add-TestSale {
    # Rings up one fake sale: a new Document with an item and a payment.
    param([Parameter(Mandatory)][string]$Database, [string]$When = '2026-11-26 10:00:00')
    $sql = @"
BEGIN;
INSERT INTO Document (Number, UserId, Date, StockDate, Total, DocumentTypeId, WarehouseId, DateCreated, DateUpdated)
  VALUES ('TEST-' || (SELECT coalesce(max(Id), 0) + 1 FROM Document), (SELECT min(Id) FROM User), '$($When.Substring(0,10))', '$When', 1, 1, 1, '$When', '$When');
INSERT INTO DocumentItem (DocumentId, ProductId, Quantity, Price) VALUES ((SELECT max(Id) FROM Document), (SELECT min(Id) FROM Product), 1, 1);
INSERT INTO Payment (DocumentId, PaymentTypeId, Amount, Date) VALUES ((SELECT max(Id) FROM Document), 1, 1, '$($When.Substring(0,10))');
COMMIT;
"@
    Invoke-TestSql -Database $Database -Sql $sql | Out-Null
}

function Set-TestMarker {
    # Writes a marker row into a per-PC table so tests can see which laptop's copy survived.
    param([Parameter(Mandatory)][string]$Database, [Parameter(Mandatory)][string]$Value)
    Invoke-TestSql -Database $Database -Sql "INSERT OR REPLACE INTO ApplicationProperty (Name, Value) VALUES ('Test.Marker', '$Value');" | Out-Null
}

function Get-TestMarker {
    param([Parameter(Mandatory)][string]$Database)
    return (Get-TestScalar -Database $Database -Sql "SELECT Value FROM ApplicationProperty WHERE Name = 'Test.Marker';")
}

function Get-PerPcHash {
    # Hash of all per-PC table rows (never printed, only compared).
    param([Parameter(Mandatory)][string]$Database)
    $sql = "SELECT (SELECT coalesce(group_concat(Name || '=' || coalesce(Value, ''), '|'), '') FROM (SELECT * FROM ApplicationProperty ORDER BY Name)) || '#' || " +
    "(SELECT coalesce(group_concat(Id || ':' || Key || ':' || coalesce(PrinterName, ''), '|'), '') FROM (SELECT * FROM PosPrinterSelection ORDER BY Id)) || '#' || " +
    "(SELECT coalesce(group_concat(Name || ':' || coalesce(Level, ''), '|'), '') FROM (SELECT * FROM SecurityKey ORDER BY Name));"
    $s = [string](Get-TestScalar -Database $Database -Sql $sql)
    $sha = [Security.Cryptography.SHA256]::Create()
    return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))) -replace '-', '')
}

function Get-TestCases {
    $cases = @(@{ Kind = 'synthetic' })
    if (Test-Path -LiteralPath $script:RealFixture) { $cases += @{ Kind = 'real' } }
    return $cases
}
