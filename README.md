# Aronium Sync (two laptops)

Keeps a second laptop up to date with the laptop that rings up sales in Aronium Lite.

- **Selling laptop**: records sales and manages stock, as usual. Every 15 minutes it saves a checked copy of the Aronium database to OneDrive.
- **Viewing laptop**: only looks. Every 5 minutes it picks up the newest copy.
- **Only one laptop sells at a time.** Aronium Lite can't merge two sets of sales. If you ring up a sale on the viewing laptop, sync stops so that sale isn't lost.

Both laptops must be signed in to the **same OneDrive**.

## Install

Do this on each laptop, signed in as the Windows user who uses Aronium. You don't need admin rights.

1. Copy this folder to the laptop, for example to `Downloads\aronium-sync`.
2. Close Aronium.
3. Open **Windows PowerShell** (Start menu, type "PowerShell") and go to the folder:
   ```
   cd $HOME\Downloads\aronium-sync
   ```
4. Run one of these:
   - On the **selling** laptop:
     ```
     powershell -ExecutionPolicy Bypass -File .\install.ps1 -Role seller
     ```
   - On the **viewing** laptop:
     ```
     powershell -ExecutionPolicy Bypass -File .\install.ps1 -Role reader
     ```
5. Answer the questions. Press Enter to accept the suggestion in brackets.
   - OneDrive folder: use the same one on both laptops. The default is `OneDrive\aronium`.
   - Who to call: a name and phone number. It appears in the warnings.
   - Shop hours: used for the "main laptop is down" warning.
6. Install checks the name Aronium runs under, because sync uses it to tell whether Aronium is open.
   - If install stops with "Aronium is running as ...", run it again and add `-AroniumProcessName <that name>`.
   - If it warns that it couldn't check the name, open Aronium and run `Get-Process | Where-Object { $_.Path -like '*Aronium*' }`. If the name differs from the exe's file name, install again with `-AroniumProcessName`.

Install the selling laptop first. You'll get an "Aronium Sync is set up" notification. The desktop gets an **Aronium Sync - Clear pause** icon, and the viewing laptop also gets **Aronium Sync - Take over**.

Everything lives in `%LOCALAPPDATA%\AroniumSync`. The log is `sync.log` in that folder.

## What the notifications mean

| Notification | Laptop | What to do |
|---|---|---|
| **New data from the main laptop (as of 14:30). Restart Aronium to see it.** | Viewing | Click **Update now**. Aronium closes, loads the new data and opens again. If you're busy, click **Later** and it will ask again when the next copy arrives. If Aronium is already closed, the update happens on its own with no notification. |
| **Please close Aronium, then click Update now again.** | Viewing | Aronium didn't close by itself, maybe because a window or dialog is open. Finish what you're doing, close Aronium, then try again. Sync never forces Aronium closed. |
| **Sales were recorded on this laptop. Sync is paused so they aren't lost. Call [owner].** | Viewing | Someone rang up a sale (a receipt or payment) on the viewing laptop. Sync has stopped. Opening a shift, Z reports or product edits on the viewing laptop do not pause sync; they are replaced by the next copy. See [Clearing a sync pause](#clearing-a-sync-pause). |
| **Main laptop last synced at 10:15. If it's down, use Take over.** | Viewing | The selling laptop hasn't saved a copy for over an hour during shop hours. The hour counts from opening time, so a selling laptop that is switched on a little late doesn't trigger it. If the last copy is from an earlier day, the day is shown too (for example "Wed 20:00"). Check it's on, awake and connected to the internet. If it's broken, see [Take over](#take-over-the-selling-laptop-is-down). |
| **Backup failed at 14:30: (reason)** | Selling | The copy didn't save. Common causes are OneDrive not running or signed out, a full disk, or a damaged database. It retries every 15 minutes. If it keeps failing, call the owner. |
| **This laptop is no longer the selling laptop. Do not sell on it.** | Old selling laptop | The other laptop has taken over. Stop selling here. Reinstall this laptop with `-Role reader` once it's sorted out. |

Focus Assist (Do Not Disturb) can hide notifications. Every notification is also written to `sync.log`.

## Take over (the selling laptop is down)

Do this on the viewing laptop only when the selling laptop really can't be used: broken, stolen, or out of power for the day.

1. Click **Take over** on the "Main laptop last synced..." notification, or double-click **Aronium Sync - Take over** on the desktop.
2. A box asks: *This makes THIS laptop the selling laptop. Receipt numbers jump by 500. Continue?* Click **Yes**. **No** changes nothing.
3. The laptop does the following:
   - It closes Aronium.
   - It loads the newest copy, unless it has its own sales. Those are kept.
   - It moves every receipt number forward by 500. Receipts printed on the broken laptop after its last copy are then never printed twice. The gap in the numbers is on purpose.
   - It becomes the selling laptop and reopens Aronium.
4. Sales made on the broken laptop after its last copy (up to 15 minutes' worth) aren't on this laptop. Re-enter them from the printed receipts if needed.

When the old laptop is fixed, it won't publish over the new one. It shows "This laptop is no longer the selling laptop".

Before you change it, open Aronium on the old laptop and note any sales from its last 15 minutes that the new selling laptop doesn't have. Reinstalling it as the viewing laptop replaces its data; the old file is kept in its `backups` folder, but nothing warns you about those sales.

To make it the viewing laptop, run on it:

```
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\AroniumSync\set-role.ps1" -Role reader
```

Within 5 minutes it loads the new selling laptop's copy. Its old file is kept in `backups`.

## Give the selling role back

After a takeover, the repaired laptop has old data. **Don't reinstall it as the selling laptop.** It would publish its old copy, lose the sales made on the other laptop since the takeover, and set receipt numbers back so they repeat later. Install and `set-role.ps1` refuse to do this without `-Force`.

Do it in this order:

1. On the laptop that is selling now, close Aronium and wait for its next copy (up to 15 minutes).
2. On the repaired laptop, make it the viewing laptop:
   ```
   powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\AroniumSync\set-role.ps1" -Role reader
   ```
3. Wait up to 5 minutes, then open Aronium on it and check the latest sales are there. Close Aronium.
4. On the repaired laptop, double-click **Aronium Sync - Take over** and click **Yes**. Receipt numbers jump by another 500. That's expected.
5. On the other laptop, the "no longer the selling laptop" notification appears. Make it the viewing laptop with the command in step 2.

## Clearing a sync pause

A pause means a sale (receipt or payment) was rung up on the viewing laptop. If sync carried on, the main laptop's copy would overwrite them.

1. Open Aronium on the viewing laptop and note the sales made there: time, items, amounts.
2. Enter them on the selling laptop, or decide they're not needed.
3. Clear the pause in either of these ways:
   - Double-click **Aronium Sync - Clear pause** on the desktop.
   - Delete the file `%LOCALAPPDATA%\AroniumSync\SYNC-PAUSED.txt`. To find it, paste `%LOCALAPPDATA%\AroniumSync` into the File Explorer address bar.
4. Within 5 minutes, the viewing laptop loads the main laptop's copy.
   - The old file, including the sales made on it, is kept in `%LOCALAPPDATA%\AroniumSync\backups`.
   - The last 10 old files are kept.

If more sales are made on the viewing laptop after you clear the pause, it pauses again.

## Good to know

- **Copies are up to 15 minutes old.** If the selling laptop's disk dies, sales from the last 15 minutes are lost.
- **Old copies:** the selling laptop keeps a dated copy of every change for 30 days in `OneDrive\aronium\history`.
- **Printers and settings stay per laptop.** These are kept on each laptop and never copied:
  - receipt printer settings
  - print stations
  - the Aronium app ID
  - security keys
- **Switch roles:** run `set-role.ps1 -Role reader` or `-Role seller` from `%LOCALAPPDATA%\AroniumSync`. It needs no internet. To give the selling role back after a takeover, follow [Give the selling role back](#give-the-selling-role-back).
- **Uninstall:** run `uninstall.ps1` from `%LOCALAPPDATA%\AroniumSync`. It removes everything except:
  - the `backups` folder
  - the copies in OneDrive
  - `sqlite3.exe` and the BurntToast module, so a reinstall works offline. Add `-Purge` to remove these two as well.
- **Rehearse a takeover once** before you rely on it. See `VERIFY.md` for the checks that can only be done on the real laptops.
- **Updates install themselves.** Every day at 03:00, or as soon as the laptop is on after that, and 10 minutes after sign-in, the laptop checks for a new release.
  - When there is one, you'll see "Sync tool updated to v1.2.0".
  - To stop automatic updates, set `"autoUpdate": false` in `config.json`.

## Releasing an update

Clients only ever install **published GitHub releases**. Pushing to `master` changes nothing on the laptops.

1. Make the change, run the tests, commit and push to `master`.
2. Bump `VERSION`, for example `v1.0.0` to `v1.1.0`, using `vMAJOR.MINOR.PATCH`. Add a short entry to `CHANGELOG.md`. Commit and push both.
3. Build and check the package without publishing:
   ```
   powershell -ExecutionPolicy Bypass -File tools\make-release.ps1 -NoUpload
   ```
   - It needs a clean tree on `master` and a tag that doesn't exist yet.
   - It zips the tracked top-level runtime files into `dist\ar-sync-<tag>.zip` and writes `dist\ar-sync-<tag>.zip.sha256`.
   - It refuses anything matching `*.db`, `fixtures/`, `config.json` or `*.log`.
   - It unpacks the zip and runs the same checks a laptop runs.
4. Publish:
   ```
   powershell -ExecutionPolicy Bypass -File tools\make-release.ps1
   ```
   This tags the commit, pushes the tag, and runs `gh release create` with both files. It needs the [GitHub CLI](https://cli.github.com/), signed in with `gh auth login`.

**What each laptop then does** (`update.ps1`, daily and after sign-in):
1. It asks `api.github.com` for the latest published release and compares the tag with its own `VERSION`. It only moves forward on its own.
2. It downloads `ar-sync-<tag>.zip` and `.sha256` over HTTPS from GitHub hosts only, and stops if either is missing or the hash doesn't match.
3. It unpacks to a temp folder and checks the package:
   - the required files are there
   - `VERSION` matches the tag
   - every script parses
   - the module imports in a separate PowerShell
4. It waits for any running sync step, using the same lock as publish and check, so it never updates mid-sync.
5. It copies the package files over the install. It saves each replaced file in `update-backup\` first.
   - `config.json`, `state\`, `backups\`, `bin\`, `sync.log` and `SYNC-PAUSED.txt` are never in a package and never touched.
6. It re-registers the scheduled tasks and the toast link only if their definitions changed.
7. Any failure after the copy puts the old files back. Success and failure are both logged and shown as a notification.

**To roll back or pin a laptop**, run:
```
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\AroniumSync\update.ps1" -Version v1.0.0
```
This installs that exact release and pins it, so scheduled runs leave it alone. `update.ps1 -Unpin` follows new releases again.

To withdraw a bad release, publish a fixed, higher version. Deleting a release doesn't move laptops back.

## For developers

- Tests: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1`. This needs Pester 5 (`Install-Module Pester -Scope CurrentUser -MinimumVersion 5.0 -SkipPublisherCheck`).
- The test runner downloads the pinned `sqlite3.exe` into `tools\` if it's missing.
- Tests build a small synthetic database from `tests\schema.sql`, which is Aronium 1.38.2.0's schema with no rows.
- If `fixtures\real.db` exists, every database test also runs on a copy of it. It's gitignored: put a copy of a real backup there yourself and never commit it.
- Layout:
  - All logic is in `AroniumSync.psm1`.
  - `publish.ps1`, `check.ps1`, `takeover.ps1`, `update-now.ps1`, `protocol-handler.ps1`, `clear-pause.ps1`, `set-role.ps1` and `update.ps1` are thin wrappers.
  - `tools\make-release.ps1` builds and publishes releases. It isn't shipped to laptops.
