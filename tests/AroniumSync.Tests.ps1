# Pester 5 tests. Run with tests\Run-Tests.ps1 (Windows PowerShell 5.1).
# Toasts, the Aronium process, message boxes and scheduled tasks are all mocked.
# No real task, protocol or registry entry is created.

BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:Cases = Get-TestCases
}

BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'AroniumSync.psm1') -Force
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:Now = [datetime]'2026-11-26T10:00:00'   # a Thursday, inside shop hours

    function Initialize-Mocks {
        Mock Show-SyncToast -ModuleName AroniumSync { }
        Mock Get-AroniumProcess -ModuleName AroniumSync { }
        Mock Close-AroniumGracefully -ModuleName AroniumSync { $true }
        Mock Start-Aronium -ModuleName AroniumSync { $true }
        Mock Show-ConfirmBox -ModuleName AroniumSync { $false }
        Mock Register-SyncTasks -ModuleName AroniumSync { }
        Mock Register-SyncProtocol -ModuleName AroniumSync { }
        Mock Set-SyncShortcuts -ModuleName AroniumSync { }
        Mock Register-UpdateTask -ModuleName AroniumSync { }
        Mock Update-SyncRegistrations -ModuleName AroniumSync { }
        Mock Invoke-UpdateHttp -ModuleName AroniumSync { throw 'network must be mocked in tests' }
        Mock Stop-Process -ModuleName AroniumSync { throw 'Stop-Process must never be called' }
    }

    function New-TwoLaptops {
        # A sells, B views. B starts as an exact copy of A plus its own per-PC marker.
        param([string]$Kind)
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $mutex = 'Local\AroniumSyncTest-' + [guid]::NewGuid().ToString('N')
        $A = New-TestLaptop -Root $root -Name 'A' -Role seller -MutexName $mutex
        $B = New-TestLaptop -Root $root -Name 'B' -Role reader -MutexName $mutex
        New-FixtureDb -Kind $Kind -Path $A.dbPath
        Copy-Item -LiteralPath $A.dbPath -Destination $B.dbPath
        Set-TestMarker -Database $A.dbPath -Value 'seller'
        Set-TestMarker -Database $B.dbPath -Value 'reader'
        Set-BaselineStamp -Config $B -Now $script:Now
        return @{ A = $A; B = $B; Root = $root }
    }

    function Get-Latest { param($Config) Read-JsonFile (Join-Path $Config.oneDriveFolder 'latest.json') }
    function Get-Writer { param($Config) Read-JsonFile (Join-Path $Config.oneDriveFolder 'writer.json') }
    function Get-DocCount { param($Database) [int](Get-TestScalar -Database $Database -Sql 'SELECT count(*) FROM Document;') }
    function Get-Counters {
        param($Database)
        $h = @{}
        foreach ($l in (Invoke-TestSql -Database $Database -Sql "SELECT Name || '=' || Value FROM Counter ORDER BY Name;")) {
            $n, $v = $l.Split('=', 2); $h[$n] = [int64]$v
        }
        return $h
    }
}

Describe 'Publish (<Kind> DB)' -ForEach $Cases {
    BeforeEach {
        Initialize-Mocks
        $L = New-TwoLaptops -Kind $Kind
        $A = $L.A
    }

    It 'publishes a copy that passes integrity and matches latest.json and the source data' {
        Invoke-Publish -Config $A -Now $Now -HostName 'LAPTOP-A' | Should -Be 'published'
        $latestDb = Join-Path $A.oneDriveFolder 'latest.db'
        $latest = Get-Latest $A
        Test-SqliteIntegrity -Config $A -Database $latestDb | Should -BeTrue
        Get-FileSha256 $latestDb | Should -Be $latest.sha256
        $latest.fingerprint | Should -Be (Get-DataFingerprint -Config $A -Database $A.dbPath)
        $latest.host | Should -Be 'LAPTOP-A'
        $latest.published_at | Should -Match '^2026-11-26T10:00:00'
        @(Get-ChildItem (Join-Path $A.oneDriveFolder 'history') -Filter 'pos-*.db').Count | Should -Be 1
        (Get-Writer $A).host | Should -Be 'LAPTOP-A'
        @(Get-ChildItem $A.oneDriveFolder -Filter '*.uploading' -Force).Count | Should -Be 0
        Should -Invoke Show-SyncToast -ModuleName AroniumSync -Times 0 -Exactly
    }

    It 'only refreshes latest.json when nothing changed (heartbeat)' {
        Invoke-Publish -Config $A -Now $Now -HostName 'LAPTOP-A' | Should -Be 'published'
        $sha1 = (Get-Latest $A).sha256
        Invoke-Publish -Config $A -Now $Now.AddMinutes(15) -HostName 'LAPTOP-A' | Should -Be 'unchanged'
        (Get-Latest $A).sha256 | Should -Be $sha1
        (Get-Latest $A).published_at | Should -Match 'T10:15:00'
        @(Get-ChildItem (Join-Path $A.oneDriveFolder 'history') -Filter 'pos-*.db').Count | Should -Be 1
    }

    It 'publishes a new copy after a sale' {
        Invoke-Publish -Config $A -Now $Now -HostName 'LAPTOP-A' | Out-Null
        $sha1 = (Get-Latest $A).sha256
        Add-TestSale -Database $A.dbPath
        Invoke-Publish -Config $A -Now $Now.AddMinutes(15) -HostName 'LAPTOP-A' | Should -Be 'published'
        (Get-Latest $A).sha256 | Should -Not -Be $sha1
    }

    It 'prunes dated copies older than 30 days' {
        $hist = Join-Path $A.oneDriveFolder 'history'
        New-Item -ItemType Directory -Force -Path $hist | Out-Null
        $old = Join-Path $hist ('pos-' + $Now.AddDays(-40).ToString('yyyyMMdd-HHmmss') + '.db')
        $recent = Join-Path $hist ('pos-' + $Now.AddDays(-10).ToString('yyyyMMdd-HHmmss') + '.db')
        Set-Content -LiteralPath $old -Value 'x'; Set-Content -LiteralPath $recent -Value 'x'
        Invoke-Publish -Config $A -Now $Now -HostName 'LAPTOP-A' | Should -Be 'published'
        Test-Path -LiteralPath $old | Should -BeFalse
        Test-Path -LiteralPath $recent | Should -BeTrue
    }

    It 'refuses a corrupt database and toasts "Backup failed at HH:MM"' {
        $fs = [IO.File]::Open($A.dbPath, 'Open', 'ReadWrite')
        try {
            $junk = New-Object byte[] 16384
            (New-Object Random 7).NextBytes($junk)
            [void]$fs.Seek(4096, 'Begin'); $fs.Write($junk, 0, $junk.Length)
        } finally { $fs.Dispose() }
        Invoke-Publish -Config $A -Now $Now -HostName 'LAPTOP-A' | Should -Be 'failed'
        Test-Path (Join-Path $A.oneDriveFolder 'latest.json') | Should -BeFalse
        Test-Path (Join-Path $A.oneDriveFolder 'latest.db') | Should -BeFalse
        Should -Invoke Show-SyncToast -ModuleName AroniumSync -Times 1 -Exactly -ParameterFilter {
            $Kind -eq 'publish-failed' -and $Text -like 'Backup failed at 10:00: *'
        }
    }

    It 'toasts when the database is missing' {
        Remove-Item -LiteralPath $A.dbPath
        Invoke-Publish -Config $A -Now $Now -HostName 'LAPTOP-A' | Should -Be 'failed'
        Should -Invoke Show-SyncToast -ModuleName AroniumSync -Times 1 -Exactly -ParameterFilter { $Kind -eq 'publish-failed' }
    }
}

Describe 'Restore on the reader (<Kind> DB)' -ForEach $Cases {
    BeforeEach {
        Initialize-Mocks
        $L = New-TwoLaptops -Kind $Kind
        $A = $L.A; $B = $L.B
        $perPcBefore = Get-PerPcHash -Database $B.dbPath
        Add-TestSale -Database $A.dbPath
        Invoke-Publish -Config $A -Now $Now -HostName 'LAPTOP-A' | Should -Be 'published'
    }

    It 'restores silently: data from the new copy, per-PC tables kept from the old local file' {
        Invoke-Check -Config $B -Now $Now -HostName 'LAPTOP-B' | Should -Be 'restored'
        Get-DocCount $B.dbPath | Should -Be (Get-DocCount $A.dbPath)
        Get-DataFingerprint -Config $B -Database $B.dbPath | Should -Be (Get-DataFingerprint -Config $A -Database $A.dbPath)
        Get-TestMarker -Database $B.dbPath | Should -Be 'reader'
        Get-PerPcHash -Database $B.dbPath | Should -Be $perPcBefore
        Test-SqliteIntegrity -Config $B -Database $B.dbPath | Should -BeTrue
        @(Get-ChildItem $B.backupDir -Filter 'pos-*.bak').Count | Should -Be 1
        (Get-RestoreStamp -Config $B).sha256 | Should -Be (Get-Latest $A).sha256
        Test-Path ($B.dbPath + '.incoming') | Should -BeFalse
        Should -Invoke Show-SyncToast -ModuleName AroniumSync -Times 0 -Exactly
    }

    It 'is up to date on the next run' {
        Invoke-Check -Config $B -Now $Now | Should -Be 'restored'
        Invoke-Check -Config $B -Now $Now.AddMinutes(5) | Should -Be 'up-to-date'
    }

    It 'keeps only the last 10 .bak files' {
        New-Item -ItemType Directory -Force -Path $B.backupDir | Out-Null
        1..12 | ForEach-Object { Set-Content -LiteralPath (Join-Path $B.backupDir ('pos-202601{0:D2}-090000.bak' -f $_)) -Value 'x' }
        Invoke-Check -Config $B -Now $Now | Should -Be 'restored'
        $baks = @(Get-ChildItem $B.backupDir -Filter 'pos-*.bak' | Sort-Object Name)
        $baks.Count | Should -Be 10
        $baks[-1].Name | Should -Be 'pos-20261126-100000.bak'
    }

    It 'refuses to restore while Aronium is running' {
        Mock Get-AroniumProcess -ModuleName AroniumSync { [pscustomobject]@{ Id = 1 } }
        $in = Join-Path $L.Root 'in.db'
        Copy-Item (Join-Path $A.oneDriveFolder 'latest.db') $in
        { Invoke-Restore -Config $B -IncomingPath $in -ExpectedSha (Get-Latest $A).sha256 } | Should -Throw '*Aronium is running*'
    }

    It 'refuses to restore when a -journal file exists' {
        Set-Content -LiteralPath ($B.dbPath + '-journal') -Value 'x'
        $shaBefore = Get-FileSha256 $B.dbPath
        $in = Join-Path $L.Root 'in.db'
        Copy-Item (Join-Path $A.oneDriveFolder 'latest.db') $in
        { Invoke-Restore -Config $B -IncomingPath $in -ExpectedSha (Get-Latest $A).sha256 } | Should -Throw '*journal*'
        Invoke-Check -Config $B -Now $Now | Should -Be 'failed'
        Get-FileSha256 $B.dbPath | Should -Be $shaBefore
    }

    It 'asks with [Update now] [Later] when Aronium is open, and Later waits for the next copy' {
        Mock Get-AroniumProcess -ModuleName AroniumSync { [pscustomobject]@{ Id = 1 } }
        Invoke-Check -Config $B -Now $Now | Should -Be 'notified'
        Should -Invoke Show-SyncToast -ModuleName AroniumSync -Times 1 -Exactly -ParameterFilter {
            $Kind -eq 'update' -and $Text -eq 'New data from the main laptop (as of 10:00). Restart Aronium to see it.' -and
            ($Buttons -join ',') -eq 'update-now,later'
        }
        Invoke-Check -Config $B -Now $Now.AddMinutes(5) | Should -Be 'notified'
        Should -Invoke Show-SyncToast -ModuleName AroniumSync -Times 1 -Exactly

        Invoke-ProtocolAction -Config $B -Uri 'aronium-sync:later' | Should -Be 'later'
        # past the 60-min re-ask window, but Later holds until a new copy arrives
        Invoke-Check -Config $B -Now $Now.AddMinutes(65) | Should -Be 'later'
        Should -Invoke Show-SyncToast -ModuleName AroniumSync -Times 0 -Exactly -ParameterFilter { $Kind -eq 'update' -and $Text -notlike 'New data*10:00*' }
        Should -Invoke Show-SyncToast -ModuleName AroniumSync -Times 1 -Exactly -ParameterFilter { $Kind -eq 'update' }

        Add-TestSale -Database $A.dbPath
        Invoke-Publish -Config $A -Now $Now.AddMinutes(70) -HostName 'LAPTOP-A' | Should -Be 'published'
        Invoke-Check -Config $B -Now $Now.AddMinutes(71) | Should -Be 'notified'
        Should -Invoke Show-SyncToast -ModuleName AroniumSync -Times 2 -Exactly -ParameterFilter { $Kind -eq 'update' }
    }
}

Describe 'Divergence check (<Kind> DB)' -ForEach $Cases {
    BeforeEach {
        Initialize-Mocks
        $L = New-TwoLaptops -Kind $Kind
        $A = $L.A; $B = $L.B
        Add-TestSale -Database $A.dbPath
        Invoke-Publish -Config $A -Now $Now -HostName 'LAPTOP-A' | Out-Null
    }

    It 'negative: no local sales, so no pause and the copy is restored' {
        (Test-Divergence -Config $B -Latest (Get-Latest $A)).Diverged | Should -BeFalse
        Invoke-Check -Config $B -Now $Now | Should -Be 'restored'
        Test-Path $B.pauseFlag | Should -BeFalse
    }

    It 'positive: a sale on the reader pauses sync with a persistent toast and leaves pos.db alone' {
        Add-TestSale -Database $B.dbPath -When '2026-11-26 09:30:00'
        $shaBefore = Get-FileSha256 $B.dbPath
        (Test-Divergence -Config $B -Latest (Get-Latest $A)).Diverged | Should -BeTrue
        Invoke-Check -Config $B -Now $Now | Should -Be 'paused'
        Test-Path $B.pauseFlag | Should -BeTrue
        Get-FileSha256 $B.dbPath | Should -Be $shaBefore
        Should -Invoke Show-SyncToast -ModuleName AroniumSync -Times 1 -Exactly -ParameterFilter {
            $Kind -eq 'diverged' -and $Persistent -and -not $Buttons -and
            $Text -eq "Sales were recorded on this laptop. Sync is paused so they aren't lost. Call Owner 0917-000-0000."
        }
        # stays paused, toast not repeated within the hour
        Invoke-Check -Config $B -Now $Now.AddMinutes(5) | Should -Be 'paused'
        Get-FileSha256 $B.dbPath | Should -Be $shaBefore
        Should -Invoke Show-SyncToast -ModuleName AroniumSync -Times 1 -Exactly
    }

    It 'a product edit on the reader (no new sale) is also caught' {
        Invoke-TestSql -Database $B.dbPath -Sql "UPDATE Product SET DateUpdated = '2026-11-26 09:45:00' WHERE Id = (SELECT min(Id) FROM Product);" | Out-Null
        Invoke-Check -Config $B -Now $Now | Should -Be 'paused'
    }

    It 'clearing the flag lets the next run restore, keeping the local sales in a .bak' {
        Add-TestSale -Database $B.dbPath -When '2026-11-26 09:30:00'
        $localDocs = Get-DocCount $B.dbPath
        Invoke-Check -Config $B -Now $Now | Should -Be 'paused'
        Remove-Item -LiteralPath $B.pauseFlag
        Invoke-Check -Config $B -Now $Now.AddMinutes(5) | Should -Be 'restored'
        Get-DataFingerprint -Config $B -Database $B.dbPath | Should -Be (Get-DataFingerprint -Config $A -Database $A.dbPath)
        $bak = @(Get-ChildItem $B.backupDir -Filter 'pos-*.bak')[0].FullName
        Get-DocCount $bak | Should -Be $localDocs
    }

    It 'pauses again if more sales are made after the flag was cleared but before a restore' {
        Mock Get-AroniumProcess -ModuleName AroniumSync { [pscustomobject]@{ Id = 1 } }
        Add-TestSale -Database $B.dbPath -When '2026-11-26 09:30:00'
        Invoke-Check -Config $B -Now $Now | Should -Be 'paused'
        Remove-Item -LiteralPath $B.pauseFlag
        Invoke-Check -Config $B -Now $Now.AddMinutes(5) | Should -Be 'notified'
        Add-TestSale -Database $B.dbPath -When '2026-11-26 10:07:00'
        Invoke-Check -Config $B -Now $Now.AddMinutes(10) | Should -Be 'paused'
    }

    It 'clearing the flag restores even when no newer copy has been published since' {
        Invoke-Check -Config $B -Now $Now | Should -Be 'restored'
        Add-TestSale -Database $B.dbPath -When '2026-11-26 10:02:00'
        Invoke-Check -Config $B -Now $Now.AddMinutes(5) | Should -Be 'paused'
        Remove-Item -LiteralPath $B.pauseFlag
        Invoke-Check -Config $B -Now $Now.AddMinutes(10) | Should -Be 'restored'
        Get-DataFingerprint -Config $B -Database $B.dbPath | Should -Be (Get-DataFingerprint -Config $A -Database $A.dbPath)
        Invoke-Check -Config $B -Now $Now.AddMinutes(15) | Should -Be 'up-to-date'
    }

    It 'with no restore stamp, a local DB that differs from the published copy pauses' {
        Remove-Item -LiteralPath (Join-Path $B.stateDir 'restore-stamp.json')
        Invoke-Check -Config $B -Now $Now | Should -Be 'paused'
    }

    It 'with no restore stamp and no local DB, the first copy is restored' {
        Remove-Item -LiteralPath (Join-Path $B.stateDir 'restore-stamp.json')
        Remove-Item -LiteralPath $B.dbPath
        Invoke-Check -Config $B -Now $Now | Should -Be 'restored'
        Test-Path $B.dbPath | Should -BeTrue
    }
}

Describe 'OneDrive mid-sync (<Kind> DB)' -ForEach $Cases {
    BeforeEach {
        Initialize-Mocks
        $L = New-TwoLaptops -Kind $Kind
        $A = $L.A; $B = $L.B
        Add-TestSale -Database $A.dbPath
        Invoke-Publish -Config $A -Now $Now -HostName 'LAPTOP-A' | Out-Null
    }

    It 'waits when latest.db does not match latest.json, then restores once it does' {
        $latestDb = Join-Path $A.oneDriveFolder 'latest.db'
        $good = Join-Path $L.Root 'good.db'
        Copy-Item $latestDb $good
        $fs = [IO.File]::Open($latestDb, 'Open', 'ReadWrite')
        try { $fs.SetLength($fs.Length - 1024) } finally { $fs.Dispose() }   # half-downloaded file
        $shaBefore = Get-FileSha256 $B.dbPath

        Invoke-Check -Config $B -Now $Now | Should -Be 'waiting'
        Get-FileSha256 $B.dbPath | Should -Be $shaBefore
        (Get-RestoreStamp -Config $B).kind | Should -Be 'baseline'

        Copy-Item $good $latestDb -Force                                       # OneDrive finishes
        Invoke-Check -Config $B -Now $Now.AddMinutes(5) | Should -Be 'restored'
        Get-DataFingerprint -Config $B -Database $B.dbPath | Should -Be (Get-DataFingerprint -Config $A -Database $A.dbPath)
    }
}

Describe 'Stale main laptop' {
    BeforeEach {
        Initialize-Mocks
        $L = New-TwoLaptops -Kind 'synthetic'
        $A = $L.A; $B = $L.B
        Invoke-Publish -Config $A -Now $Now.AddMinutes(-75) -HostName 'LAPTOP-A' | Out-Null
    }

    It 'toasts once with a [Take over] button when the last publish is over 60 min old in shop hours' {
        Invoke-Check -Config $B -Now $Now | Out-Null
        Should -Invoke Show-SyncToast -ModuleName AroniumSync -Times 1 -Exactly -ParameterFilter {
            $Kind -eq 'stale' -and ($Buttons -join ',') -eq 'takeover' -and
            $Text -eq "Main laptop last synced at 08:45. If it's down, use Take over."
        }
        Invoke-Check -Config $B -Now $Now.AddMinutes(5) | Out-Null
        Should -Invoke Show-SyncToast -ModuleName AroniumSync -Times 1 -Exactly -ParameterFilter { $Kind -eq 'stale' }
    }

    It 'does not raise the alarm at opening just because the seller is not on yet' {
        Invoke-Publish -Config $A -Now ([datetime]'2026-11-25T20:00:00') -HostName 'LAPTOP-A' | Out-Null
        Invoke-Check -Config $B -Now ([datetime]'2026-11-26T08:30:00') | Out-Null
        Should -Invoke Show-SyncToast -ModuleName AroniumSync -Times 0 -Exactly -ParameterFilter { $Kind -eq 'stale' }
        Invoke-Check -Config $B -Now ([datetime]'2026-11-26T09:05:00') | Out-Null
        Should -Invoke Show-SyncToast -ModuleName AroniumSync -Times 1 -Exactly -ParameterFilter {
            $Kind -eq 'stale' -and $Text -eq "Main laptop last synced at Wed 20:00. If it's down, use Take over."
        }
    }

    It 'does not toast outside shop hours' {
        Invoke-Check -Config $B -Now ([datetime]'2026-11-26T22:30:00') | Out-Null
        Should -Invoke Show-SyncToast -ModuleName AroniumSync -Times 0 -Exactly -ParameterFilter { $Kind -eq 'stale' }
    }
}

Describe 'Update now' {
    BeforeEach {
        Initialize-Mocks
        $L = New-TwoLaptops -Kind 'synthetic'
        $A = $L.A; $B = $L.B
        Add-TestSale -Database $A.dbPath
        Invoke-Publish -Config $A -Now $Now -HostName 'LAPTOP-A' | Out-Null
        $global:AroniumSyncTestRunning = $true
        Mock Get-AroniumProcess -ModuleName AroniumSync { if ($global:AroniumSyncTestRunning) { [pscustomobject]@{ Id = 1 } } }
    }
    AfterEach { Remove-Variable -Name AroniumSyncTestRunning -Scope Global -ErrorAction SilentlyContinue }

    It 'closes Aronium gracefully, restores, and relaunches it' {
        Mock Close-AroniumGracefully -ModuleName AroniumSync { $global:AroniumSyncTestRunning = $false; $true }
        Invoke-UpdateNow -Config $B -Now $Now | Should -Be 'restored'
        Get-DataFingerprint -Config $B -Database $B.dbPath | Should -Be (Get-DataFingerprint -Config $A -Database $A.dbPath)
        Should -Invoke Close-AroniumGracefully -ModuleName AroniumSync -Times 1 -Exactly -ParameterFilter { $TimeoutSeconds -eq 30 }
        Should -Invoke Start-Aronium -ModuleName AroniumSync -Times 1 -Exactly
        Should -Invoke Stop-Process -ModuleName AroniumSync -Times 0 -Exactly
    }

    It 'never force-kills: if Aronium stays open it toasts "Please close Aronium" and changes nothing' {
        Mock Close-AroniumGracefully -ModuleName AroniumSync { $false }
        $shaBefore = Get-FileSha256 $B.dbPath
        Invoke-UpdateNow -Config $B -Now $Now | Should -Be 'aronium-open'
        Get-FileSha256 $B.dbPath | Should -Be $shaBefore
        Should -Invoke Show-SyncToast -ModuleName AroniumSync -Times 1 -Exactly -ParameterFilter { $Text -like 'Please close Aronium*' }
        Should -Invoke Stop-Process -ModuleName AroniumSync -Times 0 -Exactly
        Should -Invoke Start-Aronium -ModuleName AroniumSync -Times 0 -Exactly
    }

    It 'Close-AroniumGracefully itself never calls Stop-Process' {
        $src = (Get-Command Close-AroniumGracefully -Module AroniumSync).Definition
        $src | Should -Not -Match 'Stop-Process|\.Kill\('
    }
}

Describe 'Take over (<Kind> DB)' -ForEach $Cases {
    BeforeEach {
        Initialize-Mocks
        $L = New-TwoLaptops -Kind $Kind
        $A = $L.A; $B = $L.B
        Add-TestSale -Database $A.dbPath
        Invoke-Publish -Config $A -Now $Now -HostName 'LAPTOP-A' | Out-Null
        $sellerCounters = Get-Counters $A.dbPath
    }

    It 'after Yes: restores, bumps every Counter row by 500, writes writer.json, becomes seller' {
        Mock Show-ConfirmBox -ModuleName AroniumSync { $true }
        Invoke-Takeover -Config $B -Now $Now.AddMinutes(90) -HostName 'LAPTOP-B' | Should -Be 'taken-over'
        Should -Invoke Show-ConfirmBox -ModuleName AroniumSync -Times 1 -Exactly -ParameterFilter {
            $Text -eq 'This makes THIS laptop the selling laptop. Receipt numbers jump by 500. Continue?'
        }
        $after = Get-Counters $B.dbPath
        $after.Count | Should -Be $sellerCounters.Count
        $after.Count | Should -BeGreaterThan 0
        foreach ($k in $sellerCounters.Keys) { $after[$k] | Should -Be ($sellerCounters[$k] + 500) }
        Get-DocCount $B.dbPath | Should -Be (Get-DocCount $A.dbPath)
        $w = Get-Writer $B
        $w.host | Should -Be 'LAPTOP-B'
        $w.previous_host | Should -Be 'LAPTOP-A'
        (Get-SyncConfig -Path $B.configPath).role | Should -Be 'seller'
        Should -Invoke Register-SyncTasks -ModuleName AroniumSync -Times 1 -Exactly -ParameterFilter { $Role -eq 'seller' }
        (Get-Latest $B).host | Should -Be 'LAPTOP-B'
        Get-TestMarker -Database $B.dbPath | Should -Be 'reader'
    }

    It 'after No: changes nothing' {
        $shaBefore = Get-FileSha256 $B.dbPath
        Invoke-Takeover -Config $B -Now $Now -HostName 'LAPTOP-B' | Should -Be 'cancelled'
        Get-FileSha256 $B.dbPath | Should -Be $shaBefore
        (Get-Writer $B).host | Should -Be 'LAPTOP-A'
        (Get-SyncConfig -Path $B.configPath).role | Should -Be 'reader'
        Should -Invoke Register-SyncTasks -ModuleName AroniumSync -Times 0 -Exactly
    }

    It 'when the reader has its own sales, keeps them (no restore) and still bumps counters' {
        Mock Show-ConfirmBox -ModuleName AroniumSync { $true }
        Add-TestSale -Database $B.dbPath -When '2026-11-26 09:30:00'
        $localDocs = Get-DocCount $B.dbPath
        $localCounters = Get-Counters $B.dbPath
        Invoke-Takeover -Config $B -Now $Now -HostName 'LAPTOP-B' | Should -Be 'taken-over'
        Get-DocCount $B.dbPath | Should -Be $localDocs
        $after = Get-Counters $B.dbPath
        foreach ($k in $localCounters.Keys) { $after[$k] | Should -Be ($localCounters[$k] + 500) }
    }

    It 'the old seller stops publishing after a takeover and toasts instead' {
        Mock Show-ConfirmBox -ModuleName AroniumSync { $true }
        Invoke-Takeover -Config $B -Now $Now.AddMinutes(90) -HostName 'LAPTOP-B' | Should -Be 'taken-over'
        $latestBefore = Get-Latest $B
        Add-TestSale -Database $A.dbPath
        Invoke-Publish -Config $A -Now $Now.AddMinutes(100) -HostName 'LAPTOP-A' | Should -Be 'not-writer'
        $latestAfter = Get-Latest $B
        $latestAfter.sha256 | Should -Be $latestBefore.sha256
        $latestAfter.host | Should -Be 'LAPTOP-B'
        Should -Invoke Show-SyncToast -ModuleName AroniumSync -Times 1 -Exactly -ParameterFilter {
            $Kind -eq 'not-writer' -and $Text -like 'This laptop is no longer the selling laptop*'
        }
    }

    It 'running Take over again on the laptop that is already the seller does nothing' {
        Mock Show-ConfirmBox -ModuleName AroniumSync { $true }
        Invoke-Takeover -Config $B -Now $Now -HostName 'LAPTOP-B' | Should -Be 'taken-over'
        $countersAfterFirst = Get-Counters $B.dbPath
        Invoke-Takeover -Config $B -Now $Now.AddMinutes(1) -HostName 'LAPTOP-B' | Should -Be 'already-seller'
        $again = Get-Counters $B.dbPath
        foreach ($k in $countersAfterFirst.Keys) { $again[$k] | Should -Be $countersAfterFirst[$k] }
        Should -Invoke Show-ConfirmBox -ModuleName AroniumSync -Times 1 -Exactly
    }

    It 'does nothing if Aronium will not close' {
        Mock Show-ConfirmBox -ModuleName AroniumSync { $true }
        Mock Get-AroniumProcess -ModuleName AroniumSync { [pscustomobject]@{ Id = 1 } }
        Mock Close-AroniumGracefully -ModuleName AroniumSync { $false }
        $shaBefore = Get-FileSha256 $B.dbPath
        Invoke-Takeover -Config $B -Now $Now -HostName 'LAPTOP-B' | Should -Be 'aronium-open'
        Get-FileSha256 $B.dbPath | Should -Be $shaBefore
        (Get-Writer $B).host | Should -Be 'LAPTOP-A'
        Should -Invoke Stop-Process -ModuleName AroniumSync -Times 0 -Exactly
    }
}

Describe 'Protocol handler' {
    BeforeEach {
        Initialize-Mocks
        $L = New-TwoLaptops -Kind 'synthetic'
        $B = $L.B
        Mock Invoke-UpdateNow -ModuleName AroniumSync { 'restored' }
        Mock Set-LaterAction -ModuleName AroniumSync { }
        Mock Invoke-Takeover -ModuleName AroniumSync { 'cancelled' }
    }

    It 'accepts <Uri>' -ForEach @(
        @{ Uri = 'aronium-sync:update-now'; Want = 'update-now' }
        @{ Uri = 'aronium-sync:later'; Want = 'later' }
        @{ Uri = 'aronium-sync:takeover'; Want = 'takeover' }
        @{ Uri = 'aronium-sync://takeover/'; Want = 'takeover' }
        @{ Uri = 'ARONIUM-SYNC:later'; Want = 'later' }
    ) {
        ConvertTo-SyncAction -Uri $Uri | Should -Be $Want
    }

    It 'rejects <Uri>' -ForEach @(
        @{ Uri = 'aronium-sync:rm' }
        @{ Uri = 'aronium-sync:takeover;calc.exe' }
        @{ Uri = 'aronium-sync:update-now&calc' }
        @{ Uri = 'aronium-sync:update-now --force' }
        @{ Uri = 'aronium-sync:TAKEOVER' }
        @{ Uri = 'aronium-sync:../takeover' }
        @{ Uri = 'aronium-sync:takeover?x=1' }
        @{ Uri = "aronium-sync:later`r`ncalc" }
        @{ Uri = 'http://example.com/takeover' }
        @{ Uri = 'takeover' }
        @{ Uri = '' }
        @{ Uri = ('aronium-sync:' + ('a' * 100)) }
    ) {
        ConvertTo-SyncAction -Uri $Uri | Should -BeNullOrEmpty
    }

    It 'rejects $null' {
        ConvertTo-SyncAction -Uri $null | Should -BeNullOrEmpty
    }

    It 'runs nothing for an unknown action and logs it' {
        Invoke-ProtocolAction -Config $B -Uri 'aronium-sync:format-c' | Should -Be 'rejected'
        Should -Invoke Invoke-UpdateNow -ModuleName AroniumSync -Times 0 -Exactly
        Should -Invoke Set-LaterAction -ModuleName AroniumSync -Times 0 -Exactly
        Should -Invoke Invoke-Takeover -ModuleName AroniumSync -Times 0 -Exactly
        [IO.File]::ReadAllText($B.logPath) | Should -Match "Ignored unknown protocol action 'aronium-sync:format-c'"
    }

    It 'dispatches each whitelisted action to its own function' {
        Invoke-ProtocolAction -Config $B -Uri 'aronium-sync:update-now' | Should -Be 'update-now'
        Invoke-ProtocolAction -Config $B -Uri 'aronium-sync:later' | Should -Be 'later'
        Invoke-ProtocolAction -Config $B -Uri 'aronium-sync:takeover' | Should -Be 'takeover'
        Should -Invoke Invoke-UpdateNow -ModuleName AroniumSync -Times 1 -Exactly
        Should -Invoke Set-LaterAction -ModuleName AroniumSync -Times 1 -Exactly
        Should -Invoke Invoke-Takeover -ModuleName AroniumSync -Times 1 -Exactly
    }
}

Describe 'Take over button always goes through the confirm box' {
    BeforeEach {
        Initialize-Mocks
        $L = New-TwoLaptops -Kind 'synthetic'
        $A = $L.A; $B = $L.B
        Invoke-Publish -Config $A -Now $Now -HostName 'LAPTOP-A' | Out-Null
    }

    It 'a single click on [Take over] with No in the box changes nothing' {
        Invoke-ProtocolAction -Config $B -Uri 'aronium-sync:takeover' | Should -Be 'takeover'
        Should -Invoke Show-ConfirmBox -ModuleName AroniumSync -Times 1 -Exactly
        (Get-Writer $B).host | Should -Be 'LAPTOP-A'
        (Get-SyncConfig -Path $B.configPath).role | Should -Be 'reader'
    }
}

Describe 'Install pieces (generated only, nothing registered)' {
    It 'seller task runs every 15 min as the logged-on user, with a shutdown event trigger' {
        [xml]$x = Get-SyncTaskXml -Role seller -ScriptPath 'C:\x\publish.ps1' -UserId 'PC\shop'
        $x.Task.Principals.Principal.LogonType | Should -Be 'InteractiveToken'
        $x.Task.Triggers.TimeTrigger.Repetition.Interval | Should -Be 'PT15M'
        $x.Task.Triggers.EventTrigger.Subscription | Should -Match 'EventID=1074'
        $x.Task.Actions.Exec.Arguments | Should -Match 'publish\.ps1'
    }

    It 'seller logon trigger waits 2-5 min so OneDrive can bring down writer.json first' {
        [xml]$x = Get-SyncTaskXml -Role seller -ScriptPath 'C:\x\publish.ps1' -UserId 'PC\shop'
        $x.Task.Triggers.LogonTrigger.Delay | Should -Match '^PT[2-5]M$'
    }

    It 'reader task runs every 5 min as the logged-on user' {
        [xml]$x = Get-SyncTaskXml -Role reader -ScriptPath 'C:\x\check.ps1' -UserId 'PC\shop'
        $x.Task.Principals.Principal.LogonType | Should -Be 'InteractiveToken'
        $x.Task.Triggers.TimeTrigger.Repetition.Interval | Should -Be 'PT5M'
        $x.Task.Triggers.PSObject.Properties.Name | Should -Not -Contain 'EventTrigger'
    }

    It 'protocol command passes the URL as one quoted argument to the handler script only' {
        $cmd = Get-ProtocolCommand -HandlerScript 'C:\x\protocol-handler.ps1'
        $cmd | Should -Match '-File "C:\\x\\protocol-handler\.ps1" "%1"$'
        $cmd | Should -Not -Match '-Command'
    }
}

Describe 'Fingerprint' -ForEach $Cases {
    It 'ignores per-PC tables (<Kind> DB)' {
        $db = Join-Path $TestDrive ('fp-' + [guid]::NewGuid().ToString('N') + '.db')
        New-FixtureDb -Kind $Kind -Path $db
        $cfg = @{ sqlitePath = $SqliteExe }
        $before = Get-DataFingerprint -Config $cfg -Database $db
        Set-TestMarker -Database $db -Value 'changed'
        Get-DataFingerprint -Config $cfg -Database $db | Should -Be $before
        Add-TestSale -Database $db
        Get-DataFingerprint -Config $cfg -Database $db | Should -Not -Be $before
        $before.Split(';').Count | Should -Be 8
        $before | Should -Not -Match 'missing'
    }
}

Describe 'sqlite3 stdin encoding' {
    It 'works when the console input encoding is UTF-8 with a BOM (code page 65001)' {
        $L = New-TwoLaptops -Kind 'synthetic'
        $old = [Console]::InputEncoding
        try {
            [Console]::InputEncoding = New-Object System.Text.UTF8Encoding $true
            $r = InModuleScope AroniumSync -Parameters @{ C = $L.A } { param($C) Invoke-Sqlite -Config $C -Database $C.dbPath -Sql 'SELECT 41+1;' -ReadOnly }
            $r | Should -Be '42'
        } finally { [Console]::InputEncoding = $old }
    }
}

Describe 'Example config' {
    It 'config.example.json parses and its paths expand' {
        $c = Get-SyncConfig -Path (Join-Path $RepoRoot 'config.example.json')
        $c.dbPath | Should -BeLike '*\Aronium\Data\pos.db'
        $c.dbPath | Should -Not -BeLike '*%LOCALAPPDATA%*'
        $c.oneDriveFolder | Should -BeLike '*\aronium'
    }
}

Describe 'Boot race after a takeover (<Kind> DB)' -ForEach $Cases {
    BeforeEach {
        Initialize-Mocks
        Mock Show-ConfirmBox -ModuleName AroniumSync { $true }
        $L = New-TwoLaptops -Kind $Kind
        $A = $L.A; $B = $L.B
        Invoke-Publish -Config $A -Now $Now -HostName 'LAPTOP-A' | Should -Be 'published'
        Invoke-Takeover -Config $B -Now $Now.AddMinutes(90) -HostName 'LAPTOP-B' | Should -Be 'taken-over'
        # A boots. OneDrive has brought down latest.json but not the new writer.json yet.
        Write-JsonFile -Path (Join-Path $A.oneDriveFolder 'writer.json') -Object ([pscustomobject]@{ host = 'LAPTOP-A'; since = (Format-SyncTime $Now) })
        $latestBefore = Get-Latest $B
        $historyBefore = @(Get-ChildItem (Join-Path $A.oneDriveFolder 'history')).Count
    }

    It 'the stale old seller does not overwrite the new copy and toasts instead' {
        Add-TestSale -Database $A.dbPath
        Invoke-Publish -Config $A -Now $Now.AddMinutes(100) -HostName 'LAPTOP-A' | Should -Be 'not-writer'
        $after = Get-Latest $B
        $after.sha256 | Should -Be $latestBefore.sha256
        $after.host | Should -Be 'LAPTOP-B'
        @(Get-ChildItem (Join-Path $A.oneDriveFolder 'history')).Count | Should -Be $historyBefore
        Should -Invoke Show-SyncToast -ModuleName AroniumSync -Times 1 -Exactly -ParameterFilter {
            $Kind -eq 'not-writer' -and $Persistent -and $Text -like 'This laptop is no longer the selling laptop*'
        }
    }

    It 'the new seller keeps publishing once writer.json has caught up' {
        Write-JsonFile -Path (Join-Path $B.oneDriveFolder 'writer.json') -Object ([pscustomobject]@{ host = 'LAPTOP-B'; since = (Format-SyncTime $Now.AddMinutes(90)) })
        Add-TestSale -Database $B.dbPath
        Invoke-Publish -Config $B -Now $Now.AddMinutes(105) -HostName 'LAPTOP-B' | Should -Be 'published'
    }
}

Describe 'Restore fail-safe' {
    BeforeEach {
        Initialize-Mocks
        $L = New-TwoLaptops -Kind 'synthetic'
        $A = $L.A; $B = $L.B
        Add-TestSale -Database $A.dbPath
        Invoke-Publish -Config $A -Now $Now -HostName 'LAPTOP-A' | Out-Null
        $exe = Join-Path $L.Root 'Aronium.Pos.exe'
        Set-Content -LiteralPath $exe -Value 'not really a program'
        $B.aroniumExe = $exe
        $in = Join-Path $L.Root 'in.db'
        Copy-Item (Join-Path $A.oneDriveFolder 'latest.db') $in
        $shaBefore = Get-FileSha256 $B.dbPath
    }

    It 'treats Aronium as running when its program file is in use, even if no process matched' {
        $hold = [IO.File]::Open($exe, 'Open', 'Read', 'Read')   # a running .exe is held like this
        try {
            { Invoke-Restore -Config $B -IncomingPath $in -ExpectedSha (Get-Latest $A).sha256 } | Should -Throw '*program file is in use*'
            Invoke-Check -Config $B -Now $Now | Should -Be 'notified'
        } finally { $hold.Dispose() }
        Get-FileSha256 $B.dbPath | Should -Be $shaBefore
    }

    It 'treats Aronium as running when pos.db is held open by another program' {
        $hold = [IO.File]::Open($B.dbPath, 'Open', 'ReadWrite', 'ReadWrite')   # how sqlite holds it
        try {
            { Invoke-Restore -Config $B -IncomingPath $in -ExpectedSha (Get-Latest $A).sha256 } | Should -Throw '*pos.db is open*'
        } finally { $hold.Dispose() }
        Get-FileSha256 $B.dbPath | Should -Be $shaBefore
    }

    It 'treats Aronium as running when the process list cannot be read' {
        Mock Get-AroniumProcess -ModuleName AroniumSync { throw 'access denied' }
        { Invoke-Restore -Config $B -IncomingPath $in -ExpectedSha (Get-Latest $A).sha256 } | Should -Throw '*could not list processes*'
        Get-FileSha256 $B.dbPath | Should -Be $shaBefore
    }

    It 'restores normally when the program file exists but nothing holds it' {
        Invoke-Check -Config $B -Now $Now | Should -Be 'restored'
    }
}

Describe 'Finding Aronium by name and by exe path (real process list)' {
    BeforeEach {
        $self = Get-Process -Id $PID
        $cfg = @{ aroniumProcessName = 'NoSuchAroniumProcess'; aroniumExe = $self.Path }
    }

    It 'Get-AroniumProcess finds the program by its exe path when the configured name is wrong' {
        @(Get-AroniumProcess -Config $cfg | Where-Object { $_.Id -eq $PID }).Count | Should -Be 1
    }

    It 'install check: ok when a live process has the configured name' {
        $cfg.aroniumProcessName = $self.ProcessName
        (Test-AroniumProcessName -Config $cfg).Status | Should -Be 'ok'
    }

    It 'install check: mismatch names the real process when Aronium runs under another name' {
        $r = Test-AroniumProcessName -Config $cfg
        $r.Status | Should -Be 'mismatch'
        $r.Names | Should -Contain $self.ProcessName
    }

    It 'install check: not-running when nothing matches' {
        $cfg.aroniumExe = 'C:\nowhere\NotHere.exe'
        (Test-AroniumProcessName -Config $cfg).Status | Should -Be 'not-running'
    }
}

Describe 'Seller switch guard and hand-back (<Kind> DB)' -ForEach $Cases {
    BeforeEach {
        Initialize-Mocks
        Mock Show-ConfirmBox -ModuleName AroniumSync { $true }
        $L = New-TwoLaptops -Kind $Kind
        $A = $L.A; $B = $L.B
        $counters0 = Get-Counters $A.dbPath
        Invoke-Publish -Config $A -Now $Now -HostName 'LAPTOP-A' | Out-Null
        Invoke-Takeover -Config $B -Now $Now.AddMinutes(90) -HostName 'LAPTOP-B' | Should -Be 'taken-over'
        Add-TestSale -Database $B.dbPath
        Invoke-Publish -Config $B -Now $Now.AddMinutes(95) -HostName 'LAPTOP-B' | Should -Be 'published'
        (Get-Item -LiteralPath $A.dbPath).LastWriteTime = $Now   # A was switched off before the takeover
    }

    It 'refuses to make the stale old seller the seller again and points to the README' {
        Get-SellerSwitchBlock -Config $A -HostName 'LAPTOP-A' | Should -BeLike '*LAPTOP-B*Give the selling role back*'
        $r = Set-SyncRole -Config $A -Role seller -HostName 'LAPTOP-A' -Now $Now.AddMinutes(100)
        $r.Status | Should -Be 'refused'
        (Get-Writer $B).host | Should -Be 'LAPTOP-B'
        (Get-Latest $B).host | Should -Be 'LAPTOP-B'
        (Get-SyncConfig -Path $A.configPath).role | Should -Be 'seller'
    }

    It '-Force overrides the guard' {
        $r = Set-SyncRole -Config $A -Role seller -Force -HostName 'LAPTOP-A' -Now $Now.AddMinutes(100)
        $r.Status | Should -Be 'seller'
        (Get-Writer $B).host | Should -Be 'LAPTOP-A'
    }

    It 'does not refuse once this laptop holds the same data as the published copy' {
        (Set-SyncRole -Config $A -Role reader -HostName 'LAPTOP-A' -Now $Now.AddMinutes(100)).Status | Should -Be 'reader'
        Invoke-Check -Config $A -Now $Now.AddMinutes(100) -HostName 'LAPTOP-A' | Should -Be 'restored'
        (Get-Item -LiteralPath $A.dbPath).LastWriteTime = $Now
        Get-SellerSwitchBlock -Config $A -HostName 'LAPTOP-A' | Should -BeNullOrEmpty
    }

    It 'hand-back (reader, restore, Take over) keeps the sales from B and moves receipt numbers on again' {
        $bDocs = Get-DocCount $B.dbPath
        (Set-SyncRole -Config $A -Role reader -HostName 'LAPTOP-A' -Now $Now.AddMinutes(100)).Status | Should -Be 'reader'
        (Get-SyncConfig -Path $A.configPath).role | Should -Be 'reader'
        Should -Invoke Register-SyncTasks -ModuleName AroniumSync -Times 1 -Exactly -ParameterFilter { $Role -eq 'reader' }
        Invoke-Check -Config $A -Now $Now.AddMinutes(100) -HostName 'LAPTOP-A' | Should -Be 'restored'
        Get-DocCount $A.dbPath | Should -Be $bDocs

        Invoke-Takeover -Config $A -Now $Now.AddMinutes(110) -HostName 'LAPTOP-A' | Should -Be 'taken-over'
        $after = Get-Counters $A.dbPath
        foreach ($k in $counters0.Keys) { $after[$k] | Should -Be ($counters0[$k] + 1000) }
        (Get-Writer $A).host | Should -Be 'LAPTOP-A'
        (Get-Latest $A).host | Should -Be 'LAPTOP-A'

        Invoke-Publish -Config $B -Now $Now.AddMinutes(115) -HostName 'LAPTOP-B' | Should -Be 'not-writer'
        (Set-SyncRole -Config $B -Role reader -HostName 'LAPTOP-B' -Now $Now.AddMinutes(116)).Status | Should -Be 'reader'
        Invoke-Check -Config $B -Now $Now.AddMinutes(116) -HostName 'LAPTOP-B' | Should -Be 'restored'
        Get-DocCount $B.dbPath | Should -Be (Get-DocCount $A.dbPath)
        Get-TestMarker -Database $B.dbPath | Should -Be 'reader'
    }
}

Describe 'Self-update' {
    BeforeAll {
        $script:RuntimeFiles = @(Get-ChildItem -LiteralPath $RepoRoot -File | Where-Object {
                $_.Name -match '\.(ps1|psm1|md)$' -or $_.Name -in @('VERSION', 'config.example.json') } | ForEach-Object { $_.Name })

        function New-FakeInstall {
            # An installed laptop at v1.0.0 with config, state, backups, bin, log and a pause flag.
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $cfg = New-TestLaptop -Root $root -Name 'A' -Role seller
            $app = Split-Path -Parent $cfg.configPath
            foreach ($f in $script:RuntimeFiles) { Copy-Item -LiteralPath (Join-Path $RepoRoot $f) -Destination $app }
            [IO.File]::WriteAllText((Join-Path $app 'VERSION'), "v1.0.0`n")
            New-Item -ItemType Directory -Force -Path (Join-Path $app 'state'), (Join-Path $app 'backups'), (Join-Path $app 'bin') | Out-Null
            Save-SyncState -Config $cfg -State @{ lastPublishedAt = '2026-11-26T09:45:00+08:00' }
            Set-Content -LiteralPath (Join-Path $app 'backups\pos-20261126-090000.bak') -Value 'old data'
            Set-Content -LiteralPath (Join-Path $app 'bin\sqlite3.exe') -Value 'not really sqlite'
            Set-Content -LiteralPath (Join-Path $app 'sync.log') -Value 'FIRST LINE'
            Set-Content -LiteralPath (Join-Path $app 'SYNC-PAUSED.txt') -Value 'paused'
            return @{ Cfg = $cfg; App = $app }
        }

        function Get-ProgramHashes {
            # Hashes of the program files (not config/state/backups/bin/log).
            param([string]$App)
            $h = @{}
            foreach ($f in Get-ChildItem -LiteralPath $App -File | Where-Object { $_.Name -match '\.(ps1|psm1|md)$' -or $_.Name -eq 'VERSION' }) {
                $h[$f.Name] = Get-FileSha256 $f.FullName
            }
            return $h
        }

        function New-FakeRelease {
            # Builds ar-sync-<Tag>.zip + .sha256 from the repo files, optionally tampered with.
            param([string]$Tag, [scriptblock]$Tamper, [string[]]$Extra = @())
            $src = Join-Path $TestDrive ('rel-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path $src | Out-Null
            foreach ($f in $script:RuntimeFiles) { Copy-Item -LiteralPath (Join-Path $RepoRoot $f) -Destination $src }
            [IO.File]::WriteAllText((Join-Path $src 'VERSION'), "$Tag`n")
            foreach ($e in $Extra) { Set-Content -LiteralPath (Join-Path $src $e) -Value '# added in this release' }
            if ($Tamper) { & $Tamper $src }
            $pkg = New-ReleasePackage -Root $src -Version $Tag -Files ($script:RuntimeFiles + $Extra) -OutDir (Join-Path $src 'out')
            $global:ArSyncFakeDir = Join-Path $src 'out'
            $global:ArSyncFakeTag = $Tag
            $global:ArSyncFakeAssets = @("ar-sync-$Tag.zip", "ar-sync-$Tag.zip.sha256")
            return $pkg
        }
    }

    BeforeEach {
        Initialize-Mocks
        Mock Invoke-UpdateApi -ModuleName AroniumSync {
            [pscustomobject]@{
                tag_name = $global:ArSyncFakeTag
                assets   = @($global:ArSyncFakeAssets | ForEach-Object {
                        [pscustomobject]@{ name = $_; browser_download_url = "https://github.com/huenique/ar-sync/releases/download/$($global:ArSyncFakeTag)/$_" } })
            }
        }
        Mock Invoke-UpdateDownload -ModuleName AroniumSync { Copy-Item -LiteralPath (Join-Path $global:ArSyncFakeDir (Split-Path -Leaf $Url)) -Destination $OutFile }
        $I = New-FakeInstall
        $before = Get-ProgramHashes $I.App
    }
    AfterEach { Remove-Variable -Name ArSyncFakeDir, ArSyncFakeTag, ArSyncFakeAssets -Scope Global -ErrorAction SilentlyContinue }

    It 'installs a newer release, toasts, and leaves config, state, backups, bin, log and pause flag alone' {
        $keep = @{}
        foreach ($p in @('config.json', 'backups\pos-20261126-090000.bak', 'bin\sqlite3.exe', 'SYNC-PAUSED.txt')) { $keep[$p] = Get-FileSha256 (Join-Path $I.App $p) }
        New-FakeRelease -Tag 'v1.1.0' | Out-Null
        Invoke-SelfUpdate -Config $I.Cfg -AppDir $I.App | Should -Be 'updated'
        Get-InstalledVersion -AppDir $I.App | Should -Be 'v1.1.0'
        foreach ($p in $keep.Keys) { Get-FileSha256 (Join-Path $I.App $p) | Should -Be $keep[$p] }
        (Get-SyncState -Config $I.Cfg).lastPublishedAt | Should -Be '2026-11-26T09:45:00+08:00'
        (Get-Content -LiteralPath (Join-Path $I.App 'sync.log'))[0] | Should -Be 'FIRST LINE'
        Should -Invoke Show-SyncToast -ModuleName AroniumSync -Times 1 -Exactly -ParameterFilter { $Text -eq 'Sync tool updated to v1.1.0.' }
        # same task definitions, so Task Scheduler and the registry are left alone
        Should -Invoke Update-SyncRegistrations -ModuleName AroniumSync -Times 0 -Exactly
    }

    It 'does nothing when the latest release is the installed version' {
        New-FakeRelease -Tag 'v1.0.0' | Out-Null
        Invoke-SelfUpdate -Config $I.Cfg -AppDir $I.App | Should -Be 'up-to-date'
        Should -Invoke Invoke-UpdateDownload -ModuleName AroniumSync -Times 0 -Exactly
        Should -Invoke Show-SyncToast -ModuleName AroniumSync -Times 0 -Exactly
    }

    It 'never downgrades on its own when the latest release is older' {
        New-FakeRelease -Tag 'v0.9.0' | Out-Null
        Invoke-SelfUpdate -Config $I.Cfg -AppDir $I.App | Should -Be 'up-to-date'
        Get-InstalledVersion -AppDir $I.App | Should -Be 'v1.0.0'
        Should -Invoke Invoke-UpdateDownload -ModuleName AroniumSync -Times 0 -Exactly
    }

    It '-Version installs that exact (older) release and pins it; -Unpin follows releases again' {
        New-FakeRelease -Tag 'v0.9.0' | Out-Null
        Invoke-SelfUpdate -Config $I.Cfg -AppDir $I.App -Version 'v0.9.0' | Should -Be 'updated'
        Should -Invoke Invoke-UpdateApi -ModuleName AroniumSync -Times 1 -Exactly -ParameterFilter { $Url -like '*/releases/tags/v0.9.0' }
        Get-InstalledVersion -AppDir $I.App | Should -Be 'v0.9.0'
        New-FakeRelease -Tag 'v1.1.0' | Out-Null
        Invoke-SelfUpdate -Config $I.Cfg -AppDir $I.App | Should -Be 'pinned'
        Get-InstalledVersion -AppDir $I.App | Should -Be 'v0.9.0'
        Invoke-SelfUpdate -Config $I.Cfg -AppDir $I.App -Unpin | Should -Be 'updated'
        Get-InstalledVersion -AppDir $I.App | Should -Be 'v1.1.0'
        (Get-SyncState -Config $I.Cfg).updatePin | Should -BeNullOrEmpty
    }

    It 'aborts on a hash mismatch and changes nothing' {
        $pkg = New-FakeRelease -Tag 'v1.1.0'
        [IO.File]::WriteAllText($pkg.Sha256File, ('0' * 64) + "  ar-sync-v1.1.0.zip`n")
        Invoke-SelfUpdate -Config $I.Cfg -AppDir $I.App | Should -Be 'failed'
        $after = Get-ProgramHashes $I.App
        foreach ($k in $before.Keys) { $after[$k] | Should -Be $before[$k] }
        Should -Invoke Show-SyncToast -ModuleName AroniumSync -Times 1 -Exactly -ParameterFilter { $Text -like '*failed*hash mismatch*' }
    }

    It 'aborts when the release has no .sha256 asset' {
        New-FakeRelease -Tag 'v1.1.0' | Out-Null
        $global:ArSyncFakeAssets = @('ar-sync-v1.1.0.zip')
        Invoke-SelfUpdate -Config $I.Cfg -AppDir $I.App | Should -Be 'failed'
        Get-InstalledVersion -AppDir $I.App | Should -Be 'v1.0.0'
        Should -Invoke Invoke-UpdateDownload -ModuleName AroniumSync -Times 0 -Exactly
    }

    It 'refuses a package whose script does not parse, before touching the install' {
        New-FakeRelease -Tag 'v1.1.0' -Tamper { param($d) Add-Content -LiteralPath (Join-Path $d 'check.ps1') -Value 'function { broken' } | Out-Null
        Invoke-SelfUpdate -Config $I.Cfg -AppDir $I.App | Should -Be 'failed'
        $after = Get-ProgramHashes $I.App
        foreach ($k in $before.Keys) { $after[$k] | Should -Be $before[$k] }
        Test-Path (Join-Path $I.App 'update-backup') | Should -BeFalse
    }

    It 'refuses a corrupt zip' {
        $pkg = New-FakeRelease -Tag 'v1.1.0'
        [IO.File]::WriteAllBytes($pkg.Zip, [byte[]](1..200))
        $h = Get-FileSha256 $pkg.Zip
        [IO.File]::WriteAllText($pkg.Sha256File, "$h  ar-sync-v1.1.0.zip`n")
        Invoke-SelfUpdate -Config $I.Cfg -AppDir $I.App | Should -Be 'failed'
        Get-InstalledVersion -AppDir $I.App | Should -Be 'v1.0.0'
    }

    It 're-registers tasks only when their definitions changed' {
        New-FakeRelease -Tag 'v1.1.0' -Tamper { param($d)
            $p = Join-Path $d 'AroniumSync.psm1'
            [IO.File]::WriteAllText($p, [IO.File]::ReadAllText($p).Replace("'PT15M'", "'PT20M'")) } | Out-Null
        Invoke-SelfUpdate -Config $I.Cfg -AppDir $I.App | Should -Be 'updated'
        Should -Invoke Update-SyncRegistrations -ModuleName AroniumSync -Times 1 -Exactly
    }

    It 'rolls back every file when a step after the copy fails' {
        Mock Update-SyncRegistrations -ModuleName AroniumSync { throw 'Task Scheduler said no' }
        New-FakeRelease -Tag 'v1.1.0' -Extra @('brand-new.ps1') -Tamper { param($d)
            $p = Join-Path $d 'AroniumSync.psm1'
            [IO.File]::WriteAllText($p, [IO.File]::ReadAllText($p).Replace("'PT15M'", "'PT20M'")) } | Out-Null
        Invoke-SelfUpdate -Config $I.Cfg -AppDir $I.App | Should -Be 'failed'
        $after = Get-ProgramHashes $I.App
        $after.Count | Should -Be $before.Count
        foreach ($k in $before.Keys) { $after[$k] | Should -Be $before[$k] }
        Test-Path (Join-Path $I.App 'brand-new.ps1') | Should -BeFalse
        Should -Invoke Register-SyncTasks -ModuleName AroniumSync -Times 1 -Exactly
        Should -Invoke Show-SyncToast -ModuleName AroniumSync -Times 1 -Exactly -ParameterFilter { $Text -like '*Task Scheduler said no*Rolled back*' }
    }

    It 'does not check at all when autoUpdate is off' {
        Set-SyncConfigField -Config $I.Cfg -Name 'autoUpdate' -Value $false
        Invoke-SelfUpdate -Config (Get-SyncConfig -Path $I.Cfg.configPath) -AppDir $I.App | Should -Be 'disabled'
        Should -Invoke Invoke-UpdateApi -ModuleName AroniumSync -Times 0 -Exactly
    }

    It 'waits for a running sync step (same mutex) and does nothing if it does not finish' {
        New-FakeRelease -Tag 'v1.1.0' | Out-Null
        $held = New-Object Threading.ManualResetEvent $false
        $done = New-Object Threading.ManualResetEvent $false
        $ps = [powershell]::Create()
        [void]$ps.AddScript({ param($name, $held, $done)
                $m = New-Object Threading.Mutex($false, $name)
                [void]$m.WaitOne(); [void]$held.Set(); [void]$done.WaitOne(30000); $m.ReleaseMutex(); $m.Dispose() }).AddArgument($I.Cfg.mutexName).AddArgument($held).AddArgument($done)
        $h = $ps.BeginInvoke()
        try {
            $held.WaitOne(10000) | Should -BeTrue
            Invoke-SelfUpdate -Config $I.Cfg -AppDir $I.App -MutexWaitSeconds 1 | Should -Be 'busy'
            Get-InstalledVersion -AppDir $I.App | Should -Be 'v1.0.0'
            Should -Invoke Invoke-UpdateApi -ModuleName AroniumSync -Times 0 -Exactly
        } finally { [void]$done.Set(); [void]$ps.EndInvoke($h); $ps.Dispose() }
        Invoke-SelfUpdate -Config $I.Cfg -AppDir $I.App -MutexWaitSeconds 1 | Should -Be 'updated'
    }
}

Describe 'Self-update guards' {
    It 'allows only GitHub over HTTPS: <Url> -> <Ok>' -ForEach @(
        @{ Url = 'https://api.github.com/repos/huenique/ar-sync/releases/latest'; Ok = $true }
        @{ Url = 'https://github.com/huenique/ar-sync/releases/download/v1.0.0/ar-sync-v1.0.0.zip'; Ok = $true }
        @{ Url = 'https://objects.githubusercontent.com/x'; Ok = $true }
        @{ Url = 'http://github.com/huenique/ar-sync/releases/download/v1.0.0/x.zip'; Ok = $false }
        @{ Url = 'https://github.com.evil.example/x.zip'; Ok = $false }
        @{ Url = 'https://evil.example/github.com/x.zip'; Ok = $false }
        @{ Url = 'https://github.com:8443/x.zip'; Ok = $false }
        @{ Url = 'file:///C:/x.zip'; Ok = $false }
        @{ Url = ''; Ok = $false }
    ) {
        Test-UpdateUrl $Url | Should -Be $Ok
    }

    It 'refuses to package <Path>' -ForEach @(
        @{ Path = 'pos.db' }, @{ Path = 'fixtures/real.db' }, @{ Path = 'fixtures\notes.txt' }, @{ Path = 'config.json' },
        @{ Path = 'sync.log' }, @{ Path = 'state/state.json' }
    ) {
        { Assert-ReleaseFiles -Paths @('AroniumSync.psm1', $Path) } | Should -Throw '*Refusing to package*'
    }

    It 'packages the normal runtime files' {
        { Assert-ReleaseFiles -Paths @('AroniumSync.psm1', 'update.ps1', 'config.example.json', 'README.md', 'VERSION') } | Should -Not -Throw
    }

    It 'the repo VERSION file is a valid version' {
        Get-InstalledVersion -AppDir $RepoRoot | Should -Match '^v\d+\.\d+\.\d+$'
        Get-InstalledVersion -AppDir $RepoRoot | Should -Not -Be 'v0.0.0'
    }

    It 'update task runs daily at 03:00 and 10 min after logon, as the logged-on user' {
        [xml]$x = Get-UpdateTaskXml -ScriptPath 'C:\x\update.ps1' -UserId 'PC\shop' -Start ([datetime]'2026-11-26')
        $x.Task.Triggers.CalendarTrigger.StartBoundary | Should -Be '2026-11-26T03:00:00'
        $x.Task.Triggers.CalendarTrigger.ScheduleByDay.DaysInterval | Should -Be '1'
        $x.Task.Triggers.LogonTrigger.Delay | Should -Be 'PT10M'
        $x.Task.Principals.Principal.LogonType | Should -Be 'InteractiveToken'
        $x.Task.Actions.Exec.Arguments | Should -Match 'update\.ps1'
    }
}
