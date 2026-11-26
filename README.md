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

Install the selling laptop first. You'll get an "Aronium Sync is set up" notification. The desktop gets an **Aronium Sync - Clear pause** icon, and the viewing laptop also gets **Aronium Sync - Take over**.

Everything lives in `%LOCALAPPDATA%\AroniumSync`. The log is `sync.log` in that folder.

## What the notifications mean

| Notification | Laptop | What to do |
|---|---|---|
| **New data from the main laptop (as of 14:30). Restart Aronium to see it.** | Viewing | Click **Update now**. Aronium closes, loads the new data and opens again. If you're busy, click **Later** and it will ask again when the next copy arrives. If Aronium is already closed, the update happens on its own with no notification. |
| **Please close Aronium, then click Update now again.** | Viewing | Aronium didn't close by itself, maybe because a window or dialog is open. Finish what you're doing, close Aronium, then try again. Sync never forces Aronium closed. |
| **Sales were recorded on this laptop. Sync is paused so they aren't lost. Call [owner].** | Viewing | Someone used the viewing laptop to sell or change something. Sync has stopped. See [Clearing a sync pause](#clearing-a-sync-pause). |
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
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\AroniumSync\uninstall.ps1"
```

Then install it again with `-Role reader`.

## Clearing a sync pause

A pause means sales or changes were made on the viewing laptop. If sync carried on, the main laptop's copy would overwrite them.

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
- **Uninstall:** run `uninstall.ps1` from `%LOCALAPPDATA%\AroniumSync`. It removes everything except the `backups` folder and the copies in OneDrive.
- **Rehearse a takeover once** before you rely on it. See `VERIFY.md` for the checks that can only be done on the real laptops.

## For developers

- Tests: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1`. This needs Pester 5 (`Install-Module Pester -Scope CurrentUser -MinimumVersion 5.0 -SkipPublisherCheck`).
- The test runner downloads the pinned `sqlite3.exe` into `tools\` if it's missing.
- Tests build a small synthetic database from `tests\schema.sql`, which is Aronium 1.38.2.0's schema with no rows.
- If `fixtures\real.db` exists, every database test also runs on a copy of it. It's gitignored: put a copy of a real backup there yourself and never commit it.
- Layout:
  - All logic is in `AroniumSync.psm1`.
  - `publish.ps1`, `check.ps1`, `takeover.ps1`, `update-now.ps1`, `protocol-handler.ps1` and `clear-pause.ps1` are thin wrappers.
