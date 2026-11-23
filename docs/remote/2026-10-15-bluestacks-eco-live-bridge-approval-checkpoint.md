# BlueStacks per-instance live Eco bridge — guarded approval checkpoint

**Date:** 2026-10-15 (Jarvis, Pacific time)  
**Decision:** **NO-GO for unattended/live activation.** Source and mock-only feasibility work complete.  
**Approval granted in this task:** Read-only investigation, synthetic tests, and this document only.  
**Not authorized:** Live Eco commands or hotkeys, UI clicks, Android/ADB actions, BlueStacks config writes, service/emulator restarts, APK deployment, RustDesk install/deployment, or changes to game/solver data.

## Executive finding

The one **vendor-documented per-instance live control** is BlueStacks 5's **Eco mode panel on each running instance's side toolbar**. It offers an on/off switch and editable Eco FPS. The Multi-instance Manager also exposes a toggle, but it affects **all running instances**. Vendor documentation does **not** establish an idempotent public, per-instance Eco read/write API for unattended use. Documentation is about operating the GUI, not promising that its controls are automatable.

Jarvis' signed BlueStacks 5.22.280.1026 configuration explicitly binds `bst.shortcut.toggle_eco_mode="Ctrl + Shift + F"`. This is an **unconditional toggle**, not a set-to-on/set-to-off command, and depends on the correct focused window. A shortcut cannot prove pre-state, verify post-state, or independently change Eco FPS.

The running BlueStacks App Player 1 window was inspected **read-only**, without opening the Eco panel or invoking a UI action. Its current Windows UI Automation subtree had 34 nodes, 29 anonymous buttons, **0 AutomationIds, 0 TogglePatterns, and 0 semantically labeled Eco/FPS controls**. This is evidence for the *current closed-panel view only*; the expanded Eco panel has **not** been inspected, so an accessible UI bridge remains **unproven**, not categorically impossible. Generic ValuePattern support on anonymous buttons is not reliable state readback.

**Recommendation:** Prefer the native vendor GUI for manual control. The sole candidate for a future automated bridge is a narrowly scoped, instance-bound Windows UI Automation adapter **only if a future read-only expanded-panel probe demonstrates unique semantic switch/FPS state, non-disruptive window ownership, and deterministic readback**. If not, stop; do not substitute keyboard injection, coordinates, native private IPC, ADB, or `bluestacks.conf` edits. No live backend has been added.

Vendor references:

- [BlueStacks: per-instance Eco mode, toggle, audio and Eco FPS](https://support.bluestacks.com/hc/en-us/articles/360052834772-How-to-run-multiple-instances-of-BlueStacks-5-more-efficiently-using-Eco-mode)
- [BlueStacks: Multi-instance Manager settings (some changes require stopped instances)](https://support.bluestacks.com/hc/en-us/articles/4422291276429-How-to-change-settings-in-the-Multi-instance-Manager-on-BlueStacks-5)
- [BlueStacks: shortcuts remain shared across instances](https://support.bluestacks.com/hc/en-us/articles/4402768474381-How-to-view-or-edit-shortcut-keys-on-BlueStacks-5)

## Verified Jarvis baseline

| Surface | Read-only finding |
| --- | --- |
| Installation | `C:\Program Files\BlueStacks_nxt`, version **5.22.280.1026** |
| Player signer | Authenticode **Valid**, **Now.gg, INC** |
| Player SHA-256 | `2F42CE395E18866A1B444FDBE696CEDB11DC2F01F594B561640CB9BE84301755` |
| Manager SHA-256 | `80F9C654B9598DAFC3903250DAA176D54498C45A9154309687B277BA8EB804B6` |
| Managed instance 1 | `Tiramisu64`, ADB **5555**, `max_fps=60`, `eco_mode_max_fps=5` |
| Managed instance 2 | `Tiramisu64_2`, ADB **5575**, `max_fps=60`, `eco_mode_max_fps=5` |
| Managed instance 3 | `Tiramisu64_3`, ADB **5585**, `max_fps=60`, `eco_mode_max_fps=5` |
| Host ADB | Pre-existing separate ADB servers at 5037 and 5041; not contacted |
| RustDesk / Aperture | RustDesk service running, automatic startup, unchanged by this work |
| Capture | Guest scrcpy helper's 30-FPS capture ceiling is **not** the BlueStacks emulator's 60-FPS normal target |
| Prior preservation | Local 19-file config/input/boot snapshot `C:\Users\<user>\AppData\Local\BlueStacks-Optimization\preserve-20261015T155011`; **not** a full Android data backup |

`bluestacks.conf` had SHA-256 `F1C63B8097D1C5C871F0DEC9207DB15AF7C578769B18FB2D3B75571BDEB6538D` when re-read at 2026-10-15 16:26 PDT. The file is ordinarily updated by BlueStacks; **do not treat this hash as an immutable activation pin**. Capture a fresh baseline immediately before any separately approved trial. The config's `eco_mode_max_fps=5` reflects a stored preference, **not proof that Eco is currently enabled or disabled**.

Protected components: RustDesk remote video/touch/keyboard and pre-login path; MIRPG/Yeti/Tangyoon solver screenshots and tasks; BlueStacks saved game data, installed applications, macros and input maps; BlueStacks network/ADB endpoints, hypervisor and existing service ownership. Existing dirty work in `src/server/emulator/remote_windows.rs`, `guest_runtime.rs`, `src/server/connection.rs` and Flutter is untouched by this checkpoint.

## Mechanisms evaluated

| Candidate | Evidence / consequences | Decision |
| --- | --- | --- |
| Per-instance native Eco side-panel | BlueStacks-supported live Eco toggle and FPS entry; no trustworthy automation readback yet | **Manual now; conditional automated candidate** |
| Per-instance `Ctrl+Shift+F` | Installed shortcut; toggle, shared shortcut mapping and focus-sensitive; cannot set 12 FPS | **Reject unattended** |
| Windows UI Automation bridge | Read-only closed-panel inspection found no named Eco state or TogglePattern; expanded panel untested | **Not approved until readback proof** |
| Multi-instance Manager Eco switch | Explicit global/all-running semantics; could disrupt other game instances | **Reject** |
| Edit `bst.instance.*.eco_mode_max_fps` | Stored 5-FPS preference; no verified live enable-state control or restart-free atomicity | **Reject as live actuator** |
| ADB, scrcpy, emulator guest settings | Controls Android guest/streaming, not the vendor-documented host Eco setting | **Reject** |
| Private BlueStacks IPC, reverse-engineered APIs, coordinate clicking, Windows CPU priority/affinity | Unsupported/unverified, may steal input or stall solver/remote streams | **Reject** |

## Activation contract (future work; all gates mandatory)

1. **Version and identity.** Revalidate exact signed BlueStacks binary/version, known `bluestacks:Tiramisu64[_2/_3]` stable ID, unique current PID + creation time + top-level HWND, owner/session, and matching instance. Never select by screen coordinates, title alone, ADB alias, or launch order.
2. **No disruptive input.** Obtain an isolated per-instance Eco UI context without altering game keys or stealing focus from active local or RustDesk sessions. Require stable, uniquely labeled semantic Eco enabled-state, Eco FPS value, normal cap, and audio state. If any is missing, ambiguous, offscreen, locked, minimized, stale, or changes after inspection: **abort without input**. No synthetic keyboard/Win32 coordinate fallback.
3. **Eligibility.** Use the existing disabled-default `eco_fps.rs` policy (120 s verified inactivity, 12 FPS Eco/60 FPS normal). Remote/local activity, MIRPG solver screenshot/recording occupancy, game automation uncertainty, preview freshness problems and any Unknown signal veto Eco entry. The policy currently has no production activity feed or scheduler.
4. **One owned writer.** Serial single-writer lock per instance across RustDesk user/service contexts. Re-read state immediately before each change, enforce compare-and-set, confirm no competing manual/user changes. Do not use a blind toggle for a state change.
5. **Before-write journal.** Private admin/SYSTEM-owned, non-user-writable separate directory (proposed `C:\ProgramData\MIRPG-EcoFps`, **not created**). Atomic create + file flush and durable per-instance record: version/hash, stable ID, PID+start, GUI state and FPS before, sound state, target state, owner/session, monotonic activity timestamp, operation nonce, stage `prepared/applied/verified/restore_due/conflict`. Secrets and user input content must not be stored. Preserve all unrelated existing journals.
6. **Apply with readback.** For current 5-FPS preference, verify and set Eco FPS to 12 using the verified per-instance GUI before enabling Eco. Preserve speaker state. Read back Eco enabled, FPS=12, unchanged sound, intact 60-FPS non-Eco cap and same process identity. Any partial/error result remains unresolved in the journal, not "success".
7. **Immediate restore.** On any remote/local activity or solver start, restore only the setting the controller verified it owns, using conditional readback and a separately recorded restore transaction. Revalidate original Eco state/FPS and sound. On disabled setting/exit, restore owned changes; don't touch pre-existing manual Eco.
8. **Crash and boot recovery.** On restart/failed GUI readback, a `prepared` transaction with changed observed state is **ambiguous**. Never blindly flip it; mark operator recovery required. If GUI is inaccessible after a verified owned Eco change, record restoration due, notify, and avoid changing another instance. Do not start/restart BlueStacks or RustDesk to recover automatically.
9. **Bounded execution.** All UI read/write attempts require short timeouts, one attempt per reconciled state, readback checks, throttled logs, no unbounded retries/spinning, and an immediate disable/kill switch that stops future writes. Keep journal until restore or operator-resolved conflict.

### Rollback procedure for a separately approved live pilot

Preflight: record the **actual** Eco on/off state, Eco FPS (currently configured preference 5, not necessarily active), normal cap 60, audio and timestamp separately for each involved instance. Record PID/HWND plus signed binary and store private journal safely **before** doing any GUI operation. Take a scoped config/control backup without touching `.vhdx` disks; preserve immutable copy and SHA.

Rollback: disable future transitions; for each *verified owned* transition, use only a uniquely bound vendor GUI with semantic readback and CAS to restore its exact captured Eco on/off state **and its original Eco FPS**, leaving sound and normal cap intact. Verify again. If user changed state, process identity drifted, the UI is hidden/locked or readback is missing, **do not guess or press Ctrl+Shift+F**: mark unresolved and use supervised manual per-instance UI review. Leave every other instance alone. Do not revert the entire shared BlueStacks config or RustDesk account settings as a shortcut.

Manual recovery reference (requires operator inspection, not executed): in the specific instance's side toolbar open Eco mode, compare its current on/off, FPS and sound to the preserved record; restore only the explicitly verified original Eco state and FPS. Re-check remote input and solver screenshots after any future approved live pilot.

## Mock-only proof collected in this task

Test file: `tests/bluestacks_eco_live_bridge_approval_mock.rs`. Runs as a **standalone Rust test binary** and imports the already existing `eco_fps.rs` policy; it contains **synthetic UI panels**, not Win32 automation or ADB commands.

```powershell
rustc --edition 2021 --test tests/bluestacks_eco_live_bridge_approval_mock.rs -o "$env:TEMP\bluestacks_eco_approval_mock.exe"
& "$env:TEMP\bluestacks_eco_approval_mock.exe"
```

Verified: **14 passed, 0 failed** (8 existing policy cases + 6 additional bridge/rollback cases). Additional checks demonstrate:

- Missing semantic Eco controls, invalid signer/process identity, unexpected version, duplicate windows and locked desktop **reject all writes**.
- One instance's synthetic 12-FPS Eco transition and restoration do not touch the other two instances or sound.
- Manual `Eco(5)` and manual changes after controller ownership block conflicting compare-and-set.
- Interrupted transaction before a click clears only if the original state is verified unchanged; interruption after a synthetic click stays **ambiguous** across simulated restart with no blind rollback.
- Unknown remote/local/solver activity never qualifies for Eco entry.

Important: The in-test journal is an **in-memory simulation**, **not a production durable/fsynced journal**, and mock success is **not evidence of real UI automation support**. Full RustDesk native build and any real GUI changes were intentionally not invoked.

Source pins (unchanged):

| Source | SHA-256 |
| --- | --- |
| `src/server/emulator/eco_fps.rs` | `E384A38B7AA861F7AAAA009E5F32097170D603DD8A5933FBBF97B29074043EC8` |
| `src/server/emulator/bluestacks.rs` | `EB1904202F962CB0B0F57F86F56756DA6FCF5A906E05C9617A1AF5B3C633D951` |
| New mock harness | `54659669AAB4E45C66C567B3B49031F0500B3284BCB76588C9011F64C42ADDC1` |

## Separate, specific future approval milestones

**Checkpoint A — Read-only GUI feasibility (next eligible action):** During a mutually acceptable window, inspect *only* the expanded Eco panel on one specific running instance; do not toggle it or change FPS. Confirm uniquely bound HWND/PID and accessible *semantic* current enabled state, Eco FPS, normal cap and sound, then close without modifying anything. If not possible without stealing an active user's input/focus, keep **NO-GO**.

**Checkpoint B — Disabled mock adapter:** Only if A proves semantic readback, add an isolated disabled/default-off Windows UI adapter with one-writer ownership, durable recovery journal, signer/version verification, mock GUI adapters/tests, and independent diff review. **No live activation.**

**Checkpoint C — One-instance guarded real acceptance:** Requires its own separate express approval and a proven reversible pilot. Begin with one specified instance only, stop on identity/readback/focus/input/solver discrepancy and preserve all game disks.

**Checkpoint D — Production multi-instance activation:** Further separate approval after verified RustDesk touch/keyboard/sound, hidden/minimized/lock, 60↔12 FPS behavior, CPU gains, all solver capture workflows, restore after close and remote reconnection. No global Eco toggles.

**Present status:** Approval checkpoint prepared. **Only Checkpoint A may be requested next. No live Eco bridge is currently ready for approval.**
