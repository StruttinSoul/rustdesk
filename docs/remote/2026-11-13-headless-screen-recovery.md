# Headless screen recovery — 2026-11-13

## Request
After pairing worked, the phone showed "No displays": atlas's MikeTheTech virtual display (`Root\MttVDD`, driver 11.30.4.434) had crashed at 7:10 PM while the Dell slept, leaving Windows with no screen. The user chose approach B: the host watchdog repairs the driver, and a login with no screen waits briefly for the repair. Spec: `docs/superpowers/specs/2026-11-13-headless-screen-recovery-design.md`. Plan: `docs/superpowers/plans/2026-11-13-headless-screen-recovery.md`. Built inline (user's choice), then one whole-change review and one fix pass. Nothing committed.

## What changed
- `src/headless_vdd.rs` (new): finds display-class devices whose hardware ID is exactly `Root\MttVDD` and reads their problem code (SetupAPI + `CM_Get_DevNode_Status`). A device needs repair when the code is not 0 (healthy) and not 22 (disabled by the user). Repair runs `pnputil /restart-device <instance id>`, killed after 30 s. One shared limiter: at most one repair per 60 s; after 3 repairs in a row that leave it failed, one per 10 minutes until it is seen healthy. Logs one info line per repair and one warn on entering back-off.
- `src/server/emulator/host_management.rs`: the watchdog thread (every 20 s) calls the repair after its health probe. UI health queries never trigger it.
- `src/server/display_service.rs`: at login, if Windows has no screen, atlas asks for a repair and waits for a screen only while a repair is live (just issued, in progress, or finished in the last 10 s). The whole wait, repair included, is capped at 10 s. Logins with a screen take the old path with no added work.
- `src/lib.rs`: registers the module.

## Verification on atlas (Rust 1.75.0)
- Focused tests: headless_vdd 9 passed, 1 ignored; emulator 167/0 (13 ignored); lan 28/0; aperture_ 14/0; device_proof_decision 7/0; pair_decision 6/0. The ignored read-only test `find_mttvdd_lists_atlas_driver` was run on atlas and passed (finds the one MttVDD node). Logs: `target/headless-vdd-20261113/checks/`.
- `cargo build --release --lib --features flutter,hwcodec,vram`: finished in 6m 45s, 17 warnings (same count as before, none in touched files). DLL SHA256 `8a2f13e2c03d5d2c647c12deca375ce91cc216fc38973fd8f6a270ab331d5174`, in `target/headless-vdd-20261113/artifacts/`. It includes batch 2 and phone pairing.
- Whole-change review (`target/headless-vdd-20261113/final-review.md`): the release build failure and two login-wait problems were fixed with tests; 7 minor items deferred (listed in the ledger).

## Installed
- With the user's go-ahead on 2026-11-14: host DLL `797CD988…` → `8A2F13E2…` succeeded, service Running, only `librustdesk.dll` changed. Verified backup: `%LOCALAPPDATA%\MIRPG\host-backups\aperture-host-fixes-20261113-20261114T062721Z\`. The pairing-only DLL is kept in `target/aperture-host-fixes-20261113/pairing-dll/`.

## Not done
- The device test (Dell asleep, driver failed, connect from the phone).

## Known limits
- If Windows device enumeration itself hangs, the watchdog thread waits with it (logins do not: they give up after 10 s).
- The driver's crashes are not fixed; atlas only recovers from them. A newer MttVDD build may be worth checking.
