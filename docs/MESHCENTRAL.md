# MeshCentral: remote support for the shop laptops

We reach the two client laptops (Aronium Lite POS + ar-sync) through MeshCentral.
It gives us remote desktop, a PowerShell terminal, and file access, at any time.

- URL: https://mesh.silongstrategies.com
- Server: the `silong` droplet, docker container `meshcentral`, files in `/opt/meshcentral`
- nginx site: `/etc/nginx/sites-available/meshcentral` (TLS by Let's Encrypt)
- The app listens on `127.0.0.1:4430` only. nginx is the only way in.

## 1. Create the "hardware store" device group

1. Sign in at https://mesh.silongstrategies.com.
2. On **My Devices**, click **Add Device Group** (or "Click here to create a device group").
3. Name: `hardware store`. Type: **Manage using a software agent**. Click **OK**.

## 2. Install the agent on each laptop

Do this on each laptop, signed in as a Windows admin.

1. In MeshCentral, open the **hardware store** group and click **Add Agent**.
2. Operating system: **Windows**. Installation type: **Background and interactive**.
   - "Background only" also works. It hides the tray icon, so the client can't see
     or stop it. Use it only if the client agrees (see the consent note below).
3. Download **Windows (64-bit)**. You get one `.exe` with the server and group built in.
4. Copy it to the laptop and run it as administrator. Click **Install**.
5. Within a minute the laptop shows up in the hardware store group. Rename it to something
   clear, like `Counter 1`.

The agent runs as the Windows service **Mesh Agent**. It starts at boot and
reconnects by itself.

To remove it later, run the same `.exe` and click **Uninstall**. Or use
**Remove** in the device's General tab.

### Let shop staff install it instead

`docs/INSTALL-REMOTE-HELP.md` is a one-page guide for staff. Before you print it, fill in:

- `<INVITE-LINK>`: open the **hardware store** group, click **Invite**, choose
  **Installation type: Background and interactive** and an expiry (e.g. 1 week),
  then click **OK** and copy the link it shows. Staff open it, and it gives them the
  Windows installer for the hardware store group. They don't need to sign in.
- `<HELP-CONTACT>`: the phone number or chat staff should use.

Once a laptop shows up, run section 3 on it right away through Terminal.

**Staff web page.** The same guide, with an "Install link" button, is at
https://silongstrategies.com/staff/, behind nginx basic auth. It lives only on the
server, in `/var/www/staff/index.html`, which is not in any git repo, so the invite
link never lands in git.

- Set or change the staff login: `ssh silong` then
  `sudo htpasswd -c /etc/nginx/.htpasswd-staff staff`. With no login set, the page
  refuses everyone.
- Paste the invite link: `sudo nano /var/www/staff/index.html`, then replace
  `PASTE-INVITE-LINK-HERE` (and `<HELP-CONTACT>`).
- The main domain goes through the Namecheap proxy to the droplet on plain :80. So the
  staff password travels unencrypted on that last hop. Use a password just for this
  page.

## 3. Stop the laptops sleeping on AC power

A sleeping laptop is offline. Run this in an admin PowerShell on each laptop.
You can run it through MeshCentral's Terminal once the agent is in.

```powershell
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0
powercfg /setactive SCHEME_CURRENT
```

- The first two lines turn off sleep and hibernate on AC.
- The last two make closing the lid do nothing on AC.
- Screen-off is fine. It doesn't drop the connection.
- Battery settings stay as they are.

To check: run `powercfg /query SCHEME_CURRENT SUB_SLEEP` and look for `0x00000000`
under the AC lines.

## 4. Consent note for the client

Tell the client in writing before you install the agent. Something like:

> We are installing a remote support tool (MeshCentral) on your POS laptops. It lets
> Silong Strategies see the screen, use a terminal, and copy files on these laptops,
> so we can fix Aronium and the sync tool without a site visit. Only our team can
> use it. We sign in with a password and a second factor, and the connection is
> encrypted. We will only connect for support of the POS and sync setup. You can
> ask us to remove it at any time.

Get a "yes" back (chat or email) and keep it. If they want to be asked first each
time, turn on **user consent** in the hardware store group: **Edit device group** →
**User Consent** → tick **Desktop**, **Terminal** and **Files**. The person at the
laptop then clicks Allow before a session starts.

## 5. Accounts and 2FA

- New sign-ups are off (`newAccounts: false`). Add more people from **My Users**.
- Turn on 2FA for every account: **My Account** → **Manage authenticator app** →
  scan the QR with an authenticator app → enter the code. Then save the
  **backup codes** somewhere safe (**Manage backup codes**).
- Idle web sessions log out after 30 minutes.
- Don't use `newAccountsPass` (the sign-up password) in 1.3.2. It always rejects
  the right password: the login page sends the field as `anewaccountpass`, but
  `webserver.js` (line 1782) reads `newaccountspass`. To let someone sign up, keep
  `newAccounts: false` and create their account from **My Users** instead.

## 6. Update MeshCentral

The image is pinned in `/opt/meshcentral/docker-compose.yml` (`ghcr.io/ylianst/meshcentral:<version>`).

```sh
ssh silong
cd /opt/meshcentral
tar czf /root/meshcentral-before-update-$(date +%F).tgz data   # backup first
sed -i 's|meshcentral:[0-9.]*|meshcentral:NEW_VERSION|' docker-compose.yml
docker compose pull && docker compose up -d
docker logs --tail 30 meshcentral
```

Agents update themselves after the server updates. Release notes:
https://github.com/Ylianst/MeshCentral/releases

## 7. Back up MeshCentral

- MeshCentral makes its own backup every 24 hours into `/opt/meshcentral/backups`.
  It keeps 14 days.
- That backup is on the same droplet, so it only helps if the data goes bad. If you
  lose the droplet, you lose it too. Pull a copy off the box now and then:

```powershell
scp -r silong:/opt/meshcentral/backups "$HOME\Backups\meshcentral"
```

- The important part is `/opt/meshcentral/data`. It holds the server keys that the
  agents trust, plus the user and device database. If you lose it, every agent must
  be reinstalled.

To restore on a new box: copy `data/` back into `/opt/meshcentral/data`, use the
same `docker-compose.yml`, point the DNS record at it, run certbot, then
`docker compose up -d`.

## 8. TLS certificate

- certbot renews the mesh cert by itself.
- A deploy hook (`/etc/letsencrypt/renewal-hooks/deploy/meshcentral.sh`) copies the
  new public cert to `/opt/meshcentral/data/webcert.pem` and restarts the container.
  That way MeshCentral tells agents the new cert hash.
- If agents ever drop after a renewal, run the hook by hand:

```sh
RENEWED_DOMAINS=mesh.silongstrategies.com sh /etc/letsencrypt/renewal-hooks/deploy/meshcentral.sh
```
