# BlueStacks adaptive Eco FPS — mock-only implementation checkpoint

Date: 2026-10-15  
Status: **SOURCE ONLY / DISARMED / NOT DEPLOYED**

## Scope and protected dependencies

- Jarvis BlueStacks 5, pinned Android 13 instances `Tiramisu64`, `Tiramisu64_2`, `Tiramisu64_3`.
- Existing ADB ports `5555`, `5575`, `5585` and separate ADB servers `5037` / `5041` remain unchanged.
- RustDesk/Aperture direct-guest capture, preview streams, keyboard/touch routing, MIRPG solver screenshots, startup/pre-login setup, BlueStacks macros, Android data disks and game accounts remain unchanged.
- Existing source changes in `remote_windows.rs`, `connection.rs`, `guest_runtime.rs`, Flutter and other projects were not replaced.

## Implemented

`src/server/emulator/eco_fps.rs` is a per-instance, backend-injected state machine. The existing Windows-only emulator module exports it, but **no production code starts it**. The only bundled backend explicitly rejects all attempts to read or change live BlueStacks settings.

- Policy defaults: `enabled=false`, Eco `12 FPS` (validated range `10..=15`), normal `60 FPS`, idle-confirmation period `120 s`.
- Per-instance state and strict identity allowlist; missing, stopped or duplicate observations are not eligible for changes.
- Eco is requested only after continuously verified inactivity in **remote, local and solver-capture** signals. Unknown or active signals keep normal mode, and force immediate restore when this controller owns the Eco transition.
- A disabled controller never changes an unowned setting; disabling an owning controller requests a restore on its next safe observation. Failed restore retains ownership for retry.
- The backend contract requires read-before-write and compare-and-set; pre-existing manually enabled Eco settings, changed settings and failures are not silently overwritten.
- All time is supplied by the caller as monotonic elapsed duration; synthetic tests advance it without waiting or contacting BlueStacks.

## Mock-only tests

Run without any ADB/emulator commands:

```powershell
rustc --edition 2021 --test src/server/emulator/eco_fps.rs -o "$env:TEMP\eco_fps_mock.exe"
& "$env:TEMP\eco_fps_mock.exe"
```

Test coverage: default-disabled behavior, three-instance isolation, 120-second idle transition, immediate local/remote recovery, unknown or active solver, duplicate/stopped/unknown instance rejection, manual Eco preservation, failure/retry, and unavailable real backend.

Validation on Jarvis: **8/8 standalone Rust mock tests passed**, `rustfmt --check` passed, and the tracked source diff passed `git diff --check`. The optional offline full-project release test initially stopped because `VCPKG_ROOT` was not set; with the documented Windows vcpkg/LLVM variables it advanced through the RustDesk crate and emitted unrelated existing warnings. This resource-heavy **full-project test was stopped before execution** rather than continuing to load Jarvis. It must not be reported as passing.

## Unresolved live activation gate

BlueStacks documents per-instance Eco settings through its toolbar/Multi-instance Manager, but does **not** document a supported remote programmatic Eco-mode API. A real backend using speculative ADB commands, direct `bluestacks.conf` edits while running, fake hotkeys or UI clicks would risk game state, RustDesk input or remote access. **None is included.**

Before any separately approved activation:

1. Verify a supported, version-pinned per-instance *live* Eco read/write/readback mechanism; preserve pre-existing settings and implement atomic compare-and-set or refuse when unsafe.
2. Connect current remote activity from authenticated guest sessions, qualified local BlueStacks foreground/input by stable instance identity, and the actual MIRPG solver-capture occupancy. Report Unknown if any signal is unavailable; never infer solver inactivity just because RustDesk is idle.
3. Gate runtime enablement and the writer behind separate approval and an explicit disabled-by-default switch. Preserve 60 FPS on interaction and confirm that guest scrcpy helper's current 30 FPS stream ceiling is a **different** setting.
4. Test one instance at a time with local/phone controls, solver screenshots, immediate restore, reconnects, pre-login startup and instance transitions, with rollback; do not modify ADB ports, boot settings, input mappings or `.vhdx` game disks.
5. Add a durable owned-setting recovery journal before a live writer is permitted, so RustDesk termination, failed restart or a changed manual Eco mode cannot silently strand a throttled instance.

This checkpoint does **not** claim to have reduced current CPU usage or FPS. It prepares and mock-tests the policy, not an operating BlueStacks controller.
