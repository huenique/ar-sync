# Check on the real laptops

The tests run on a copy of a real Aronium 1.38.2.0 backup and on a synthetic database. Nothing was tried against a running Aronium, real OneDrive or real notifications. Check these on the shop's laptops before relying on sync.

## Aronium itself
1. **Exe, process name and database path.**
   - Run install and confirm it found the right `.exe`. Then check `aroniumExe`, `aroniumProcessName` and `dbPath` in `%LOCALAPPDATA%\AroniumSync\config.json`.
   - With Aronium open, `Get-Process | Where-Object Path -like '*Aronium*'` shows the real process name.
   - The default database path `%LOCALAPPDATA%\Aronium\Data\pos.db` comes from Aronium's help pages and hasn't been checked on a real install.
2. **Does Aronium keep data outside `pos.db`?**
   - Look for other files that change after a sale, for example config, cache or image folders next to `pos.db` or under `%APPDATA%`.
   - If there are any, they aren't synced.
3. **Does opening Aronium change the fingerprinted tables?** If so, the viewing laptop pauses on every launch, a false alarm.
   1. On the viewing laptop, after a restore, open Aronium.
   2. Look around without selling, then close it.
   3. Wait for the next check (5 minutes) and confirm there is no "Sales were recorded" notification.
   - Also try it with Aronium left open for an hour. Stock recounts, Z-reports or automatic price updates would show up here.
4. **Does closing with CloseMainWindow work?** Click **Update now** while Aronium is open. It should close within 30 seconds and reopen.
   - If Aronium asks "are you sure?" on exit, or minimizes to the tray, it won't close. You'll see "Please close Aronium" every time.
   - This is safe, but not useful.

## Windows
5. **Do the notification buttons work on this Windows build?**
   - Check that **Update now**, **Later** and **Take over** each run their action.
   - The log shows `Toast button: <action>`.
   - Windows asks which app should open `aronium-sync` links the first time. Choose Windows PowerShell and tick "always".
6. **Does the "Sales were recorded" notification stay on screen?**
   - It is sent as a Reminder notification with only a Dismiss button. Windows needs at least one button to keep a notification on screen.
   - Check it stays until dismissed and doesn't fade into the Action Center.
7. **Scheduled tasks.**
   - In Task Scheduler, check `AroniumSync Publish` (selling) or `AroniumSync Check` (viewing): Last Run Result `0x0`, running as the shop's user.
   - Check whether a PowerShell window flashes up each run. That would mean `-WindowStyle Hidden` isn't enough on this machine.
8. **Publish at shutdown.**
   - The selling laptop's task also triggers on event 1074 (a user-started shutdown or restart).
   - Shut down from the Start menu and check `sync.log` and OneDrive for a copy from that moment. Windows may cut the task off before it finishes.
   - Logoff alone is not covered: Task Scheduler has no logoff trigger. The logon trigger and the 15-minute timer cover the gap.
9. **OneDrive keeps the folder on the device.**
   - Install runs `attrib +P` on the `aronium` folder ("Always keep on this device"). Confirm the folder shows a solid green tick on the viewing laptop.
   - If not, right-click the folder and choose **Always keep on this device**.

## End to end (rehearse once)
10. Ring up a test sale on the selling laptop. Within 20 minutes, the viewing laptop shows it after **Update now**, or by itself if Aronium was closed.
11. Ring up a sale on the viewing laptop. Within 5 minutes you see "Sales were recorded", and `SYNC-PAUSED.txt` exists. Clear it and check the next copy loads, with the old file in `backups`.
12. **Take over:**
    1. Turn the selling laptop off.
    2. Wait for "Main laptop last synced", or run the desktop **Take over** icon.
    3. Click Yes.
    4. Check that the next receipt number is 500 higher and the printer still works.
    5. Turn the old laptop back on. Check it shows "no longer the selling laptop" and does not change `OneDrive\aronium\latest.json`.
    6. Reinstall the old laptop as reader.
