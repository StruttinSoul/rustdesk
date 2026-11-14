# Phone key pairing — 2026-11-13

## Request
The user asked for the phone to connect to atlas directly, with no ID or password, as a trusted device. They chose real device pairing and limited password-free login to home and WireGuard. Spec: `docs/superpowers/specs/2026-11-13-phone-key-pairing-design.md`. Plan: `docs/superpowers/plans/2026-11-13-phone-key-pairing.md`. Built task by task, each task reviewed by a separate agent, then one whole-change review and fix wave. Nothing committed, installed or deployed.

## What changed
- **Proof** (`src/aperture_device_proof.rs`, `libs/base/protos/message.proto`): Ed25519 signature over `aperture-device-login-v1`, host ID, salt, challenge and connection type, length-prefixed. New `LoginRequest.device_proof = 18`; pairing messages at `Message` 44/45. Older builds ignore the new fields.
- **Host list** (`src/server/aperture_trusted_phones.rs`, `src/ipc.rs`, `src/flutter_ffi.rs`): option `aperture-trusted-phones`, written only by the service under a lock. A whole-map options save from the UI cannot overwrite it. The desktop UI reads it and removes entries over IPC.
- **Host login** (`src/server/connection.rs`, `src/server.rs`, `src/lan.rs`, `src/rendezvous_mediator.rs`): a proof is accepted only when the connection came from the 21120 listener, the stream is encrypted, the connection is the main remote one, the key is listed and the signature is valid. Otherwise atlas replies `Device key not accepted`, keeps the connection open and does not show an accept prompt. Approve-mode, 2FA and the whitelist still apply. A listed key with a bad signature counts toward the failure throttle.
- **Host pairing**: accepted only on an authorized, encrypted session that logged in with a password. Errors `Pair from a password session`, `Pair over an encrypted connection`, `Invalid key`.
- **Phone** (`src/client/aperture_device_key.rs`, `src/client.rs`, `src/client/io_loop.rs`, `src/client/lan_fast_path.rs`, `src/ui_session_interface.rs`, `src/flutter.rs`): key in LocalConfig `aperture-device-sign-sk`; per-host flag `aperture-device-paired`. A proof is sent only on a LAN fast-path connection to a paired host, with an empty password. On rejection the phone clears the flag and reruns the normal password path on the same connection. The last verified LAN address (`aperture-lan-last-address`) is tried when discovery finds nothing, for WireGuard.
- **UI**: phone session menu shows **Trust this phone** / **Forget pairing**; desktop Security settings show **Trusted phones** with **Remove**.

## Verification on atlas (Rust 1.75.0)
- Focused tests: emulator 167 passed, 0 failed, 13 ignored; lan 28/0; aperture_ 14/0; device_proof_decision 7/0; pair_decision 6/0. Logs: `target/phone-key-pairing-20261113/checks/`.
- `cargo build --release --lib --features flutter,hwcodec,vram`: finished in 9m 29s, same 17 warnings as batch 2. DLL SHA256 `797cd98823dcf563890c0a34d7c73370e273bef8edc209477fe19b144510041a`, kept in `target/phone-key-pairing-20261113/artifacts/`. It includes batch 2.
- `flutter analyze` on the two pages: the same 5 infos as before, plus 2 errors because the local pub cache folder `device_info_plus-9.1.2` is empty (environment, not code).
- Android native library (ARM64, using the libsodium and build cache on E:): `librustdesk.so` SHA256 `875BE36E…B757`.
- Phone APK: the release-signed build is not possible on this Windows account, because the stored release-key password (DPAPI) no longer decrypts. At the user's request the side-by-side **Aperture Test** app was built instead (`-PapertureSideBySide=true -PmirpgTestApk=true`, ID `com.carriez.flutter_hbb.aperturetest`, 1.5.0/68, local debug-key signature `b324e23f…7d18`, not debuggable, 16 KiB aligned). APK SHA256 `2C6AE5CD07A7872E2291788A4A662E8590B51E64C3159B0A9571110986665FB5`, in `target/phone-key-pairing-20261113/apk/`. The release `mirpgtest` app is unaffected.
- Installed with the user's go-ahead: host DLL `F12BDFF6…` → `797CD988…` on 2026-11-14 (receipt `target/aperture-host-fixes-20261113/deployment/installation-result.json`, verified backup in `%LOCALAPPDATA%\MIRPG\host-backups\aperture-host-fixes-20261113-20261114T043309Z\`); the user installed the Aperture Test APK from a temporary LAN download link, since removed.
- Device test (2026-11-14, user): pairing from a password session and the password-free reconnect at home work. The user chose to skip the removal test. Mobile-data, 2FA and service-restart checks not run.
- Atlas's "No displays" on the first connection was not caused by this change: the MttVDD virtual display driver had crashed (7:10 PM) while the Dell slept. It was restarted with `pnputil /restart-device ROOT\DISPLAY\0000` and the virtual screen set to 1920x1080@60 (it crashed once right after the mode change, then held after a second restart). That driver build (2024-12) is the remaining risk for headless sessions.
- Not done: an iOS or non-Windows compile.

## Device test checklist (after installs, each with the user's go-ahead)
1. Connect from the phone with the password, tap **Trust this phone**; atlas lists it under **Trusted phones**.
2. Close and reopen Aperture at home: no password prompt.
3. Remove the phone on atlas, reconnect: the password prompt or saved password works, no accept prompt on atlas, and **Trust this phone** is back.
4. Mobile data without WireGuard: password prompt, as before.
5. With 2FA on (if used): a key login still asks for 2FA.
6. Restart the RustDesk service: the trusted list survives.

## Known limits
- WireGuard ending on atlas itself needs the 21120 listener to bind the tunnel address (separate WireGuard task).
- File transfer, terminal and other separate connections still use the password.
- Android's default backup includes app data, so the device key would be restored to a new phone from backup. Saved passwords have the same exposure.
- A corrupted stored key of the right length is not detected; the phone falls back to the password, and pairing again would re-enrol the same broken key.
