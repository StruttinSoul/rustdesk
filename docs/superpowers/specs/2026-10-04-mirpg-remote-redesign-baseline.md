# MIRPG Remote Redesign Baseline

Date: 2026-10-04
Status: Baseline reconciled against `448501369ae567677091fe37615f0a5c499f5094`; product-code implementation has not started for this redesign.

## Purpose

This document turns the October 4 MIRPG Remote design handoff into a repository-local baseline. It records what already exists, what is only partially present through upstream RustDesk capability, and what still requires product work. The handoff remains the design authority; this file is the engineering reconciliation that travels with the codebase.

The fourteen visual boards referenced by the handoff are not present in this checkout or in the supplied attachment set. The written palette, vocabulary, behavior, and state requirements are sufficient to plan and implement the application shell. Pixel-level visual fidelity to those boards remains unverified until the actual board assets are available.

## Fixed Product Decisions

- Primary phone target is the Samsung Galaxy S25 Ultra (`SM_S938W`).
- One authenticated RustDesk session owns the Windows PC, monitor streams, BlueStacks targets, System, Files, Shell, and Codex.
- Authentication, negotiated permissions, target ownership, input release, and existing capability gates remain authoritative.
- BlueStacks remains an official installation and is controlled through the existing provider/helper boundary.
- Connected workspace navigation vocabulary is `Overview · System · Files · Shell · Codex`; settings and destructive session actions live in overflow or dedicated panels.
- Android guest fullscreen keeps the left target switcher and the right Back/Home/Recents rail outside guest pixels.
- Windows control evolves from Fit toward Fit/Readable/precision modes without replacing the existing authenticated stream.
- Direct/Relay and health labels must report observed session state. Private IP addressing alone is not enough to claim LAN.
- The visual base is restrained graphite/mint: background `#101416`, surface `#191F22`, raised surface `#242C30`, primary text `#F1F4F5`, secondary text `#AEBAC0`, accent `#70D8C1`.
- The redesign is feature-scoped. Do not globally rewrite upstream RustDesk theming when a mobile shell/theme wrapper is sufficient.

## Current Architecture

`RemotePage` still owns the authenticated outgoing RustDesk session. Once peer authentication and the `target_dashboard` capability are present, it pushes `TargetDashboardPage`. The dashboard keeps a single session alive while it subscribes to visible monitor/BlueStacks previews, promotes a selected target to fullscreen, and switches input ownership within the same connection.

The connected workspace already embeds System, Files, PowerShell terminal, and Codex pages. `EmulatorModel` owns dashboard preview state, selected guest state, guest navigation, host management requests, and stale-response rejection. Monitor video continues to use RustDesk display streams and the ordinary session input model.

This means P1 does not require a protobuf or Windows-host change. Later phases should first reuse existing RustDesk options before adding protocol surface.

## Existing Capability Reuse

The baseline inspection confirmed these capabilities already exist beneath the current mobile UI:

| Capability | Existing source | Redesign implication |
| --- | --- | --- |
| Live BlueStacks + monitor targets | dashboard/emulator protocol and target-keyed image slots | Keep; redesign presentation and controls. |
| Host health/recovery/processes | `HostManagementPage` + emulator host management request | Keep; improve stale/unavailable truthfulness later. |
| File transfer | existing RustDesk file manager | Keep transport; redesign mobile workflow/states. |
| PowerShell terminal | existing embedded `TerminalPage` | Present as `Shell`; retain PowerShell semantics. |
| Native Codex bridge | `CodexPage` / `CodexModel` / host Codex service | Keep; redesign surrounding shell only in P1. |
| Clipboard | RustDesk clipboard + file clipboard channels | Directional clipboard panel is integration work, not a new clipboard transport. |
| Quality/codec telemetry | `QualityMonitorModel`, image-quality/codec controls | Build Auto/Sharp/Smooth and health UI on real telemetry. |
| Block local input | `block-input` / `unblock-input` with server acknowledgement | P4 security panel should expose real state and failures. |
| Privacy/blank display | existing RustDesk privacy-mode implementations | P4 should gate by advertised support and show acknowledgement. |
| Lock after session end | `lock_after_session_end` peer option | P4 should expose the existing option rather than inventing a lock command. |
| Remote resolution | `sessionChangeResolution` + advertised resolutions | P4 can integrate the existing capability with safer UX. |
| Virtual display | existing RustDesk virtual-display manager/menu | P5 phone workspace is lifecycle/UX work on top of an existing backend capability. |

## Screen Baseline

Status vocabulary: **Implemented** means the requested behavior is materially present; **Partial** means useful behavior exists but misses handoff requirements; **Inherited** means upstream RustDesk provides the capability but MIRPG-specific UX is not built; **Absent** means no matching product surface was found.

| ID | Screen | Baseline |
| --- | --- | --- |
| S01 | Computers root | Partial — standard RustDesk connection/peer root, last-PC reconnect, search/autocomplete; MIRPG shell and requested states are not redesigned. |
| S02 | Connect/auth | Partial — standard RustDesk auth, acceptance, errors, reconnect; not presented in the new shell. |
| S03 | PC Overview | Implemented functionally — live BlueStacks/monitor cards, Boot, errors/retry, capability gating; visual shell is legacy. |
| S04 | Windows Fit | Implemented functionally — fitted monitor, TeamViewer-style pointer/toolbar; scale vocabulary and shell need redesign. |
| S05 | Windows Readable | Absent. |
| S06 | Target chooser | Implemented functionally — live in-session chooser and dashboard return; redesign pending. |
| S07 | Remote keyboard | Partial — text send plus special keys exists; deliberate Keys/Text, held modifiers, and richer state treatment pending. |
| S08 | Guest fullscreen | Implemented functionally — orientation, direct touch, left chooser, right Back/Home/Recents, error states. |
| S09 | System summary | Partial — live CPU/memory/uptime/watchdog exists; freshness/unavailable states need stronger modeling. |
| S10 | Recovery actions | Implemented for current bounded recoverable components. |
| S11 | Processes | Implemented baseline — search and confirmed End task; race/result polish remains. |
| S12 | File browser | Inherited/Partial — mature RustDesk file browser embedded in workspace; mobile redesign pending. |
| S13 | File select/destination | Inherited/Partial. |
| S14 | File operations | Inherited/Partial. |
| S15 | Transfers | Inherited/Partial — real transfer jobs exist; requested queue/status presentation needs redesign. |
| S16 | Shell | Implemented baseline through embedded terminal; MIRPG state shell pending. |
| S17 | Shell tools | Partial — terminal keyboard helpers exist; requested explicit safe paste/IME tool treatment pending. |
| S18 | Codex list/New | Implemented. |
| S19 | Codex conversation | Implemented. |
| S20 | Codex approval | Implemented with live Approve/Deny reconciliation. |
| S21 | Codex unavailable | Implemented with Windows-app fallback. |
| S22 | Settings root | Inherited/Partial — broad RustDesk Settings exists; MIRPG scope grouping pending. |
| S23 | Connection/account settings | Inherited/Partial. |
| S24 | Display/input settings | Partial — upstream view, quality, codec, resolution options exist; requested per-target MIRPG controls pending. |
| S25 | Permissions | Partial — negotiated permission state exists; dedicated truthful permission surface pending. |
| S26 | Chat | Inherited. |
| S27 | Share this phone | Inherited through RustDesk server/share screen. |
| S28 | QR scanner | Inherited. |
| S29 | Remote camera | Inherited. |
| S30 | Global connection states | Partial — reconnect/error machinery exists; fresh-frame/input-off continuity contract needs explicit MIRPG state. |
| S31 | Precision panel | Absent. |
| S32 | Directional clipboard/text exchange | Partial — transport exists; dedicated direction/safe-paste UI absent. |
| S33 | Window picker | Absent. |
| S34 | Privacy/security panel | Partial — backend options exist; coherent state/acknowledgement panel absent. |
| S35 | Phone workspace | Partial backend — virtual display exists; phone-oriented lifecycle/presets/session UX absent. |

## New Feature Baseline

| ID | Feature | Baseline / target phase |
| --- | --- | --- |
| N01 | Unified workspace/tokens | Partial; P1. |
| N02 | Fit/Readable | Fit present, Readable absent; P2. |
| N03 | Same-frame minimap | Absent; P2. |
| N04 | Explicit Pan | Absent in MIRPG monitor controller; P2. |
| N05 | Collapsible/dockable controls | Partial hide/show toolbar only; P2. |
| N06 | Optional touchpad panel | Upstream pointer widgets exist but are not integrated into this monitor controller; P2 optional. |
| N07 | Orientation policy | Partial automatic target orientation; P2. |
| N08 | Recent/pinned window jumping | Absent; P4 and host capability investigation. |
| N09 | Precision gain | Absent; P2. |
| N10 | Movable L/R buttons | Absent; P2. |
| N11 | Double-tap-hold drag + drag lock | Absent; P2. |
| N12 | Sticky key strip | Partial special-key panel; P2. |
| N13 | Editable shortcuts | Absent; P2. |
| N14 | Keys vs Text | Partial; P2. |
| N15 | Per-target gesture guide | Partial generic help; P2. |
| N16 | Auto/Sharp/Smooth quality profiles | Quality controls/telemetry exist; named profiles absent; P3. |
| N17 | Honest session health | Partial Direct/Relay + quality telemetry; P3. |
| N18 | Safe reconnect continuity | Partial reconnect machinery; P3 needs explicit stale-frame/input gating and restoration policy. |
| N19 | Clear minimize vs End session | Partial; P1 makes End explicit and prevents silent Back disconnect, P3 can add true background/minimize continuity. |
| N20 | Cursor offset | Absent; P2. |
| N21 | Precision loupe | Absent; P2 optional. |
| N22 | Thumbwheel scrolling | Absent; P2. |
| N23 | View-only input guard | Host permission guard exists; local voluntary guard absent; P2. |
| N24 | Directional clipboard | Transport exists; UI absent; P2/P4. |
| N25 | Physical display blanking | Existing privacy-mode backend; redesigned acknowledged control in P4. |
| N26 | Lock local input | Existing acknowledged block-input backend; redesigned control in P4. |
| N27 | Lock Windows on disconnect | Existing `lock_after_session_end` option; redesigned control in P4. |
| N28 | Phone workspace virtual display | Existing virtual-display backend; phone-workspace lifecycle in P5. |
| N29 | Explicit Windows resolution | Existing advertised resolution/change API; safer integrated UI in P4. |
| N30 | Stylus/advanced-stream capability investigation | Not established by this baseline; P0/P4 investigation. |

## P1 Scope: Coherent Application Shell

P1 is deliberately client-side. It establishes a consistent MIRPG visual language and navigation contract without changing remote transport or Windows-host protocol.

P1 will:

- add a feature-scoped graphite/mint Material 3-like theme used by the mobile root and connected workspace;
- present the root remote destination as `Computers` while preserving existing connection/peer behavior;
- present connected destinations as `Overview`, `System`, `Files`, `Shell`, and `Codex`, gated by the same negotiated capabilities as today;
- keep one navigation surface at a time and keep fullscreen target controls separate from workspace navigation;
- replace the ambiguous dashboard close affordance with a session menu that includes explicit `End session` and app settings access;
- make system Back from a fullscreen target return to Overview, and make Back from Overview avoid silently disconnecting;
- retain Direct/Relay truth from the current connection state;
- preserve live previews, guest/monitor switching, Boot, Files, Shell, System, Codex, keyboard permissions, and view-only behavior unchanged beneath the shell;
- remain usable on the S25 Ultra at 130% text scale and compact widths.

P1 will not add Readable/minimap/precision controls, new quality profiles, new host protocol, new security commands, phone workspace lifecycle, or exact reproduction of the missing visual boards.

## P1 Navigation and Session Contract

- `Overview` is the landing destination after authentication when target-dashboard capability is available.
- Selecting a monitor or guest enters fullscreen control. System Back from fullscreen returns to `Overview` and does not disconnect.
- System Back from `Overview` does not silently end the remote session. The user ends the connection through the explicit session menu.
- `End session` uses the existing RustDesk connection-close path so end-of-session auditing and lock-after-session behavior remain intact.
- `App settings` opens the existing Settings page above the connected workspace; returning keeps the remote session alive.
- True background/minimized-session return to the Computers root is deferred to P3 because the current `RemotePage` route owns session lifetime. P1 does not fake this by spawning a second Home route.

## Verification Boundary

P1 acceptance requires focused Flutter widget tests, Dart analysis of touched files, the existing dashboard/monitor/model regression tests, and an Android APK build. Physical S25 Ultra installation and visual comparison are valuable runtime checks but cannot establish fidelity to the missing fourteen design boards.
