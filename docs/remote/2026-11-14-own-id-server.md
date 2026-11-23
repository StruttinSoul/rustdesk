# Own ID server on atlas — 2026-11-14

## Why
RustDesk's public server now refuses clients without an account, and Aperture has none. The secured home path (TCP 21120) only trusts a peer identity signed by the ID server, so a freshly installed app could never bootstrap: the first connection had to go through the public server, which refused it. The user chose to run RustDesk's open-source ID server on atlas, home network only.

## Setup (done with the user's go-ahead)
- RustDesk server 1.1.16 for Windows (`rustdesk-server-windows-x86_64-unsigned.zip`, SHA256 `b865a3a6…7adb0`, matches GitHub's recorded digest). `hbbs.exe` and `hbbr.exe` in `C:\ProgramData\Aperture\id-server` (ACL: SYSTEM and Administrators only; the private key `id_ed25519` is there).
- Scheduled tasks `\Aperture\Aperture ID server` (`cmd /c set DB_URL=C:\ProgramData\Aperture\id-server\db_v2.sqlite3&& hbbs.exe -r <atlas-ip>:21117 -k _ >> hbbs.log`) and `\Aperture\Aperture relay` (`hbbr -k _ >> hbbr.log`): at startup, as SYSTEM. As SYSTEM, hbbs otherwise puts its database in the Aperture service's config folder (`LocalService\AppData\Roaming\RustDesk\config`); the files it left there were moved to `id-serverrom-service-config`. Under NetworkService hbbs never started listening, so it stays SYSTEM.
- Watchdog `\Aperture\Aperture ID server watchdog` (every minute, SYSTEM, `id-server\watchdog.ps1`): restarts hbbs when nothing listens on TCP 21116 (after a 180 s start grace; one start took ~110 s) and starts hbbr if it is not running. Restarts are logged in `id-server\watchdog.log`. Why: hbbs 1.1.16 on Windows drops its listeners after a UDP "connection reset" (os error 10054), seen several times on 2026-11-14 (e.g. when the phone left Wi-Fi), then logs `Timeout of test_hbbs`.
- Firewall group `Aperture`: only the ID server and relay ports, only from the home network and WireGuard (details kept out of this public copy). No router ports were opened.
- Atlas's Aperture service: `custom-rendezvous-server` and `relay-server` = `<atlas-ip>`, `key` = `<id-server-key>` (public key). Before, all three were empty (built-in public servers). Script and result: `target/own-id-server-20261114/`.
- Phone apps: Settings → ID/Relay Server, same ID server, relay server and key; API server empty.

## Verified
- Aperture 1.5.5 (new release key) on the phone: first connection went through `<atlas-ip>:21116` (45 ms TCP punch), saved atlas's identity; after the password login, connections take the home path (39–41 ms).
- The phone reaches atlas through WireGuard even at home (`<atlas-ip> dev tun0 src <vpn-ip>`), and away from home (mobile data + WireGuard) the user confirmed it connects (2026-11-14).

## Not verified / limits
- Atlas now posts connection audit records to `http://<atlas-ip>:21114/api/audit/conn` (derived from the custom ID server); the free server has no API, so each post fails after ~46 s of retries. Log noise only.
- Two one-off TCP connect failures over the tunnel (21120 at 11:25:38, 21116 at 11:26:30) each succeeded on the next try.
- Aperture Test still uses the built-in servers; its home path works because it already saved atlas's identity.
- While hbbs is down (up to a few minutes after a 10054), new installs cannot bootstrap and atlas logs rendezvous errors; the home path (at home and over WireGuard) does not depend on it. Running hbbs on Linux would avoid the Windows behaviour.
- Rollback: on atlas set the three options back to empty, then disable the three scheduled tasks and the `Aperture` firewall group.
