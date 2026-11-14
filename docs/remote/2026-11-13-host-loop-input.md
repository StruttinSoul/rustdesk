# Host connection loop and guest input path — 2026-11-13

## Request
After a project review, the user asked to fix what could be fixed from a remote agent session, using subagents. Two host-side Rust changes were made. Nothing was built, deployed, installed or committed.

## Changes (Rust host only; no protocol, Flutter, phone or service change)

### 1. Host jobs no longer block the connection loop
`on_emulator_request` used to await inventory (`List`) and every `Host` action inline in the per-connection select loop. While it waited, the loop could not drain guest video events (queue of 8) or read input, so frames overflowed and the encoder was reset. `emulator_shutdown` could hold the loop for up to ten seconds. The 2026-10-15 lag note fixed this from the phone side by polling less; this removes the host cause.

- New `src/server/emulator/host_worker.rs`: a lazily started, per-connection worker task. Jobs run one at a time in arrival order through `spawn_blocking`. The replay cache (`HostOperationReplay`) now lives in the worker. The job queue is bounded at 32; a full queue answers `Host is busy; retry shortly`.
- Results return to the loop as a new `GuestEvent::Host { generation, response }` on the existing event channel and are sent by the loop as before. A result whose generation no longer matches the connection is discarded.
- `reset_session_scope_for_login` drops the worker, which cancels queued jobs and empties the replay cache. A job already inside `spawn_blocking` finishes; its result is not delivered.
- `src/server/connection.rs` changes by three lines: the `emulator_operation_replay` field is replaced by `emulator_host_worker`.
- Authorization (`authorize_request`, `authorize_host_operation`) is unchanged and still runs before a job is queued.

### 2. Guest input path
- `guest_runtime.rs`: `TCP_NODELAY` on the scrcpy control socket, so small touch and key packets are not held by Nagle.
- `remote_windows.rs` `input_loop`: the geometry mutex is copied and released before socket writes. It was held across writes with a one-second timeout, which could stall the capture thread and the watchdog.
- `remote_windows.rs` `GuestSession::input`: the input queue grows from 32 to 256, and touch moves are dropped once 24 requests are pending. Down, up, cancel, key, text and navigation events are never dropped. Before, a burst that filled the queue failed the whole session.

## Validation
**The crate was not compiled and no repo test was run.** No Windows toolchain is reachable from the agent environment.

- All edited files parse with rustfmt (edition 2021).
- `host_worker.rs` was copied byte-for-byte into a standalone tokio crate with stub types: 7 worker tests and 1 simulated connection-loop test pass, 20 runs out of 20, and 7 deliberately broken variants were caught.
- The move-shedding function was tested standalone against a copy with stub types.
- Each task had an independent review by a separate agent that had not seen the work: no Critical or Important findings. The Task 2 review also read the client (`emulator_model.dart`, `src/client/emulator.rs`, `src/flutter.rs`) and found that responses are matched by `request_id` and kind, not by arrival order.

Required on atlas before any deployment, using the focused-test recipe and environment recorded in `2026-10-15-android-lag.md`:

    cargo test <focused-test flags from that note> emulator::host_worker
    cargo test <focused-test flags from that note> emulator::remote
    cargo test <focused-test flags from that note> emulator::remote_windows

Then a normal optimized Windows build, and a non-Windows `cargo check` if that target is still kept building (the new `GuestEvent::Host` variant is compiled on every platform).

## Later the same day — built and tested on atlas
The user ran `target/aperture-host-fixes-20261113/run-host-checks.cmd` on atlas (Rust 1.75.0 from `.rustup/toolchains`, `VCPKG_ROOT=%LOCALAPPDATA%/MIRPG/windows-cache-sdk`, `LIBCLANG_PATH=C:/DevTools/vcpkg/downloads/tools/clang/clang-15.0.6/bin`). The window's PATH had no `cargo`; the script adds the toolchain's own `bin` folder.

- `cargo test --release --lib --features flutter,hwcodec,vram --config profile.release.package.rustdesk.opt-level=0 --config profile.release.package.rustdesk.codegen-units=16 --no-fail-fast emulator` → **163 passed, 0 failed, 13 ignored** (the device-specific tests). All 7 `host_worker` tests, the 3 new input tests and the existing replay tests are in that count.
- `cargo build --release --lib --features flutter,hwcodec,vram` → finished in 12m 27s. Output `target/release/librustdesk.dll`, SHA256 `f12bdff648b974ab320fe4e47d15a0bb094565ff46c3a5c12f5bfc2da04d53d9`. No new warnings in the changed files.
- Logs: `target/aperture-host-fixes-20261113/checks/`.

This supersedes the "not compiled" statement above for Windows. Still not done: non-Windows `cargo check`, staging/deployment to the installed host, and any phone test.

## Batch 2 and staged update — same day, afternoon
Second host batch, reviewed but **not yet built or tested on atlas** (run `run-host-checks.cmd` again):
- `src/server/connection.rs`: the host worker is dropped in `on_close` right after `closed = true`, and again after the select loop, so queued host jobs do not start while a connection is closing. The one `send_close_reason_no_retry` await before `on_close` in some arms still runs with the worker alive.
- `src/server/emulator/guest_runtime.rs`: the fullscreen scrcpy profile comes from four host options, read once per session start with `Config::get_option` like `aperture-secure-lan`. Unset, empty, non-numeric or out-of-range values fall back per field, and the default argument list is unchanged. Preview sessions never read them.
  - `aperture-guest-max-size` 720–1920 (default 1280); `aperture-guest-max-fps` 15–60 (30); `aperture-guest-bit-rate` 1000000–16000000 (4000000); `aperture-guest-keyframe-interval` 1–10 s (1).
  - Set from an elevated shell, derived from the `--option` handler and not yet run: `& "C:\Program Files\RustDesk\RustDesk.exe" --option aperture-guest-max-fps 60`. Queue sizes are counted in frames, so 60 fps halves the burst headroom; treat these as experiments to measure on the phone.

Staged DLL-only update for batch 1 (the DLL built and tested above, SHA256 `f12bdff6…04d53d9`), in `target/aperture-host-fixes-20261113/deployment/`: `validate-host-update.cmd` (no admin, no change, writes `preflight.json`), then `install-host-update.cmd` (UAC). The install backs the current DLL up to `%LOCALAPPDATA%/MIRPG/host-backups/aperture-host-fixes-20261113-<UTC>/`, stops the service and installed-path `RustDesk.exe` processes, replaces only `librustdesk.dll`, restarts the service, checks that exactly one installed file changed, and rolls back on failure. It was reviewed twice by a separate agent and passed a mocked suite (22 scenarios), but **has never run on Windows**. Not installed. Open minor findings are in `task-4-review.md` and `task-4-rereview-1.md`.

## Known limits
- Host and inventory responses now arrive asynchronously. A late inventory can overwrite the shared error text in `emulator_model.dart`, and an inventory that arrives after a `desktop` reset is ignored until the next refresh. Both are cosmetic.
- After a login reset, a mutation still running in `spawn_blocking` can overlap the first job of the new worker.
- After the connection loop exits, queued jobs can still start until the `Connection` value is dropped.
- With 33 jobs outstanding, a retried operation gets the busy error while its original is still queued.
- Phone behaviour is unverified: touch feel with `TCP_NODELAY`, shedding thresholds, and whether the freeze during inventory or shutdown is gone.

## Files and rollback
Edited: `src/server/emulator/host_worker.rs` (new), `src/server/emulator/connection.rs`, `src/server/emulator/remote.rs`, `src/server/emulator.rs`, `src/server/emulator/remote_windows.rs`, `src/server/emulator/guest_runtime.rs`, `src/server/connection.rs`.

Workspace `target/aperture-host-fixes-20261113/`: pre-change copies in `before/` and `before-task-2/`, `task-1.diff`, `task-2.diff`, briefs, implementer reports, reviews and the ledger `progress.md`. It also holds a snapshot of the whole uncommitted tree taken before these edits: `pre-task-tracked.patch` (tracked changes against HEAD 854aed08d) and `pre-task-untracked.tgz`. To roll back, copy the `before/` files over the edited ones and remove `host_worker.rs`.
