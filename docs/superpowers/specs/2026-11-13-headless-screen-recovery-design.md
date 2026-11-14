# Headless screen recovery on atlas (short design)

Date: 2026-11-13. Status: awaiting the user's approval. Not committed.

## Intent
When atlas's Dell monitor is asleep, the only screen Windows has is the MikeTheTech virtual display (`Root\MttVDD`, driver 11.30.4.434, `C:\VirtualDisplayDriver`). That driver crashed twice on 2026-11-13 (7:10 PM, 10:09 PM). After its retries Windows leaves it failed (`CM_PROB_FAILED_POST_START`), atlas has no screen, and the phone shows a dead-end "No displays". Connecting from the phone should show atlas's screen anyway.

## Goals
- Atlas brings the virtual display back by itself when it has failed, before or during a session.
- A phone that logs in while no screen exists waits briefly for the repair instead of getting an empty display list.
- Host-only change: one host DLL through the existing updater. No phone update.

## Non-goals
- Fixing why MttVDD crashes, or updating it.
- Installing RustDesk's own virtual display driver (approach C).
- Linux, macOS, or the phone's "No displays" wording.

## Anti-goals (a failure even if it works)
- Touching any device other than `Root\MttVDD`: no physical GPU, monitor, or other virtual display driver.
- Re-enabling a driver the user disabled on purpose (`CM_PROB_DISABLED`): only the failed/crashed state is repaired.
- A restart loop when the driver keeps crashing.
- Blocking an async task, or holding up logins when a screen already exists.

## Approaches
- **A. Repair at connect only.** Simple; does nothing for a crash mid-session or between sessions.
- **B. Watchdog plus repair at connect (chosen by the user).** The existing host watchdog repairs the driver whenever it is failed; a login that finds no screen also triggers the repair and waits for it.
- **C. Install RustDesk's IDD.** A new system driver alongside the crashing one. Rejected.

## Design
- **Detection** (Windows only): find device nodes whose hardware ID is exactly `Root\MttVDD` (case-insensitive) and read their problem code. "Needs repair" means present with a problem code other than none and other than disabled.
- **Repair:** restart that device node, the same operation as `pnputil /restart-device <instance id>` that fixed it by hand tonight. The builder may call the SetupAPI/CfgMgr32 equivalent or run `pnputil` with a timeout; either runs off any async task.
- **Rate limit (one shared limiter for both callers):** at most one repair per 60 s. After 3 repairs in a row where the device is failed again at the next check, back off to one per 10 minutes until a check finds it healthy. My call.
- **Watchdog:** the existing `mirpg-host-watchdog` thread (`src/server/emulator/host_management.rs`) checks on each pass and repairs when needed. Only the process that runs the watchdog repairs, so two processes never restart the driver at once.
- **Login path:** where the host builds the login display list (`src/server/display_service.rs`, `try_get_displays_` / `is_inited_msg`), if `Display::all()` is empty and the device needs repair, request a repair (subject to the limiter, in a blocking-safe context) and poll `Display::all()` every 500 ms for up to 10 s before falling back to today's behaviour. If a screen exists, nothing changes and nothing waits. My call on the timings.
- **Logging:** one info line per repair attempt and its result; one warn line when backing off. No per-pass logging while healthy.

## Testing
- Unit tests for the decision and rate-limit logic (healthy, disabled, failed, back-off, recovery), without touching real devices.
- Existing focused suites stay green (emulator 167, lan 28, aperture_ 14).
- On atlas, with the user's go-ahead after install: with the Dell asleep and the driver failed, connect from the phone and see the 1080p screen; check the log shows one repair.

## Left to the builder
- API vs `pnputil` for the restart, and how the problem code is read.
- Module placement (a small Windows-only module beside `virtual_display_manager.rs` is preferred).
