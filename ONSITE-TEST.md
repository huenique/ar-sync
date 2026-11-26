# On-site test: one half-day visit

**A** = selling laptop. **B** = viewing laptop. Each step says which one: **[A]**, **[B]** or **[A+B]**.
Hostnames: A = `LAPTOP-MB7LH62P`  B = `LAPTOP-MVEPIKMR` (from `$env:COMPUTERNAME`).

## Remote setup, 2026-11-26 (done over MeshCentral)

Both laptops are already installed (v1.0.0) and running. On the visit, skip what is ticked here and do the rest.

| | A (seller) | B (reader) |
|---|---|---|
| Windows user | `M.O FLORES CONS` | `Marissa Flores` |
| OneDrive (same personal account) | `C:\Users\M.O FLORES CONS\OneDrive` | `C:\Users\Marissa Flores\Desktop\OneDrive` |
| Aronium | 1.44.0.1 → 1.52.2.0 | 1.50.1.3 → 1.52.2.0 |
| Process / exe | `Aronium.Pos`, `C:\Program Files\Aronium\Aronium.Pos.exe` | same |
| Backups before any change | `C:\ar-sync-backup\pos-*.db` (hash-checked) | same |

Verified remotely:
- [x] Section 2: backups of both `pos.db`, SHA256 match, `integrity_check` ok. They stay on each laptop in `C:\ar-sync-backup` (admins + that user only).
- [x] Section 3: exe, process name and DB path (table above). The process name was checked against the running Aronium on A.
- [x] Sleep and hibernate off on AC, lid set to do nothing on AC and battery (both). Both were on battery when checked, so keep them plugged in.
- [x] Section 5: install on both. Tasks `AroniumSync Publish` (A), `AroniumSync Check` (B) and `AroniumSync Update` (both) run as the logged-on user, Interactive. The `aronium-sync:` link is in each user's HKCU. Shop hours are 08:00–18:00 Mon–Sat in both configs. Owner contact is `09195079798`.
- [x] Section 6: first publish on A. `latest.db` passes `integrity_check`, and OneDrive delivered it to B with the same SHA256 as `latest.json`. First restore on B with Aronium closed: done silently, B's per-PC tables unchanged (row hashes before and after), and B's newest sale is now A's (17:26:35, 29,516 sales).
- [x] Section 4 (reader side): a second check, and a third with Aronium open on B, did not pause.

Still needs someone on site:
- [ ] Section 4 on A: does opening Aronium on A, with no sale, change the fingerprint?
- [ ] Section 7: see each toast and click each button. Toasts were logged (`TOAST [install]` in `sync.log` on both), but nobody has seen one on screen.
- [ ] Desktop shortcuts "Clear pause" and "Take over": check they exist and open.
- [ ] Sections 8–9: takeover rehearsal and shutdown publish.
- [ ] Printing on B after a restore (printer tables are per-PC and were kept, but test a receipt).
- [ ] B has Aronium's **Price Lists** plugin and A does not. B re-adds the Price Lists tables each time it opens a restored copy. That's harmless unless staff start using price lists on B. Decide whether to remove the plugin from B or add it to A.
- [ ] Both `C:\ar-sync-backup` folders can be deleted after a week of good syncs.

Notes for remote work (MeshCentral):
- `runcommand --runasuser` hangs and blocks the agent's command queue. To run as the user, register a one-shot scheduled task with an Interactive principal (`ustart.ps1` on the server does this).
- `Start-Process -Wait` on the Aronium installer never returns, because setup starts Aronium as SYSTEM in session 0 at the end. Wait on the installer process only, then stop that session-0 Aronium. It opens an empty DB in the SYSTEM profile, not the shop's.
- Staff don't need to run the agent installer again. Running it again starts a second, temporary agent.

**Ground rules**
- No real sales during the visit. Ideally the shop is closed. Then "put the step-2 copies back" is always a clean rollback.
- Test sales on A get refunded. Test sales on B need no refund, because the next restore throws them away.
- Refund in Aronium: open the sales history, pick the test receipt, click **Refund**, pay it back in cash. Write the exact menu path here once you find it: `________________`.
- Use **Windows PowerShell** (5.1), not PowerShell 7.

About 4 hours: sections 2–3 take 35 min, 4–6 take 1 h, 7 takes 1 h, 8–9 take 1 h, 10–11 take 15 min.

## 0. Every PowerShell window (run this first)

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
$U  = 'E:\aronium-sync'            # repo on the USB stick (fix the drive letter)
$BK = 'E:\aronium-backup'          # backups go here
$S  = "$env:LOCALAPPDATA\AroniumSync"
$OD = "$env:OneDrive\aronium"
$DB = "$env:LOCALAPPDATA\Aronium\Data\pos.db"   # change to the path found in 3.1
$SQ = "$U\tools\sqlite3.exe"
function Show-Tail { Get-Content "$S\sync.log" -Tail 12 }
function Edit-Cfg([scriptblock]$Change) {   # edit config.json without a BOM
  $c = [IO.File]::ReadAllText("$S\config.json") | ConvertFrom-Json; & $Change $c
  [IO.File]::WriteAllText("$S\config.json", ($c | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false)) }
```

After `Start-ScheduledTask`, wait about 30 seconds before reading the log.

## 1. Before the visit

**1.1** Copy the repo folder to the USB stick, including `tools\sqlite3.exe`. Delete `fixtures\` from the USB copy, because it holds a real database. Install doesn't copy `tools\`, so this is your offline sqlite.
Expect: `Test-Path E:\aronium-sync\tools\sqlite3.exe` → `True`. `[ ] pass [ ] fail`

**1.2** Make an offline copy of BurntToast in case the shop has no internet: `Save-Module BurntToast -RequiredVersion 1.1.0 -Path E:\modules`.
On site, if install can't reach PowerShell Gallery, copy `E:\modules\BurntToast` to `$HOME\Documents\WindowsPowerShell\Modules\`. `[ ] pass [ ] fail`

**1.3** Ask the owner for:
- a no-sales window
- the Windows sign-in on both laptops
- confirmation that both laptops use the **same OneDrive account**
- the name and phone number for the alerts
- the shop hours

Print this sheet. `[ ] pass [ ] fail`

**1.4 [A+B]** On arrival, before anything else, take a fresh Aronium backup with **Aronium's own backup feature**, saved to `$BK`.
If you can't find the feature, rely on 2.1 and note it. `[ ] pass [ ] fail`

## 2. Back up both laptops (before touching anything)

**2.1 [A+B]** Close Aronium. Copy Aronium's whole data folder and check the copy:
```powershell
$dst = "$BK\$env:COMPUTERNAME-$(Get-Date -f yyyyMMdd-HHmm)"
Copy-Item (Split-Path $DB) $dst -Recurse
Get-FileHash $DB, "$dst\pos.db" | Format-Table Hash, Path
```
Expect: both hashes are equal. Write A's hash `________` and B's hash `________`.
If fail: `$DB` is wrong, so do 3.1 first and come back. **Don't continue without this copy.** `[ ] pass [ ] fail`

## 3. Find Aronium's exe, process and database

**3.1 [A+B]** Find the database:
```powershell
Get-ChildItem $env:LOCALAPPDATA, $env:APPDATA, $env:ProgramData -Filter pos.db -Recurse -Depth 4 -ErrorAction SilentlyContinue | Select-Object FullName, Length, LastWriteTime
```
Expect: one `pos.db`. On A it was modified recently.
If there are several, use the one whose time changes after a sale. If there are none, look in Aronium's settings for the database location.
Path on A: `________` Path on B: `________`. If it isn't the default, set `$DB` and back it up as in 2.1. `[ ] pass [ ] fail`

**3.2 [A+B]** Open Aronium, then run:
```powershell
Get-Process | Where-Object { $_.Path -like '*Aronium*' } | Select-Object ProcessName, Path, SessionId
```
Expect: one row. Write down Path (exe) `________` and ProcessName `________`.
Pass both to install as `-AroniumExe` and `-AroniumProcessName`. Sync also spots Aronium by its exe path, but the name is the main check. `[ ] pass [ ] fail`

**3.3 [A+B]** With Aronium still open, run:
```powershell
try { [IO.File]::Open($DB, 'Open', 'ReadWrite', 'None').Dispose(); 'free' } catch { 'held' }
```
Expect: `held`. Aronium keeps `pos.db` open, so the restore guard can see Aronium even without the process name.
If it prints `free`, the guard relies on the process name and exe path only. Note it, and don't fail the visit for it. `[ ] pass [ ] fail`

**3.4 [A+B]** Close Aronium, then run `Get-ChildItem "$DB*"`.
Expect: only `pos.db`, with no `-journal` or `-wal`.
If fail: a leftover journal after a clean close means every restore will be refused. Stop and report. `[ ] pass [ ] fail`

**3.5 [A+B]** Check OneDrive:
1. On A, run `Set-Content "$env:OneDrive\probe.txt" (Get-Date)`.
2. On B, run `Get-Content "$env:OneDrive\probe.txt"`.

Expect: B shows the same text within 2 minutes. Delete the file afterward.
If fail: compare the account in OneDrive settings on both laptops and fix it before going on. `[ ] pass [ ] fail`

**3.6** Pass the values from 3.1 and 3.2 to `install.ps1` as parameters instead of editing `config.example.json` by hand. `[ ] pass [ ] fail`

## 4. Fingerprint check: does opening Aronium look like a sale?

**4.1 [B]** With Aronium closed, run:
```powershell
Import-Module "$U\AroniumSync.psm1" -Force
$fp1 = Get-DataFingerprint -Config @{ sqlitePath = $SQ } -Database $DB
```
Expect: one line starting with `Document=`. `[ ] pass [ ] fail`

**4.2 [B]** Open Aronium and look around: products, sales history, reports, settings. **Don't sell.**
If it asks for starting cash or to open a shift, cancel and note it, because the `StartingCash` and `ZReport` tables are part of the fingerprint. Close Aronium. `[ ] pass [ ] fail`

**4.3 [B]** Run:
```powershell
$fp2 = Get-DataFingerprint -Config @{ sqlitePath = $SQ } -Database $DB
$fp1 -eq $fp2; Compare-Object ($fp1 -split ';') ($fp2 -split ';')
```
Expect: `True` and no differences.
If fail: the table named in the diff is what Aronium writes when it starts. B would pause on every launch.
- If it's the shift prompt, retry without it.
- Otherwise install A only (it still gives an off-site copy every 15 minutes), skip B, and report the table.

`[ ] pass [ ] fail`

**4.4 [B]** Optional: leave Aronium open on B for the rest of the visit and re-check in 11.2. This catches timed writes such as stock recounts and Z-reports.

## 5. Install

**5.1 [A+B]** If the shop has no internet, copy sqlite in first so install skips the download:
```powershell
New-Item -ItemType Directory -Force "$S\bin" | Out-Null; Copy-Item $SQ "$S\bin\"
```
`[ ] pass [ ] fail`

**5.2 [A]** Leave Aronium **open** so install can check the process name, then run:
```powershell
cd $U
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Role seller -DbPath "$DB" -AroniumExe "<exe from 3.2>" -AroniumProcessName "<name from 3.2>" -OneDriveFolder "$env:OneDrive\aronium" -OwnerContact "<name, phone>" -ShopOpen 08:00 -ShopClose 21:00
```
Expect:
- `process name OK`
- `Running a first publish ...` followed by `published`
- an "Aronium Sync is set up. This laptop is the selling laptop." toast
- a **Clear pause** icon on the desktop

If fail:
- "Aronium is running as ...": rerun with that `-AroniumProcessName`.
- BurntToast error: see 1.2.
- sqlite hash error: see 5.1.

`[ ] pass [ ] fail`

**5.3 [A]** Check the setup:
```powershell
Get-Content "$S\config.json"; Get-Content "$OD\writer.json"; Get-Content "$OD\latest.json"
(Get-ScheduledTask 'AroniumSync Publish').Triggers | Select-Object @{n='Type';e={$_.CimClass.CimClassName}}, Delay
Start-ScheduledTask 'AroniumSync Publish'; Start-Sleep 30; Get-ScheduledTaskInfo 'AroniumSync Publish' | Select-Object LastRunTime, LastTaskResult
```
Expect:
- `aroniumProcessName` equals the name from 3.2.
- writer and latest both show host A.
- The triggers include `MSFT_TaskEventTrigger` (shutdown), and the logon trigger has a `PT3M` delay.
- `LastTaskResult` is `0`.
- No PowerShell window flashes up.

If fail:
- Wrong process name: fix it as in 3.2.
- No event trigger: check `sync.log` for "Shutdown trigger refused" and note it.

`[ ] pass [ ] fail`

**5.4 [B]** Save B's printer settings, which you'll compare in 6.3. Also take a photo of Aronium's printer settings screen.
```powershell
& $SQ -readonly $DB "SELECT * FROM PosPrinterSettings; SELECT * FROM PrintStation; SELECT * FROM PosPrinterSelection;" | Set-Content "$BK\B-printers-before.txt"
```
`[ ] pass [ ] fail`

**5.5 [B]** Wait for A's copy to arrive. When this prints `True`, close Aronium and install with the same parameters, using `-Role reader`:
```powershell
(Get-FileHash "$OD\latest.db").Hash.ToLower() -eq (Get-Content "$OD\latest.json" | ConvertFrom-Json).sha256
```
Expect:
- a warning that install couldn't check the process name, because Aronium is closed. That's fine, since 3.2 checked it.
- `Running a first check ...` followed by `restored`
- the setup toast
- **Clear pause** and **Take over** icons on the desktop
- a solid green tick on `OneDrive\aronium`. If it's missing, right-click the folder and choose **Always keep on this device**.

`[ ] pass [ ] fail`

## 6. First publish and first restore

**6.1 [A]** Run `Show-Tail`.
Expect: `Published new copy (sha ...)`, and one `pos-*.db` in `$OD\history`. `[ ] pass [ ] fail`

**6.2 [B]** Run `Show-Tail; Get-ChildItem "$S\backups"`.
Expect: `Restored copy ...` and one `.bak`, which is B's old data. Open Aronium: the newest sale in the history is A's newest sale.
If fail: see section 10. `[ ] pass [ ] fail`

**6.3 [B]** Check that B's own printer settings survived:
```powershell
Compare-Object (Get-Content "$BK\B-printers-before.txt") (& $SQ -readonly $DB "SELECT * FROM PosPrinterSettings; SELECT * FROM PrintStation; SELECT * FROM PosPrinterSelection;")
```
Expect: no output, the settings screen matches the 5.4 photo, and a reprint or test print comes out of B's printer.
If fail: restore B from the `.bak` (10.3) and report. The per-PC table list is incomplete. `[ ] pass [ ] fail`

**6.4 [B]** Repeat section 4 for real: open Aronium, look around, close it.
Then run `Start-ScheduledTask 'AroniumSync Check'`, then `Show-Tail; Test-Path "$S\SYNC-PAUSED.txt"`.
Expect: no `Divergence` line, `False`, and the task's `LastTaskResult` is `0`. `[ ] pass [ ] fail`

## 7. Each notification and button

Each toast shows only once for each new copy, so every test starts with a fresh change on A.

**7.1 [A]** Ring up test sale #1: cheapest item, quantity 1, cash. Note the receipt number `____`. Then run:
```powershell
Get-ChildItem (Split-Path $DB), "$env:APPDATA\Aronium" -Recurse -File -ErrorAction SilentlyContinue | Where-Object LastWriteTime -gt (Get-Date).AddMinutes(-5)
Start-ScheduledTask 'AroniumSync Publish'
```
Expect: only `pos.db` changed, so Aronium keeps nothing else that needs syncing. The log shows `Published new copy`.
If other files changed, list them: they aren't synced. `[ ] pass [ ] fail`

**7.2 [B]** With Aronium open, wait for the hash check in 5.5 to print `True`. Then run `Start-ScheduledTask 'AroniumSync Check'`.
Expect: a "New data from the main laptop (as of HH:MM)..." toast with **Update now** and **Later**. `[ ] pass [ ] fail`

**7.3 [B]** Click **Update now**. The first time, Windows may ask which app opens the link: choose Windows PowerShell and tick "always".
Expect:
- Aronium closes within 30 seconds and reopens.
- Test sale #1 is in B's history.
- The log shows `Toast button: update-now` and `Restored copy`.

If fail:
- "Please close Aronium" means Aronium has an exit prompt or hides in the tray. Close it by hand, click again, and note it as a known limit.
- If the click does nothing, run `Start-Process 'aronium-sync:update-now'`. If that works, the problem is the toast-to-link handoff. If it doesn't, check the key `HKCU:\Software\Classes\aronium-sync\shell\open\command`.

`[ ] pass [ ] fail`

**7.4 [A]** Refund test sale #1, then run `Start-ScheduledTask 'AroniumSync Publish'`. `[ ] pass [ ] fail`

**7.5 [B]** With Aronium open, wait for `True`, then start the Check task. When the toast appears, click **Later**. Start the Check task again.
Expect: the log shows `Toast button: later`, and the second run shows **no** toast and adds no new `TOAST` line. `[ ] pass [ ] fail`

**7.6 [B]** Close Aronium and start the Check task.
Expect: a silent `Restored copy` with no toast. Reopen Aronium: the refund is there. `[ ] pass [ ] fail`

**7.7 [B]** Test the pause:
1. In Aronium on B, ring up test sale #2: cheapest item, cash.
2. **Don't refund it.** Write **VOID** on the printed receipt, because A will reuse that number.
3. Close Aronium and start the Check task.

If you ring up more than one sale, finish them all before the check runs. Otherwise you'll need to clear the pause twice.

Expect:
- A "Sales were recorded on this laptop..." toast that **stays on screen until you click Dismiss** (wait 1 minute).
- `Test-Path "$S\SYNC-PAUSED.txt"` → `True`.
- A `Divergence ... Sync paused.` line in the log.

If fail: the toast fades means the Reminder style isn't working. No toast at all means checking Focus Assist and the `TOAST` line in the log. `[ ] pass [ ] fail`

**7.8 [B]** Double-click **Aronium Sync - Clear pause**, then start the Check task.
Expect:
- `Pause cleared by a person` followed by `Restored copy`
- a new `.bak` in `$S\backups`
- test sale #2 no longer in Aronium

`[ ] pass [ ] fail`

**7.9 [A+B]** Test the stale alert:
1. **[A]** Run `Disable-ScheduledTask 'AroniumSync Publish'`.
2. **[B]** Run `Copy-Item "$S\config.json" "$S\config.orig.json"; Edit-Cfg { param($c) $c.staleMinutes = 1; $c.shopHours.open = '00:00'; $c.shopHours.close = '23:59' }`.
3. **[B]** Wait 2 minutes, then start the Check task.

Expect: a "Main laptop last synced at HH:MM. If it's down, use Take over." toast with a **Take over** button.

Click **Take over**. A Yes/No box comes up on top, with **No** as the default. Click **No**.
Expect: the log shows `Toast button: takeover` and `Take over cancelled at the confirm box.`, and B's role is still `reader`.

Undo the test:
- **[B]** `Copy-Item "$S\config.orig.json" "$S\config.json" -Force`
- **[A]** `Enable-ScheduledTask 'AroniumSync Publish'; Start-ScheduledTask 'AroniumSync Publish'`

Don't edit `latest.json` to fake this. It's in OneDrive, A overwrites it, and editing it causes conflict copies. `[ ] pass [ ] fail`

**7.10 [A]** Test backup-failed:
1. Run `Copy-Item "$S\config.json" "$S\config.orig.json"; Edit-Cfg { param($c) $c.dbPath = 'C:\nope\pos.db' }`.
2. Start the Publish task.

Expect: a "Backup failed at HH:MM: Aronium database not found at C:\nope\pos.db" toast.

Then put the config back with `Copy-Item "$S\config.orig.json" "$S\config.json" -Force` and publish again.
Expect: `Published heartbeat` and no toast. `[ ] pass [ ] fail`

## 8. Takeover rehearsal and hand-back

**8.1 [A]** Start the Publish task. **[B]** Close Aronium, start the Check task, and confirm `Restored copy` or no new action. Then save the counters:
```powershell
& $SQ -readonly $DB "SELECT * FROM Counter;" | Tee-Object "$BK\counter-0.txt"
```
`[ ] pass [ ] fail`

**8.2 [A]** Note the time `____`. Shut down from the Start menu: **Shut down**, not sleep. `[ ] pass [ ] fail`

**8.3 [B]** Double-click **Aronium Sync - Take over**, then click **Yes**. Then run:
```powershell
& $SQ -readonly $DB "SELECT * FROM Counter;"
(Get-Content "$S\config.json" | ConvertFrom-Json).role
Get-ScheduledTask 'AroniumSync*' | Select-Object TaskName, State
Get-Content "$OD\writer.json"; Get-Content "$OD\latest.json"
```
Expect:
- a "This laptop is now the selling laptop. Receipt numbers jumped by 500." toast
- Aronium reopens
- every Counter value is `counter-0` + 500
- role is `seller`
- only the `Publish` task exists
- writer.json shows host B with previous_host A, and latest.json shows host B

`[ ] pass [ ] fail`

**8.4 [B]** Ring up test sale #3. Expect: the receipt number is 500 above A's next number, and it prints on B's printer. Refund it on B. `[ ] pass [ ] fail`

**8.5 [A]** Turn A on and sign in. The publish task waits 3 minutes after sign-in so OneDrive can catch up. After 5 minutes, run:
```powershell
Select-String 'Published|Not publishing' "$S\sync.log" | Select-Object -Last 4
Get-Content "$OD\latest.json"; Get-ChildItem $OD
```
Expect:
- a persistent "This laptop is no longer the selling laptop. Do not sell on it." toast
- the **first** line after boot is `Not publishing: writer is now B` or `Not publishing: latest.json is from B`
- latest.json still shows host B
- no `latest-<PC>` conflict copies

If fail: a `Published` line at boot means A overwrote B's copy. That is a bug, so report it. B's next publish fixes `latest.db`. `[ ] pass [ ] fail`

**Hand back.** This follows README "Give the selling role back". Never make A the seller straight away. It would publish A's out-of-date database, drop B's sales and roll the counters back, which means duplicate receipt numbers later. Move B's data to A first.

**8.6 [A]** Check the guard: `powershell -ExecutionPolicy Bypass -File "$S\set-role.ps1" -Role seller`.
Expect: it refuses, naming B and pointing to "Give the selling role back". Nothing changes. `[ ] pass [ ] fail`

**8.7 [B]** Start the Publish task. **[A]** Run:
```powershell
powershell -ExecutionPolicy Bypass -File "$S\set-role.ps1" -Role reader
Start-ScheduledTask 'AroniumSync Check'
```
Expect: `restored` in the log. Open Aronium on A: test sale #3 and its refund are there. Close Aronium. `[ ] pass [ ] fail`

**8.8 [A]** Double-click **Take over**, then click **Yes**.
Expect: the Counter values are `counter-0` + 1000 (two jumps, which is expected), and writer.json shows host A. `[ ] pass [ ] fail`

**8.9 [B]** Start the Publish task.
Expect: the "no longer the selling laptop" toast and `Not publishing: writer is now A`.
Then run `set-role.ps1 -Role reader` as in 8.7 and start the Check task.
Expect: `restored`, and B's counters match A's. `[ ] pass [ ] fail`

## 9. Shutdown publish

**9.1 [A]** Ring up and refund a test sale, so there is a new copy to publish. Note the time `____`. Shut down from the Start menu. `[ ] pass [ ] fail`

**9.2 [B]** Run `Get-Content "$OD\latest.json"`. A bonus pass is a `published_at` at the shutdown time, which means the upload finished before power-off. `[ ] pass [ ] fail`

**9.3 [A]** Boot A, then run `Select-String 'Published' "$S\sync.log" | Select-Object -Last 3`.
Expect: a line between the shutdown time and the boot.
If fail: Windows cut the task off. It's not a blocker, since the logon trigger and the 15-minute timer cover it. Tell the owner to leave A on for 15 minutes after the last sale before shutting down. `[ ] pass [ ] fail`

## 10. Rollback / uninstall (if anything goes badly)

Roll back if:
- Aronium won't open after a restore
- sales are missing on A
- B pauses on every launch
- B's printer settings are lost

**10.1 [A, B or both]** Uninstall: `powershell -ExecutionPolicy Bypass -File "$S\uninstall.ps1"`.
This removes the tasks, the link, the icons, the scripts and the config. It keeps `$S\backups`, the OneDrive folder, `sqlite3.exe` and BurntToast. Add `-Purge` to remove the last two as well. `[ ] pass [ ] fail`

**10.2 [same laptop]** Close Aronium. Put the section-2 copy back:
```powershell
$t = Get-Date -f yyyyMMdd-HHmm
Get-ChildItem "$DB", "$DB-journal", "$DB-wal" -ErrorAction SilentlyContinue | Rename-Item -NewName { "$($_.Name).sync-$t" }
Copy-Item "$BK\<PC-folder from 2.1>\pos.db" $DB; Get-FileHash $DB
```
Expect: the hash equals the one from 2.1, and Aronium opens with its pre-visit data. `[ ] pass [ ] fail`

**10.3 [B only]** For a smaller rollback, use the newest file in `$S\backups\pos-*.bak` instead of the USB copy, the same way.
If only B is the problem, uninstall B alone. A keeps making OneDrive copies, which is a free off-site backup. `[ ] pass [ ] fail`

## 11. Sign-off

**11.1 [A+B]** Final check:
- A's role is `seller` and B's is `reader`.
- Each laptop has its task, `Ready`, with `LastTaskResult` `0`.
- There's no `SYNC-PAUSED.txt`.
- OneDrive shows green.
- Focus Assist is off for the shop user.

`[ ] pass [ ] fail`

**11.2 [B]** If you did 4.4, close Aronium, start the Check task, and confirm there's no `Divergence` line. `[ ] pass [ ] fail`

**11.3** Leave the owner:
- **Labels:** A says "SELLING". B says "VIEWING ONLY - do not sell".
- **README pages:** the printed "What the notifications mean", "Take over" and "Clearing a sync pause" sections.
- **A contact:** who to call, matching `ownerContact`.
- **Test records:**
  - Refund pairs #1, #3 and the 9.1 sale, which net to zero.
  - Receipt #2, marked VOID.
  - Two 500-number gaps.
  - Offer to keep these (recommended), or to roll A back to the 2.1 copy if there have been no real sales since.
- **The 2.1 USB backups:** these are the owner's sales data, so hand them over or keep them secured.
- **This sheet:** ticked, with every open item listed.

`[ ] pass [ ] fail`

## Issues found on first read (now fixed)

The five issues from the first version of this script are fixed in code and covered by tests:

1. `config.example.json` is now valid JSON.
2. **Boot race:**
   - The old seller also refuses to publish when `latest.json` comes from another laptop and is newer than its own last publish.
   - The seller's logon task waits 3 minutes.
   - Step 8.5 checks this.
3. **Process name:**
   - Install takes `-AroniumProcessName` and checks it against the running Aronium.
   - Restores also refuse when Aronium's exe or `pos.db` is held open, or the process list can't be read.
   - Steps 3.3 and 5.2 check this.
4. **Hand-back:**
   - The README has a "Give the selling role back" section.
   - Install and `set-role.ps1 -Role seller` refuse to overwrite newer data from the other laptop unless you pass `-Force`.
   - Steps 8.6 to 8.9 check this.
5. **Role changes work offline:**
   - `set-role.ps1` switches roles in place.
   - `uninstall.ps1` keeps `sqlite3.exe` and BurntToast unless you pass `-Purge`.