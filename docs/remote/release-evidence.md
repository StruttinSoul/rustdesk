# MIRPG Remote Release Evidence

WP0 evidence index. Inventory evidence is not implementation, build, install, or physical-device proof.

## WP0 gate

- Original features: 30/30 mapped in conformance-ledger.csv.
- Original flows: 35/35 mapped.
- Visual-kit states: 40/40 exact Appendix-A IDs mapped.
- Unpictured WP0 workflows: 3/3 mapped: window picker, stale System, safe paste.
- Gateway Appendix-C states: 13/13 mapped; WP15 source/unit/widget implementation is now verified, with live-runtime and physical-device evidence still outstanding.
- Dirty tracked work: 15/15 preserved with hashes in baseline.md.
- Historical Rust failures: 5/5 reproduced and classified.
- Missing historical references: explicitly recorded; no contents invented.
- Build/test commands and required environment: recorded in baseline.md.

## Baseline probes

- Three focused BlueStacks guest-video regressions previously passed.
- Secure baseline test fails at its assertion/harness boundary.
- Declined UDP-punch baseline test still times out in the helper/test path.
- Three KCP product tests still fail during KcpStream loopback establishment.
- Plain UDP loopback: pass.
- Connected UDP send/recvfrom loopback: pass.
- Pinned kcp-sys endpoint direct test with libclang configured: pass.

## Evidence required as packages land

For each ledger row moving toward complete, record exact source commit and dirty state; exact tests and commands; selected/pending/applied/unsupported/stale/failed behavior; actual Windows host capabilities and permissions; S25 screenshots and interaction evidence; reconnect/no-replay behavior; matched Android/Windows artifact hashes; remaining limitations and any explicitly approved deviation.

## Physical/runtime matrix still unverified

- Windows control on the real roughly-2K monitors: pointer, tap, right click, two-finger scroll, pinch, Pan, Fit/Readable, minimap, cursor follow, scroll thumb and window picker.
- Release of mouse buttons, modifiers and guest touches across interruption, target change, rotation, backgrounding and view-only.
- BlueStacks live preview, direct touch, Resume/Boot/Launch-game separation, Back/Home/Recents, rotation and decoder continuity.
- Actual LAN route preference and session-health readings without application-queue inflation.
- IME/Unicode text and multiline safe paste with no implicit Enter/execute.
- Codex runtime ownership, acknowledgment/draft behavior and exact approvals.
- Files/System/Shell error and recovery states.
- Privacy/input lock/lock-on-disconnect and Phone Workspace owned lifecycle.
- Gateway status/setup/IMDb/restart against the real supervisor.
- 1.0/1.3/2.0 text scale, safe areas, IME, TalkBack, portrait/landscape and required loading/stale/error states.

WP14 may only claim the remote milestone after matched binaries and runtime evidence pass. Whole-project completion additionally requires WP15 live Gateway runtime evidence and WP12 visual conformance.

## WP1 capability, ownership, and acknowledgment gate

WP1 establishes the mutation-safety contract used by later packages. It does not complete the user-facing WP2-WP15 features by itself, so no original N/S/visual ledger row is promoted to complete on this evidence alone.

- Capability negotiation: inventory advertises `operation.identity.v1`, `operation.ack.v1`, `host.status`, `host.process_end`, and `host.recover.bluestacks_adb`. Missing/unnegotiated capability data leaves new actions unavailable.
- Mutation identity: host mutations bind `operation_id`, authenticated `session_identity`, exact `target_identity`, and `session_generation`. Login/session-scope reset rotates the host operation identity and generation.
- Acknowledgment: host mutation replies distinguish `accepted` from `state: applied|failed`, carry a typed `error_code`, echo operation/session/target/generation identity, and include an observed snapshot when available.
- Unknown outcomes: the Flutter mutation timeout is 20 seconds and becomes `unknownOutcome`; generation changes also invalidate pending work as unknown. Neither path becomes success.
- Authorization: host control permission is enforced independently of Flutter visibility. Forged targets, stale generations, mismatched sessions, unsupported actions, and operation-ID reuse against a different action/target are rejected.
- Replay safety: the host keeps a bounded per-connection completed-operation replay cache for the implemented host mutations. Exact duplicates return the cached reply under the new `request_id`; they do not execute the mutation again. The client never automatically replays a consequential action on reconnect.
- Read-only overlap: `host.status` request state is independent from mutation pending state, so a status response cannot clear a still-pending process/recovery operation.
- Package-wide contract: `capability-action-table.md` records authority, identity, timeout, reconciliation, and old-peer behavior for WP1-WP15. Later-package rows are explicitly proposed/unimplemented where that behavior has not landed.

Fresh focused evidence on 2026-10-05:

- `C:\flutter-3.24.5\bin\flutter.bat test test\emulator_model_test.dart test\remote_conformance\capability_contract_test.dart test\remote_conformance\host_capability_ui_test.dart` → 18 passed, 0 failed after the final acknowledgment-capability wiring.
- `cargo test --lib host_ -- --nocapture` with `VCPKG_ROOT=C:\vcpkg` and `LIBCLANG_PATH=C:\LLVM-15.0.6\bin` → final run 10 passed, 0 failed.
- `cargo test --lib operation_ -- --nocapture` with the same environment → final run 5 passed, 0 failed.
- TDD evidence for the final acknowledgment distinction: `accepted_host_mutation_can_still_fail_to_apply` first failed because `accepted` was absent, then passed after implementation; `failed_host_mutation_ack_preserves_operation_identity` also passed with `accepted: false` and `error_code: unsupported_action`.
- `git diff --check` passed after the final acknowledgment changes with only line-ending conversion warnings.

Remaining WP1 release evidence gap: these are source/unit/widget checks. The actual Windows host + Android phone still needs WP14 matched-binary runtime proof for permission denial, lost acknowledgment, reconnect/generation change, and old-peer degradation. Those physical/runtime checks are not inferred from the tests above.

## WP2 liveness and held-input safety gate

WP2 now has source-level coverage for the current Windows-monitor and Android-guest input paths. This does not promote the physical/runtime matrix to complete; the real Windows host and phone still need matched-binary WP14 evidence.

- Desktop liveness separates transport heartbeat, per-display stream heartbeat, decoder health, current-session frame identity, and visible frame age. A static desktop can remain controllable while its last pixels are old, provided transport, decoder, required stream heartbeat, target identity, and reconnect generation are current.
- Current Windows hosts advertise `desktop.stream_liveness.v1` and emit a per-display video-stream heartbeat. Older peers do not require that new heartbeat, while current-session frame identity, transport liveness, and local decoder health remain required before monitor input is enabled.
- A preview-subscription acknowledgment now forms a decoder boundary: queued stale video is discarded/reset and the client explicitly requests a fresh display refresh/keyframe. Async dashboard decoding is tagged with the preview acknowledgment captured before decode and is discarded if that acknowledgment changes while decoding. For peers that advertise stream liveness, a heartbeat older than the first current decoded frame is also discarded so input cannot unlock across the capture boundary until a post-frame heartbeat arrives.
- Reconnect/target changes invalidate the monitor input epoch so queued input cannot execute in a later session. Backgrounding, view focus loss, view-only, decoder/stream/transport failure, and orientation changes release locally tracked mouse buttons and keys instead of replaying them later.
- Windows host input tracks per-connection held keys, mouse buttons, pointer-scale state, and modifiers. A 6-second transport-liveness watchdog releases held state if client releases cannot arrive; permission loss and connection teardown also release it.
- Android guest input tracks active touches and keys on the phone and cancels them on background/focus/permission/geometry interruption and every return/switch path. The host guest worker already releases held touches/keys on disconnect and now accepts an idempotent `ReleaseAll` liveness command so a transport stall can release guest input without tearing down the guest stream.
- The 6-second transport/held-input threshold and 4-second stream-heartbeat threshold are empirical engineering defaults around the normal 1-second heartbeat cadence. They are not treated as user-approved product timings and remain subject to runtime tuning.

Fresh focused evidence on 2026-10-05:

- `C:\flutter-3.24.5\bin\flutter.bat test test\target_dashboard_test.dart test\emulator_model_test.dart test\monitor_control_view_test.dart test\remote_conformance\input_liveness_test.dart` → 72 passed, 0 failed after the final WP2 liveness review. This includes `static_desktop_heartbeat_stays_usable`, `one_frame_then_dead_stream_blocks_input`, `old_peer_does_not_require_stream_heartbeat`, `old_peer_still_requires_known_healthy_decoder`, `first_current_frame_requires_a_follow_up_stream_heartbeat`, `late_frame_cannot_unlock_new_target`, `reconnect_releases_and_never_replays`, `view_only_blocks_all_input_paths`, `overlay_drag_never_remote_clicks`, and `rotation_cancels_all_contacts`.
- `cargo test guest_video --lib` with `VCPKG_ROOT=C:\vcpkg` and `LIBCLANG_PATH=C:\LLVM-15.0.6\bin` → 3 passed, 0 failed.
- `cargo test held_input --lib` with the same environment → 2 passed, 0 failed.
- `cargo test liveness_release --lib` with the same environment → 1 passed, 0 failed; the guest worker releases held input and remains usable afterward.
- `cargo test disconnect_releases_guest_touches_and_held_keys --lib` with the same environment → 1 passed, 0 failed.
- `cargo test inventory_negotiates_operation_capabilities_and_scope --lib` with the same environment → 1 passed, 0 failed and confirms `desktop.stream_liveness.v1` is advertised.
- Rust focused runs continue to report the repository's existing 44 warnings; WP2 does not claim a warning-free build.

Remaining WP2 runtime evidence gap: source/unit/widget checks cannot prove real-device latency, packet-loss behavior, actual decoder recovery, focus/background delivery timing, or that a physically held Ctrl/mouse/touch is released on the real Windows + Galaxy S25 Ultra path during network loss. Those checks remain in the physical/runtime matrix and WP14 release gate.

## WP3 Codex submission, ownership, and approval gate

WP3 now has source/unit/widget coverage for draft preservation, exact-operation reconciliation, bridge-owned task identity, and approval routing. Physical airplane-mode/restart behavior is still a WP14 matched-binary runtime requirement.

- Submitted Codex text remains in the composer until the exact host operation is positively acknowledged. An acknowledgment clears only the submitted snapshot; edits typed while that operation is pending remain in the composer.
- A lost mutation acknowledgment becomes an unknown outcome. The client performs one reconciliation attempt with the same operation ID and permits only an exact-snapshot retry with that same ID; a different instruction is blocked until the uncertain operation is reconciled.
- Consequential Codex mutations use the WP1 session identity/generation and exact target identity. The host keeps a bounded replay cache so an exact duplicate can return its recorded result without creating a second turn, while operation-ID reuse for another action/target is rejected.
- MIRPG task ownership is connection scoped. Persisted Codex Desktop threads are presented as `History` on Android and stay read-only when opened. Only an explicit `Resume` claims the task; subscription and approval reads happen after the exact resume acknowledgment succeeds.
- Pending approvals are bound on first delivery to the owning connection, operation session identity, session generation, task, turn, item, and approval kind. A reconnect/generation change cannot rebind the old approval. Listing and responding both enforce that binding, and successful resolution/turn completion/bridge reset removes it.
- Command approvals expose the bounded command, working directory, and reason where available. File-change approvals expose the bounded grant scope without forwarding raw diff/policy material.
- Unsupported permission approvals remain visible and non-actionable with the exact copy: `This request needs a compatible MIRPG bridge action. Opening Windows Codex does not transfer this approval.` Opening the Windows app is a separate action and does not transfer approval authority.

Fresh focused evidence on 2026-10-05:

- `C:\flutter-3.24.5\bin\flutter.bat test --no-pub test\codex_model_test.dart test\codex_page_test.dart` → 26 passed, 0 failed. This includes history staying read-only until explicit resume, draft preservation, exact submitted-snapshot clearing, lost-ack reconciliation, exact-snapshot unknown-outcome retry, stale approval reconciliation, and the unsupported-approval no-fake-handoff UI.
- `cargo test --lib codex -- --nocapture` with `VCPKG_ROOT=C:\vcpkg` and `LIBCLANG_PATH=C:\vcpkg\downloads\tools\clang\clang-15.0.6\bin` → 60 passed, 0 failed, 4 ignored. The ignored tests require a live local Codex installation/session or foregrounding the Windows Codex app.
- New host tests `approval_wrong_runtime_rejected` and `expired_approval_not_replayed` pass and cover the immutable approval runtime/session-generation binding.
- Existing Codex tests cover exact duplicate operation replay, operation-ID conflict rejection, connection-scoped thread ownership, action/target binding, one-shot approval responses, unsupported permissions visibility, and persisted threads requiring explicit native ownership before control.
- Rust verification continues to emit the repository's existing 44-warning set; WP3 does not claim a warning-free build.

Remaining WP3 runtime evidence gap: the real Windows host + Galaxy S25 Ultra still must prove airplane-mode/lost-ack behavior, process/runtime restart, reconnect generation changes, live resume/send/steer/stop, and approval handling against matched artifacts. Those checks remain in WP14 and are not inferred from source/unit/widget tests.

## WP4 Codex workspace, queue, review, and artifact gate

WP4 now has source/unit/widget coverage for host-approved workspace selection, exact Queue/Steer/Stop targeting, structured bounded review paging, and reconnect-safe queue state. The live disposable-task gate is still pending and is not inferred from these tests.

- New tasks use host-issued opaque workspace IDs. Arbitrary client paths are rejected, inaccessible/deleted roots cannot be started, workspace paging is snapshot-bound, and roots removed from the current host inventory invalidate their old start IDs.
- Queue/Steer/Stop remain bound to the owning remote runtime, current session generation, exact task, and expected active turn. Queue entries carry the exact operation ID; a host `queuedStart` event removes that operation even when it arrives before the original queue acknowledgment.
- A late queue acknowledgment cannot roll a task that already completed back to `working`. Resume negotiates `codex.queue.reconcile.v1` and reconciles against the host's authoritative pending operation IDs. If the phone no longer has the original queue text after reconnect, the pending operation remains visible as `Queued instruction on PC · details unavailable` instead of disappearing or inventing text.
- Review negotiates `codex.review.v1`. Host-issued change/artifact IDs are task scoped; arbitrary mobile paths are never accepted. Public list pages are capped at 100 entries, one request processes at most 1000 raw file changes, diff pages are capped at 32 KiB with a 4 MiB accumulated client limit, and artifact previews are capped at 32 KiB pages with a 1 MiB accumulated client limit.
- Review continuation cursors are opaque, task/root/view scoped, bounded to 128 entries, item-fingerprint checked, and retryable after a lost page response. The active cursor is refreshed in the LRU before allocating its continuation so response retry still works at full cursor capacity.
- Host review records use bounded FIFO eviction instead of clearing the whole registry. Cached diff content is capped, unavailable artifact IDs cannot become readable later, and artifact reads remain bound to the file snapshot recorded when the artifact ID was issued.
- Windows artifact reads reject symlink/reparse components, canonicalize the resolved file under the approved workspace, and recheck the opened handle path before reading. Binary/invalid UTF-8 and oversized content return safe fallback states instead of being rendered as text.
- Mobile review memory is bounded across long sessions: at most four stored task-diff previews and eight stored artifact previews are retained at once, including partially loaded previews; the change/artifact lists are separately capped per task.

Fresh focused evidence on 2026-10-05 at HEAD `59221185a99cf555fcee552114fb5589c66a15b8` with the existing dirty feature tree preserved:

- `C:\flutter-3.24.5\bin\flutter.bat test --no-pub test\codex_model_test.dart test\codex_page_test.dart` → 54 passed, 0 failed. New coverage includes queue-start-before-ack, late queue-ack state regression, authoritative resume reconciliation, host-only queued-operation visibility, bounded diff/artifact preview caches, malformed/stale review responses, UTF-8 byte offsets, and retryable review requests.
- `cargo test --lib codex -- --nocapture` with `VCPKG_ROOT=C:\vcpkg` and `LIBCLANG_PATH=C:\vcpkg\downloads\tools\clang\clang-15.0.6\bin` → 93 passed, 0 failed, 4 ignored. The ignored tests require a live local Codex installation/authenticated session or foregrounding the Windows Codex app.
- TDD evidence for retryable review paging: `review_cursor_can_be_replayed_after_response_loss` first failed with `Codex review cursor is invalid or stale`, then passed after consumed cursors became replayable. `active_review_cursor_survives_capacity_pressure_for_response_retry` first failed at the 128-cursor boundary, then passed after the active cursor was refreshed before continuation allocation.
- TDD evidence for client state safety: `diff preview cache evicts the oldest completed preview`, `artifact preview cache evicts the oldest completed preview`, `late queue ack cannot roll a completed queued turn back to working`, and `resume keeps host-only queued operations visible after reconnect` each failed against the prior behavior and passed after the bounded/reconciled implementation.
- `flutter analyze --no-pub lib\models\codex_model.dart test\codex_model_test.dart` → no issues found. A separate analyzer pass over `codex_page.dart`, `codex_review_panel.dart`, and `codex_page_test.dart` also reported no issues.
- `git diff --check` → no whitespace errors; only the repository's existing LF/CRLF conversion warnings were emitted.
- Rust verification continues to emit the repository's existing 44-warning set; WP4 does not claim a warning-free build.

Remaining WP4 evidence gaps and limits:

- The plan's real disposable-task gate still needs a live tested-host run covering create, follow, steer, queue, stop, and structured review while native approval boundaries remain intact.
- The command runner rejected the attempted temporary Windows symlink creation probe before execution, so no physical reparse-point fixture was created in this pass. The Windows source path contains the reparse checks, but runtime filesystem proof remains pending.
- Artifact enumeration currently represents file-change-backed outputs. It does not yet constitute comprehensive enumeration of every possible Codex-generated media/output artifact, so no such claim is made.

## WP5 BlueStacks text, rotation recovery, and startup-state gate

WP5 now has source/unit/widget coverage for composed Android text, guest-geometry recovery, and evidence-backed startup phases. The physical multi-guest/phone gate remains pending and is not inferred from these tests.

- Guest text is a separate typed request from hardware key events. Current hosts advertise `guest.text.v1`; an older peer without that negotiated capability leaves the phone text action unavailable. The host validates control permission, selected guest-session identity, non-empty UTF-8, and a 4096-byte payload bound. The pinned scrcpy v4 wire path uses `TYPE_SET_CLIPBOARD` with `paste=true`, which updates the Android clipboard and requests paste rather than using `TYPE_INJECT_TEXT`; this preserves the composed UTF-8 payload without synthesizing Enter. The phone's Boolean send result is transport-submission evidence only, not an acknowledgment that the target Android application consumed the text. Physical CJK/emoji delivery is still part of the real-device gate below.
- The phone presents an explicit text composer and sends its composed text only when the user taps Send. Only one send can be in flight; the submitted snapshot is separated from newer typing, a transport failure restores that snapshot, and a target/session/focus change invalidates stale completion work. Hardware-key forwarding is suppressed while composition is open. Pending composition is discarded on target/view changes, permission loss, app background, or view-focus loss so text cannot leak into a different guest.
- A guest display-size change no longer terminates the input worker. The host assigns a new geometry generation, immediately releases all active contacts using their original geometry even if no further phone input arrives, rejects stale geometry and stale move/up events, and blocks new guest input until the new stream has produced a current decodable frame. The Flutter side retains each pointer's original frame geometry for cancellation. In addition, selected-guest control now requires a frame that the phone itself decoded for the current guest session and geometry. Each decoded phone frame refreshes a four-second freshness lease; expiry pauses touch, navigation, key-down, and composed-text submission while still permitting contact-cancel and key-up releases. Geometry/session changes invalidate the lease immediately. The host's separate 10-second watchdog remains scoped to explicit new-stream/rotation recovery.
- Startup evidence is now explicit. A stopped guest emits `boot_requested` before provider start, `starting_android` while Android/ADB readiness is being established, `waiting_screen` after Android is boot-complete and again while a rotated stream is waiting for a current frame, and `stream_ready` only after the H.264 parser has accepted a current frame for the reported geometry. A process or dimension record by itself is therefore not reported as a ready remote screen.
- Existing Boot/Resume/Launch-game separation remains intact. A stopped card boots only from an explicit Boot action, while Launch game is a separate action. Selecting/resuming a running instance keeps `launch_default_app=false` unless the explicit game action was chosen.
- Existing resource bounds remain in place: dashboard subscriptions are limited to four combined guest/display previews, guest preview capture remains the reduced 360-pixel/6-fps budget, selected capture retains its separate 1280-pixel/30-fps budget, and the prior non-blocking/reference-frame guest decoder regressions continue to pass.

Fresh focused evidence on 2026-10-05 with the existing dirty feature tree preserved:

- `C:\flutter-3.24.5\bin\flutter.bat test --no-pub test\emulator_model_test.dart test\emulator_input_test.dart test\target_dashboard_test.dart` → focused emulator/input/dashboard suite passed after the final WP5 corrections. Coverage includes capability-gated composed UTF-8 submission, no implicit key/Enter action, transport-failure reporting, original-geometry pointer cancellation, composition cancellation on target/session switch, explicit startup phases, explicit stopped-instance Boot, and separate Launch game behavior.
- `C:\flutter-3.24.5\bin\flutter.bat test --no-pub test\remote_conformance\clipboard_transfer_test.dart test\emulator_model_test.dart test\remote_conformance\paste_safety_test.dart test\terminal_model_lifecycle_test.dart test\monitor_control_view_test.dart test\target_dashboard_test.dart` → 95 passed, 0 failed. The WP5 coverage in this combined regression pass includes phone-decoded-frame freshness before input, freshness timeout, release/cancel while stale, and immediate freshness invalidation after guest geometry changes.
- `cargo test --lib emulator -- --nocapture` with `VCPKG_ROOT=C:\vcpkg` and `LIBCLANG_PATH=C:\vcpkg\downloads\tools\clang\clang-15.0.6\bin` → 109 passed, 0 failed, 8 ignored. New coverage includes the exact scrcpy v4 Unicode clipboard-paste packet, multitouch release across rotation, stale-pointer rejection while the same input worker survives, and startup-phase transport. Existing guest-video queue/reference-frame regressions and preview-bound authorization tests also pass. The ignored tests require local BlueStacks/LDPlayer instances or other explicit runtime actions.
- `flutter analyze --no-pub lib\models\emulator_model.dart lib\mobile\pages\emulator_page.dart test\emulator_model_test.dart test\emulator_input_test.dart` → no issues found.
- `git diff --check` → no whitespace errors; only the repository's existing LF/CRLF conversion warnings were emitted.
- Rust verification continues to emit the repository's existing 44-warning set; WP5 does not claim a warning-free build.

Remaining WP5 runtime evidence gap:

- The plan gate still requires matched Windows/Android artifacts on the real host and phone: two running guests plus one stopped guest, repeated portrait/landscape changes including active multitouch, rapid target switching, boot failures, lost guest streams, and Android Back/Home/Recents.
- The real phone IME still must prove keyboard presentation, accents/CJK/emoji composition through the clipboard-paste path, explicit Send exactly once, and composition cancellation during target/view switches. Source/widget tests do not constitute physical IME proof. The new four-second phone-decoded-frame lease provides steady-state stale-input protection at source/unit scope, but the actual BlueStacks freeze/jump-ahead failure still requires matched-phone runtime proof; the host's 10-second watchdog remains scoped to explicit new-stream/rotation recovery.
- No claim is made that audio, stop/restart, or other unverified provider features are available; those remain gated by actual provider support and later runtime evidence.

## WP6 Clipboard and Shell deliberate-action gate

WP6 is partially verified at source/unit/widget scope. The deliberate clipboard and Shell safety paths are implemented and tested, but write-operation reconciliation, Windows service-session clipboard runtime proof, and real phone/Shell lifecycle evidence remain open.

- Current hosts advertise `manual_clipboard` only on authenticated Remote sessions. The phone uses an explicit Phone → PC or PC → Phone direction, exact-text local preview, and an explicit copy action; there is no paste, key injection, command execution, or automatic retry on this path. Legacy hosts that do not advertise the feature retain the existing legacy clipboard behavior instead of being silently treated as compatible.
- Clipboard permission is independent from local view-only state. The host's existing clipboard permission and `disable-clipboard` session option remain authoritative. The existing one-way clipboard-redirection policy is also honored: when the Windows host is configured for input-only clipboard redirection, PC → Phone is rejected explicitly with `clipboard_direction_denied`; otherwise both manual directions are implemented.
- Manual clipboard text is bounded to 1 MiB of UTF-8 on the phone, native request handler, bounded decompression path, and Windows service clipboard-write IPC. Oversized data is rejected before a write or preview is exposed.
- Phone requests carry a UUID request ID, direction and target identity. The phone binds ephemeral state to the current target plus peer-info/reconnect generation; reconnect, target change, permission/capability loss, dismissal, reset, or close clears that state. An eight-second request timeout ends the pending state without retry. Asynchronous phone clipboard reads and local phone writes revalidate their original scope after the platform clipboard call completes.
- Phone → PC writes keep their staged text after a transport failure or timeout so the user can inspect it. A late response from another target/generation is ignored. The implementation does not yet provide an operation-ID deduplication/reconciliation contract proving whether a Windows clipboard write happened when its response is lost; that remains a WP6 completion gap.
- Shell paste is staged locally for review, including explicit xterm paste requests that are single-line, multiline, or contain control characters. The review sheet exposes exact text and `Insert text`; inserting creates a local editable draft. `Run / Enter` is a separate action and never buffers for a later reconnect.
- Shell drafts bind to the authenticated peer, peer-info generation, and reconnect generation. A target change, reconnect/authentication change, app background, or terminal disposal invalidates pending clipboard reads/review and discards a visible execution draft rather than allowing it to cross scopes. Direct mobile `pasteText` calls route back through the review hook rather than bypassing it.
- `runReviewedText` sends the reviewed prepared payload plus carriage return in one transport submission. A returned `submitted` state means only that the transport call completed while the same authenticated scope remained current; it is not PTY execution acknowledgment. An uncertain result retains the draft and disables another Run until the user explicitly states that Shell output was checked. No automatic retry occurs.

Fresh focused evidence on 2026-10-05 with the existing dirty feature tree preserved:

- `C:\flutter-3.24.5\bin\flutter.bat test --no-pub test\remote_conformance\clipboard_transfer_test.dart test\emulator_model_test.dart test\remote_conformance\paste_safety_test.dart test\terminal_model_lifecycle_test.dart test\monitor_control_view_test.dart test\target_dashboard_test.dart` → 95 passed, 0 failed. Clipboard coverage includes permission denial, target/reconnect invalidation, timeout without retry, pending-request replacement prevention, 1 MiB client bound, Unicode exact preview, response-time permission revalidation and copy-to-phone scope revalidation. Shell coverage includes known-paste interception, visible controls, review-only insert behavior, lifecycle no-buffer guarantees and large-text/landscape review layout.
- `cargo test --lib manual_clipboard -- --nocapture` with `VCPKG_ROOT=C:\vcpkg` and `LIBCLANG_PATH=C:\vcpkg\downloads\tools\clang\clang-15.0.6\bin` → 6 passed, 0 failed. Coverage includes exact host reads without writes, permission denial before clipboard access, view-only independence, oversized write rejection, Unicode/compressed decode preservation, and bounded compressed decode rejection.
- `cargo check --lib --features flutter` with the same Rust environment → passed. The repository emitted its existing 25 warnings for this feature check.
- Focused `flutter analyze --no-pub` over the touched clipboard/emulator/terminal/model pages and tests reported no errors or warnings; it exited nonzero for 11 informational findings already present in the analyzed files (deprecated `WillPopScope`/`window`, one `prefer_final_fields`, and one `hash_and_equals`).

Remaining WP6 evidence and implementation gaps:

- Phone → PC clipboard write has request correlation but no durable operation ID/deduplication/reconciliation record. A lost acknowledgment can therefore be reported only as uncertain/timeout; the implementation cannot yet safely prove a retry would not duplicate a changed clipboard write.
- The Windows root-service `_cm` clipboard path and interactive-session clipboard read/write need matched-runtime proof. Unit tests exercise the handler contract and codec bounds, not the physical Windows clipboard across the service/user boundary.
- The native clipboard handler uses a bounded blocking worker but the connection message handler awaits its completion; the real host still needs latency/reconnect testing to prove clipboard access cannot create an unacceptable control stall.
- Shell `submitted` has no PTY execution acknowledgment or dedup contract. Actual PowerShell lifecycle, lost-transport outcome, Samsung/Gboard IME, background/reconnect behavior, and very small landscape/IME layout remain part of the matched phone/host gate.

## WP7 File transfer pause/resume and conflict-safety gate

WP7 is partial. Focused source/unit/widget coverage passes for the implemented paths, while known implementation gaps and the matched Windows/phone runtime gate remain open. The current implementation binds resumable partials to a persisted transfer owner, strong source identity, exact destination/file identity, acknowledged pause/cancel attempts, immutable conflict generations, and no-replace final publication. Physical interruption, performance, old-peer compatibility, and cross-version proof remain part of WP14.

- Mobile transfers expose Pause only when the peer advertises file-pause support and file permission is available. The UI enters `pauseRequested` immediately, becomes `paused` only after the host pause acknowledgment, and treats an unknown pause outcome as `interrupted` instead of claiming success.
- Resume from `paused` or `interrupted` enters `resumeRequested`; the row returns to `inProgress` only after fresh transfer progress arrives. A failed resume returns to `interrupted` and preserves the job for review/retry.
- Persisted transfers keep a stable UUID ownership token even when reconnect creates a fresh local job ID. Version-3 sidecars bind that token to remote source, final destination, file number, source size/mtime/SHA-256, and the native identity of the created `.download` file. Fresh partial and sidecar creation uses exclusive create semantics; sidecar durability errors propagate instead of being ignored.
- Strong SHA-256 source identity is carried in the transfer digest. Source hashing runs on a background worker so digest preparation does not hold the connection/file-transfer loop. Resume requires the matching strong hash and revalidates the reopened source handle against the identity/size/mtime snapshot captured during digest preparation, so a same-size replacement at the path is rejected before resuming.
- Fresh writes hash bytes incrementally as they are written, then finalization also verifies the owned partial from disk before publication. This retains the streamed integrity check without trusting it as proof that another process did not alter the partial after a write. Resumed writes likewise perform a complete final SHA-256 verification.
- Cancel cleanup removes only a partial whose persisted ownership record and native file identity still match the exact transfer. Swapped, foreign, unmarked, or otherwise unprovable artifacts are preserved for review.
- Pause and cancel attempts carry request IDs. Pause acknowledges only after the destination stream has been flushed and closed. Cancel has an explicit terminal acknowledgment; accepted cancels keep a bounded late-packet tombstone so delayed blocks/done/errors cannot resurrect a cancelled transfer, while a rejected cancel releases that suppression and permits reconciliation.
- Conflict Replace and Keep both are bound to a UUID conflict token for the exact prompt generation plus a destination identity/size/mtime snapshot. Stale tokens and changed destinations are rejected. Flutter also tracks the active token across asynchronous prompts so a late decision cannot authorize a newer conflict.
- Keep both moves the existing destination to the first free sibling with no-replace semantics. Replace moves the confirmed existing destination aside, rechecks the moved file's identity, publishes the owned partial with no-replace semantics, and restores the prior destination if publication fails. Finalization refuses a destination that appeared or changed after the decision.
- The conflict sheet shows transfer direction and the resolved destination path. Batch-wide remembered Replace is not used by the mobile conflict path; a destructive overwrite decision is not silently replayed after reconnect.

Fresh focused evidence on 2026-10-06 with the existing dirty feature tree preserved:

- `C:\flutter-3.24.5\bin\flutter.bat test test\remote_conformance\file_transfer_test.dart test\file_model_test.dart` → 25 passed, 0 failed. Coverage includes pause/cancel acknowledgment and unknown-outcome states, terminal-state late-progress suppression, reconnect without duplicate/auto-resume, resume pending until progress, and file-model request/session regressions.
- `C:\flutter-3.24.5\bin\flutter.bat analyze lib\models\file_model.dart` → no issues.
- `cargo test -p base fs::tests --no-fail-fast` → 44 passed, 0 failed, 1 ignored because the symlink escape test requires Windows symlink privilege. The fresh pass includes final on-disk SHA-256 verification and the post-write partial-mutation regression.
- `cargo test --lib ui_cm_interface::tests --no-fail-fast` → 6 passed, 0 failed, including terminal writer cleanup after source and finalization errors.
- `cargo test --lib --features flutter client::io_loop::tests --no-fail-fast` → 5 passed, 0 failed, including the pending-cancel tombstone-capacity regression.
- `cargo check --lib --features flutter` → pass. Existing project warnings remain, with no WP7 compile error.

Remaining WP7 runtime/compatibility limitations:

- New peers echo conflict tokens. The empty-token path remains accepted for legacy compatibility, so old peers cannot provide the same exact prompt-generation guarantee and must remain capability-limited in release testing.
- Fresh and resumed large files perform a complete partial SHA-256 verification at finalization. That preserves on-disk byte identity before publish but can add terminal latency; matched large-file runtime testing must measure this before WP14 release sign-off.
- The source digest worker is backgrounded, but aborting a Tokio blocking task cannot preempt a hash that has already started. Dropped jobs detach that bounded worker; runtime stress testing should confirm this does not create unacceptable I/O contention.
- Path-component symlink checks remain best-effort/path based. Native file identities protect the owned partial and conflict destination at the critical mutation points, but a fully handle-relative/no-follow cross-platform path walk is outside this WP7 change.
- The conflict bottom sheet still needs WP12 small-screen/font-scale visual QA even though the asynchronous conflict generation is now token-bound.
- The real Windows host and phone still need matched-artifact tests for large upload/download pause, disconnect while paused/resuming, source replacement between reconnect and Resume, conflict changes between prompt and action, cancellation cleanup, Unicode paths, permission revocation, and older-host behavior.
- Runtime evidence must confirm resumed offsets and resulting files are correct on disk and that reconnect does not create a second transfer or silently overwrite a changed destination.

## WP8 System freshness and scoped process-action gate

WP8 now has source/unit/widget coverage for conservative measurement freshness, unavailable metrics, a consistent whole-machine CPU denominator, and PID-reuse-safe End task identity. Physical Task Manager comparison and successful/denied Windows termination behavior remain part of the matched-artifact release gate.

- Host status schema 3 includes `sampled_at_ms`, `source=windows_sysinfo`, and a native Windows process creation-time token where available. The phone records monotonic request-start and receipt times and uses the request start as the conservative freshness origin. A delayed response therefore cannot become freshly authorized merely because it just arrived. The PC wall clock is metadata only and cannot extend freshness.
- The System page labels data `Live` only while the authenticated inventory/session is current and the conservative local monotonic age is inside the 15-second window. Retained values become `Stale`, show `Last updated`, and process/recovery controls are disabled. Status requests themselves time out at the freshness bound so a stuck request does not block later refresh forever.
- Missing CPU, memory, or uptime measurements parse as unavailable instead of zero. The UI renders `Unavailable` rather than inventing a 0%/0 B measurement.
- Host-wide CPU remains a 0-100 whole-PC value. Per-process CPU from sysinfo is normalized by the logical CPU count before transport, and the phone labels it `% of whole PC`; schema-1 values are identified as legacy scale instead of being silently mixed with the new denominator.
- Each process snapshot includes sysinfo `start_time_secs` plus the Windows `GetProcessTimes` creation timestamp. End task is exposed only when the peer advertises `host.process_identity.v2` and a fresh schema-3 process carries both values. The operation target binds PID + the native creation token.
- The Windows host re-checks sysinfo start time for continuity, opens the exact PID with query/terminate rights, verifies the creation timestamp on that handle, and terminates that same handle. A recycled PID therefore fails closed instead of redirecting the action. There is no broad name match or process-tree fallback.
- The confirmation dialog continues to identify the exact process/PID and warns that unsaved work may be lost. A host denial resolves the operation as failed, displays the error, and retains the process in the last observed snapshot rather than implying it disappeared.
- Older peers can still show read-only measurements, but the phone does not expose End task unless the strong process-identity capability and schema-3 creation token are present.

Fresh focused evidence on 2026-10-06 with the existing dirty feature tree preserved:

- `C:\flutter-3.24.5\bin\flutter.bat test --no-pub test\remote_conformance\system_freshness_test.dart test\remote_conformance\host_capability_ui_test.dart test\emulator_model_test.dart` → 27 passed, 0 failed. Named WP8 regressions include `stale_sample_loses_live_label`, `clock_skew_does_not_make_future_freshness`, `slow_status_response_is_stale_on_arrival`, `unsupported_metric_not_zero`, `queued host mutation revalidates scope before transport dispatch`, and `end_task_denial_keeps_process_visible`.
- `cargo test --lib pid_reuse_rejected -- --nocapture` → 1 passed, 0 failed.
- `cargo test --lib host_mutations_are_bound_to_connection_scope_generation_and_target -- --nocapture` → 1 passed, 0 failed.
- `cargo test --lib host_management_is_bounded_and_control_gated -- --nocapture` → 1 passed, 0 failed.
- `cargo test --lib emulator -- --nocapture` → 110 passed, 0 failed, 8 ignored. Ignored tests require local emulator lifecycle/capture actions.
- `C:\flutter-3.24.5\bin\flutter.bat analyze --no-pub` over the WP8 page/model/tests → no issues found.
- `git diff --check` over the WP8 surface → no whitespace errors; only the repository's existing LF/CRLF conversion warnings were emitted.

Remaining WP8 runtime evidence gap:

- A matched Windows host and phone still need direct comparison against Task Manager for CPU/memory/process identity plus stale-network behavior while the System tab is open.
- Runtime tests must cover a process exiting/restarting between snapshot and confirmation, Windows access denial, a deliberately stale snapshot, host clock skew, and a successful End task proving the acknowledged refreshed snapshot removes only the expected process instance.

## WP9 authenticated Windows picker and focus gate

WP9 now has source/unit/widget coverage for a bounded authenticated Windows picker and exact-target focus flow. The physical Windows host + Galaxy S25 Ultra interaction gate remains open and is not inferred from these tests.

- The Windows host advertises `host.windows.list.v1` and `host.window_focus.v1`. Listing is read-only and remains available to an authenticated view-only connection; focusing still requires host control permission plus the WP1 operation identity/ack capabilities.
- Enumeration is bounded to 100 eligible top-level windows. It filters the RustDesk process and known shell/system surfaces, requires the active interactive process session, caps title/application metadata, and returns only opaque `win-*` IDs. HWND, PID, thread ID, process creation time, and class name stay host-side.
- Window registries are scoped by the server's authenticated connection operation identity/generation and bounded to 32 recent scopes. One remote connection cannot invalidate or reuse another connection's opaque picker state merely by listing windows.
- Each list produces a new `desktop_generation` and captures the current monitor-layout fingerprint. Focus rejects an expired generation or changed monitor layout. A candidate must still be the same HWND/PID/thread/process-creation/class/title identity in the same interactive session; conservative title changes require a refresh rather than risking handle reuse.
- Minimized windows use `GetWindowPlacement.rcNormalPosition` for picker bounds. On focus, the host restores the window, requests foreground activation without injection/elevation/`AttachThreadInput`, verifies `GetForegroundWindow`, then re-reads the actual post-restore bounds and monitor. Windows foreground-policy denial is returned honestly as `focus_denied`.
- The phone invalidates the previous actionable list as soon as refresh starts and clears it on timeout/error. A focus acknowledgment is accepted only if the observed window plus returned desktop generation reconstruct the exact operation target. Malformed/mismatched success replies resolve to no navigation and an explicit error.
- After a valid focus acknowledgment, the dashboard switches to the observed monitor through the same `_open` path used by ordinary monitor navigation, including input release, preview subscription/liveness reset, desktop selection, presentation/orientation handling, and focused-window local reveal. The picker never sends pointer input merely to reveal the window rectangle.

Fresh focused evidence on 2026-10-06 with the existing dirty feature tree preserved:

- `C:\flutter-3.24.5\bin\flutter.bat test --no-pub test\remote_conformance\window_picker_test.dart test\monitor_control_view_test.dart test\target_dashboard_test.dart test\emulator_model_test.dart test\quality_monitor_transport_test.dart` → 83 passed, 0 failed. Window-specific regressions include opaque scope-bound list/focus, unsupported-peer no-send, mismatched focus-ack rejection, stale-list invalidation, and the Windows toolbar entry.
- `C:\flutter-3.24.5\bin\flutter.bat analyze --no-pub` over the WP9 dashboard/picker/monitor/model/test surface → no issues found.
- `cargo test --lib server::emulator::` with `VCPKG_ROOT=C:\vcpkg` and `LIBCLANG_PATH=C:\vcpkg\downloads\tools\clang\clang-15.0.6\bin` → 108 passed, 0 failed, 8 ignored. The ignored tests require local emulator lifecycle/capture actions; this run includes four window-picker identity/layout/bounds helpers plus host authorization/replay coverage.
- `cargo test --lib client::emulator_protocol::tests` with the same environment → 6 passed, 0 failed, including typed view-only `windows_list` and control-gated exact-target `window_focus` parsing.
- `git diff --check` over the WP9 source/protocol/UI/test surface → no whitespace errors; only the repository's existing LF/CRLF conversion warnings were emitted.
- Rust verification continues to emit the repository's existing 44-warning set; WP9 does not claim a warning-free build.

Remaining WP9 runtime/visual evidence gap:

- A matched Windows host and Galaxy S25 Ultra still need to prove real enumeration and focus across both physical monitors, including minimized/restore, a window moved between monitors, a window closed between list and focus, a title-changing app requiring refresh, Windows foreground-policy denial, reconnect/generation change, and a view-only session that can inspect but cannot focus.
- WP12 still owns final phone layout/accessibility evidence: picker empty/loading/error/unsupported states, long titles/application names, small-screen/font-scale behavior, and screenshots showing the focused window reveal on the correct monitor.
- Focus intentionally fails closed when the serving process is not on the active interactive desktop (including session 0/no interactive desktop). No cross-session injection or elevation fallback is implemented.

## WP10 Phone Workspace reversible virtual-display gate

WP10 is implemented at source/unit/model scope and remains runtime-pending. The host advertises `host.phone_workspace.v1`, the phone exposes a Phone Workspace sheet from System, and begin/end operations use the existing WP1 operation identity/acknowledgment envelope. Driver installation is never implicit.

- Support inspection reports platform/driver/install state, predefined portrait and landscape profiles, active ownership state, and an explicit unavailable reason. Amyuni is unavailable for a new Phone Workspace when an unowned Amyuni virtual display already exists.
- Begin/end are serialized host-side so two authenticated requests cannot create or tear down the owned display concurrently. A corrupt persisted ownership record fails closed instead of being treated as absent.
- The host records an owned session before post-create validation, including backend, native display identity/index, profile, expected virtual-display set, process identity, and a fresh physical-display snapshot. Failed validation attempts cleanup; if cleanup itself fails, the ownership record is retained for recovery rather than pretending the display is gone.
- RustDesk IDD creation now propagates requested-mode failures instead of reporting success after a failed mode update. Amyuni creation is limited to the conservative zero-existing-display case and uses a single in-process owned-display token.
- Cleanup requires both the persisted session and current native in-process ownership proof. After a host-process restart, matching display names alone are treated as ambiguous; the host refuses automatic removal or duplicate creation rather than risking a foreign display. Amyuni owned cleanup uses the direct driver operation and verifies disappearance instead of relying on the broader force-one helper.
- Physical-display preservation uses a fresh display enumeration before and after activation instead of comparing two copies of the cached synchronized display list.
- The phone blocks overlapping refresh/mutation requests. A timed-out or transport-uncertain begin/end requires a successful support refresh before another mutation. Profile equality is value-based so a refreshed profile list does not silently clear the selected radio option.

Fresh focused evidence on 2026-10-06 with the existing dirty feature tree preserved:

- `cargo test --lib --features flutter server::emulator::phone_workspace::tests --no-fail-fast` with `VCPKG_ROOT=C:\vcpkg` and `LIBCLANG_PATH=C:\vcpkg\downloads\tools\clang\clang-15.0.6\bin` → 6 passed, 0 failed. These are ownership/profile/state helpers; they do not substitute for physical create/end/crash testing.
- `cargo test --lib --features flutter client::emulator_protocol::tests --no-fail-fast` with the same environment → 7 passed, 0 failed, including typed read-only support plus operation-bound begin/end requests.
- `C:\flutter-3.24.5\bin\flutter.bat analyze lib\models\host_management_model.dart lib\models\emulator_model.dart lib\mobile\widgets\phone_workspace_sheet.dart test\emulator_model_test.dart` → no issues found.
- `C:\flutter-3.24.5\bin\flutter.bat test test\emulator_model_test.dart` → 26 passed, 0 failed. Coverage includes support negotiation, exact begin/end identities, profile value equality, and suppression of support refresh while activation is pending.
- `git diff --check` over the focused WP10 files → no whitespace errors; only the repository's existing LF/CRLF conversion warnings were emitted.

Remaining WP10 runtime/visual evidence gap:

- A matched Windows host and Galaxy S25 Ultra must still prove real create/use/end for both provided orientations, verify the requested resolution on the created display, and physically confirm existing monitors retain resolution, rotation, scaling, and arrangement.
- Crash/restart behavior intentionally fails closed when native ownership cannot be re-proven. Runtime testing must confirm this presents a recoverable ambiguous state without duplicate creation or foreign-display removal; automatic crash cleanup is not claimed.
- Disconnect lifetime policy is not yet host-owned cleanup. The active display remains explicitly managed until End workspace or a separately verified recovery path is used.
- The current Phone Workspace UI is a System-sheet workflow. Fullscreen monitor-toolbar integration and final small-screen/accessibility/reference-image conformance remain WP12 work.

## WP11 Separate privacy and host-control state gate

WP11 is partial at source/unit/widget scope. The phone now presents screen privacy, local keyboard/mouse blocking, one-time Windows session lock, and lock-on-disconnect as separate controls instead of one ambiguous privacy toggle. The physical host gate remains open.

- Windows `BlockInput` now sends `BlkOnSucceeded` / `BlkOffSucceeded` after a successful host call. The Flutter toolbar no longer flips local state optimistically; it waits for the host event. The dedicated input worker attempts to release an owned block before exiting when its command channel disconnects.
- Privacy and lock-on-disconnect are session-scoped for the authenticated connection. Saved peer preferences are not automatically sent after reconnect, persisted values are not treated as observed runtime state, and a new connection round explicitly resets the sensitive session flags before reconnecting.
- The connected-PC session menu exposes `Privacy & host controls`. The sheet shows bounded pending/unknown states for screen privacy and local input. An unknown privacy result offers only `Restore screen` before another enable attempt; an unknown input result offers only `Release input` while the current permission still permits it. One-time Windows lock and lock-on-disconnect are explicitly labeled as request-only because this protocol does not yet return an observed lock acknowledgment.
- Current Windows privacy implementations are not represented as an independent input state: topmost-window privacy and virtual-display privacy can also suppress local input. The sheet states that limitation and does not claim that privacy mode hides the session from another remote viewer.
- No privacy/input/Windows-lock action is triggered by opening the sheet. All mutations remain explicit user actions and require the current remote-control permission.

Fresh focused evidence on 2026-10-06 with the existing dirty feature tree preserved:

- `cargo test --quiet --lib --features flutter server::connection::test --no-fail-fast` → 19 passed, 0 failed.
- `cargo test --quiet --lib --features flutter sensitive_session_option_tests --no-fail-fast` → 3 passed, 0 failed, including explicit clearing of session-only privacy/lock state for a new connection round.
- `C:\flutter-3.24.5\bin\flutter.bat test test\target_dashboard_test.dart` → 15 passed, 0 failed, including the connected-PC privacy-menu entry.
- `C:\flutter-3.24.5\bin\flutter.bat analyze --no-pub lib\mobile\widgets\privacy_controls_sheet.dart lib\mobile\pages\target_dashboard_page.dart` → no issues found.
- `cargo check --quiet --lib --features flutter` passed after the input-ack and no-replay changes; existing repository warnings remain.

Remaining WP11 runtime/protocol evidence gap:

- A matched Windows host and Galaxy S25 Ultra must physically verify screen privacy, local input block/release, recovery after abrupt transport loss, and that releasing privacy restores the expected desktop state.
- Windows session lock and lock-on-disconnect still lack an observed acknowledgment/query contract. The UI intentionally reports these as requested/unverified instead of claiming success.
- Physical blanking is not yet technically independent from all local-input suppression in the available Windows privacy implementations. A future backend can separate those mechanisms without changing the sheet's four-state information architecture.
- Physical inspection must also confirm that privacy mode does not overstate protection against another remote viewer.

## WP12 Visual system and phone accessibility gate

WP12 is partial at source/widget/accessibility scope. The supplied visual kit is now represented by a shared graphite/mint theme and the connected workspace is moving toward the reference hierarchy without claiming screenshot parity. Physical-device and complete 40-state visual evidence remain open.

- The shared theme uses the visual-kit typography hierarchy explicitly: 24sp titles, 18sp sections, 16sp body, 14sp secondary/labels, and 12sp metadata. Shared controls retain a 48dp minimum interactive target.
- Overview ordering is Windows monitors first, BlueStacks instances second, followed by an Ongoing work card when Codex is available. That card reads the existing Codex model and uses the visual-kit `Needs you`, `Running`, and `Review` state vocabulary; it does not create a second task state source.
- The Codex summary has a dedicated 200% text layout that reduces secondary detail while preserving the active task state and `Open Codex` action. Desktop-history-only resumable tasks are excluded from the ongoing-work summary.
- Windows floating mouse controls expose Held/Released semantics. Their drag handle has semantic reposition actions, the thumbwheel exposes accessibility increase/decrease actions, and the minimap exposes local viewport movement actions.
- The minimap keeps at least a 48dp interaction target even when the rendered desktop miniature is shorter. Tap/drag and accessibility panning modify only the local viewport; the existing regression confirms they do not emit remote pointer clicks.
- The earlier visual-system pass also moved Windows monitor cards before BlueStacks cards, normalized the connected-workspace theme, and retained the existing 48dp toolbar/control sizing.
- The latest phone-control pass replaces the crowded Windows remote header with the reference-style Back/context/More hierarchy. Clipboard, Windows picker, quality, input controls, display controls, and hide-controls remain available through the session menu, while the persistent footer is limited to Fit, Readable, Pan, Precision, Keyboard, and Targets.
- All six persistent Windows footer controls now use the whole labeled surface as the hit target with a 48dp minimum. Precision adapts at compact widths, provides explicit left/right hold, drag lock, release-all, and close actions, and suppresses the separate floating mouse-button cluster while Precision is active so the same controls are not duplicated.
- Overview is now visibly grouped into Desktop, Android instances, and Ongoing work instead of one undifferentiated target grid. Running Windows cards expose Open, running Android cards expose Resume, stopped Android cards expose Boot, and Launch game remains an independent action when configured. Existing dashboard preview subscriptions remain live and bounded by the four-preview protocol limit.

Fresh focused evidence on 2026-10-06 with the existing dirty feature tree preserved:

- `C:\flutter-3.24.5\bin\cache\dart-sdk\bin\dart.exe analyze lib\mobile\pages\target_dashboard_page.dart lib\mobile\widgets\monitor_control_view.dart lib\mobile\widgets\privacy_controls_sheet.dart test\target_dashboard_test.dart test\monitor_control_view_test.dart` → no issues found.
- `C:\flutter-3.24.5\bin\flutter.bat test --no-pub test\mirpg_remote_theme_test.dart test\monitor_control_view_test.dart test\target_dashboard_test.dart` → 56 passed, 0 failed. This includes the 200% Codex-summary layout and 48dp minimap-target regressions.
- `git diff --check` over the focused WP11/WP12 source/test surface → no whitespace errors; only the repository's existing LF/CRLF conversion warnings were emitted.
- Latest UI/control regression run: `C:\flutter-3.24.5\bin\flutter.bat test --no-pub test/mirpg_remote_theme_test.dart test/monitor_control_view_test.dart test/target_dashboard_test.dart test/remote_conformance/host_capability_ui_test.dart` → 66 passed, 0 failed. New regressions cover 360dp remote chrome/touch targets, Precision duplicate-control suppression, and explicit Open/Resume target actions.
- Latest focused Dart analysis over the Windows controls, grouped Overview, System/Gateway page, and related tests → no issues found.

Remaining WP12 visual/runtime evidence gap:

- The supplied HTML/vector reference still needs browser rendering and side-by-side capture; source token alignment is not claimed as screenshot parity.
- The complete 40-state visual inventory still needs deterministic fixture/golden or equivalent capture coverage. Current focused widgets do not prove every Files, Shell, System, Codex, emulator, reconnect, notification, and Gateway state.
- A matched Galaxy S25 Ultra run still needs screenshots and interaction checks for normal and large text, portrait/landscape remote sessions, IME-open states, long labels, display cutouts/insets, and the final Overview ordering on the physical phone.

## WP13 Opt-in Codex task notifications

WP13 is implemented and verified at source/unit/Android-compile scope. The in-app Codex workflow remains fully usable with task notifications disabled. Enabling alerts is an explicit action in the Codex header and, on Android 13+, is the point at which `POST_NOTIFICATIONS` is checked/requested.

- The notification policy accepts only actionable approval, review-ready turn completion, and failed-turn events. Event IDs are bounded and persisted so reconnect/history refresh does not re-alert old work. An authoritative approval-list refresh seeds existing approvals as history without generating a notification.
- Notification payloads contain the current Windows runtime ID plus Codex thread ID. A tap reconnects through the existing `rustdesk://` flow and opens Codex for that task when it still exists; a stale task falls back to the Codex task list instead of inventing state or failing the connection.
- Lockscreen content is private and task titles are redacted by default. The user can explicitly allow task names in alerts. A generic public notification version is supplied for the private setting.
- Android delivery uses the existing app method channel and permission machinery; no second notification dependency/service was introduced. If permission is revoked or delivery fails, alerts are paused and require explicit re-enable rather than repeatedly prompting.
- The app describes the actual background limitation: these alerts are produced while the connected remote session/app process receives Codex events. Always-on monitoring after Android kills the process is not claimed.

Fresh focused evidence on 2026-10-06 with the existing dirty feature tree preserved:

- `C:\flutter-3.24.5\bin\flutter.bat test --no-pub test\remote_conformance\task_notification_test.dart test\codex_model_test.dart` → 44 passed, 0 failed. This includes all five named WP13 policy tests plus live actionable-approval delivery and reconnect/history suppression at the CodexModel boundary.
- Earlier combined verification after the production integration: `flutter test --no-pub test\remote_conformance\task_notification_test.dart test\codex_model_test.dart test\codex_page_test.dart test\target_dashboard_test.dart` → 76 passed, 0 failed.
- `C:\Programming Projects\MIRPG\rustdesk-emulator-remote\flutter\android\gradlew.bat app:compileDebugKotlin` → BUILD SUCCESSFUL. Existing dependency/deprecation warnings remain; no WP13 Kotlin compile error was present.
- Targeted Dart analysis found no new compile error in the WP13 surface. The broad command still returns the repository's pre-existing warnings/information from large legacy files, so a warning-free global analysis is not claimed.

Remaining WP13 runtime evidence gap:

- A matched Galaxy S25 Ultra must verify first-enable permission grant/denial, later revocation, foreground and background delivery while the process survives, behavior after process recreation, lockscreen redaction, notification-channel settings, and notification taps into both a live task and a task that disappeared before opening.
- Android may suppress or delay background notifications according to process/lifecycle restrictions. No push service or independent background Codex monitor has been added, so the app does not promise alerts after its connected process has been killed.

## WP14 Matched package and physical-runtime gate

WP14 now has a matched local Windows/Android test package. The package-build portion of the gate is satisfied; real-host/phone runtime acceptance remains open and no deployment or release success is inferred from the builds.

- Windows dependencies were restored in `%LOCALAPPDATA%\MIRPG\windows-cache-sdk` from the repository's pinned vcpkg inputs: FFmpeg 7.1.1 with AMF/NVCodec/QSV, AMD AMF 1.4.35, ffnvcodec 12.1.14.0, baseline `9e593bb18ea69cc5095e012465dcd675a822ed0d`, `x64-windows-static`. The final `python .\build.py --portable --flutter --skip-portable-pack --hwcodec --vram` run used Flutter 3.24.5 and completed both Rust release and Windows Flutter release packaging.
- Windows native/package identity: `target/release/librustdesk.dll` and `flutter/build/windows/x64/runner/Release/librustdesk.dll` are both 42,666,496 bytes with SHA-256 `98F3F53E5157FC52BFF1C2131EF1EF85D7FA97A23C75AE939BD65B34EC0E91F5`. The packaged `rustdesk.exe` SHA-256 is `6E0995ED0EFD0DAA86EF83AE93F2047355E6E3E18D1310F60F79158D65884BC7`.
- The first Android native retry exposed a cross-target source defect: cross-platform `src/server/emulator/remote.rs` referenced `guest_protocol::MAX_TEXT_BYTES`, but `guest_protocol` is Windows-only. The shared 4096-byte limit was moved to the cross-platform emulator module and both Windows guest-protocol framing and remote authorization now consume that same constant. The subsequent Android native build completed through `tools/build_android_native_windows.ps1` with NDK 28.2.13676358.
- Android native/package identity: private target output, JNI source, and APK-extracted `lib/arm64-v8a/librustdesk.so` are all 37,771,736 bytes with SHA-256 `497DE3D1282B0E12F7C57F3E8E912566F072A3C15082934AEEF7029BB5C4DB5B`. `llvm-readelf` reports ELF64, AArch64, shared-object type, with no RPATH/RUNPATH entries.
- `C:\flutter-3.24.5\bin\flutter.bat build apk --debug --target-platform android-arm64 --no-pub` produced `flutter/build/app/outputs/flutter-apk/app-debug.apk`, 132,601,802 bytes, SHA-256 `EA8CF6D7DF1CC4A19849653CEA91A052D6F424BAB8DF03FCB7F95E9FE4E4DA02`. APK extraction confirms that exact ARM64 Rust JNI hash is embedded. `apksigner` verifies the normal Android debug signer with v1/v2 signatures; `zipalign -c -v 4` reports `Verification successful`. `aapt` reports package `com.carriez.flutter_hbb`, version `1.5.0`/68, min SDK 22, target SDK 36. This is a debug/test artifact; no release signing material was invented.
- The Windows test folder also contains the unmodified pinned scrcpy v4 helper through `tools/prepare_guest_helper.ps1`; its SHA-256 remains `84924BD564A1EB6089C872C7521F968058977F91F5FF02514A8C74AFF3210F3A` with the upstream Apache-2.0 license/notice.
- Matched artifacts are staged at `C:\Users\gregr\Downloads\MIRPG-Remote-Matched-Test-2026-10-06` and packaged as `C:\Users\gregr\Downloads\MIRPG-Remote-Matched-Test-2026-10-06.zip` (151,546,207 bytes, SHA-256 `67DB54CB8F28C4D6491193F7F0928892DBE234F0996A792DA212AA7603468DA4`) on branch `feature/android-emulator-remote`, HEAD `59221185a99cf555fcee552114fb5589c66a15b8`, with the existing dirty feature tree preserved. No phone install, running RustDesk binary replacement, supervisor restart, git push, or release publication was performed.
- Remaining WP14 gate: run this exact staged Windows/Android pair on the Windows host and Galaxy S25 Ultra and collect the physical behavior/reconnect/latency/input/visual evidence required by WP1-WP13. Artifact matching alone does not close WP14.
- A newer phone-only UI test artifact was built after the WP12 control/Overview pass: `C:\Users\gregr\Downloads\MIRPG-Remote-test2086-controls-ui.apk`, package `com.carriez.flutter_hbb.mirpgtest`, versionCode `4086`, versionName `1.5.0-test2086`, 130,808,408 bytes, SHA-256 `BB6FF631DCADB73D60C3E510747B96D184F448EF8A258515D26314B57B924D53`. The direct Gradle test-package build initially failed transiently in `PackageAndroidArtifact$IncrementalSplitterRunnable`; after inspecting disk/process/output state, a diagnostic `:app:packageDebug -PmirpgTestApk=true --stacktrace` retry completed successfully. This artifact has not yet been installed on the Galaxy because the phone is currently absent from both `adb devices` and `adb mdns services`; only the Box R 4K Plus and Shield TV are visible, and they were intentionally left untouched.

## WP15 Gateway management gate

WP15 is implemented and verified at source/unit/widget scope. Live supervisor deployment and physical phone evidence remain open.

- RustDesk exposes capability-gated Gateway status, setup handoff, IMDb enable/disable and refresh, and restart controls. Status parsing is schema/type strict; malformed or timed-out rechecks invalidate mutation freshness while retaining display-only prior evidence.
- Gateway mutations use operation IDs and conservative unknown-outcome handling. A transport/POST ambiguity stays unknown and is reconciled through status instead of being retried as a fresh consequential action. An accepted failure from an older peer that omits `outcome_unknown` is treated conservatively as unknown; an explicit `outcome_unknown: false` remains a definite failure.
- Restart reconciliation requires a changed verified child identity plus the readiness conditions that were true before restart. Disconnect/reconnect in the same model preserves the unresolved restart expectation. The in-memory RustDesk operation cache also replays cached unknown results without rerunning the operation.
- The Gateway local-management API uses a durable SQLite operation ledger with payload binding and fail-closed pending claims. Completed results replay across DB reopen; a full ledger refuses new claims instead of evicting old operation identities.
- RustDesk verifies the supervisor/child identity, uses loopback HTTPS certificate pinning, and bootstraps local-management credentials through DPAPI. The normal Gateway process only exposes RustDesk management when its supervisor-owned child environment explicitly sets `MARQUEE_RUSTDESK_MANAGEMENT=1`.
- The mirrored supervisor source is under `tools/marquee-gateway-runtime/`. The live supervisor source was updated on disk during this work but has not been restarted in this continuation, so live-process behavior is not claimed from the source diff.

Fresh focused evidence on 2026-10-06 with the existing dirty feature trees preserved:

- Gateway Go: `go test ./internal/setup -run TestLocalManagement -count=1` → 13 passed; broad `go test ./internal/setup` and `go test ./internal/runtimeinfo` passed. The broad `go test ./cmd/marquee-gateway -count=1 -timeout 90s -v` aggregate run timed out; the test visible at timeout, `TestServePlaybackWithoutSiloSessionFallsBackAndHealthRemainsAvailable`, passes targeted 3/3 in about 2.4 s, so the aggregate timeout is recorded rather than misreported as a functional failure or a green full-suite result.
- RustDesk Rust: `cargo test --lib gateway_management --no-default-features` → 7 passed, 0 failed; `cargo test --lib host_management --no-default-features` → 9 passed, 0 failed. Existing repository warnings remain.
- Flutter model: `C:\flutter-3.24.5\bin\flutter.bat test test\emulator_model_test.dart` → 36 passed, 0 failed.
- Flutter Gateway UI/model regression: `flutter test --no-pub test\remote_conformance\host_capability_ui_test.dart test\emulator_model_test.dart` → 41 passed, 0 failed.
- Targeted Flutter analysis over `host_management_model.dart`, `emulator_model.dart`, `gateway_management_panel.dart`, `emulator_model_test.dart`, and `host_capability_ui_test.dart` → no issues found.

Remaining WP15 runtime/visual evidence gap:

- Deploy/restart the real supervisor and verify the owned Gateway child exposes the management endpoint only under the supervisor-controlled opt-in.
- Exercise status, setup handoff, IMDb enable/disable/refresh, accepted restart, definite rejection, and an intentionally interrupted/unknown restart against the real local supervisor/child pair.
- Use the matched Windows host and Android test APK recorded under WP14 for the live supervisor/phone acceptance run.
- Capture Galaxy S25 Ultra loading, measured, stale, unreachable, provider pending/error, restart confirmation/progress/result, and setup-handoff states at the required text scales. These remain WP12/WP15 physical evidence, not source-completion claims.

## BlueStacks video freeze recovery, 2026-10-06

This change addresses a reproduced recovery defect: an eight-frame Android decode queue could overflow, lose an H.264 reference frame, and then wait indefinitely for a keyframe that BlueStacks did not reliably generate. It does not yet establish that every physical-phone freeze has the same cause.

- Real local preview measurements on `127.0.0.1:5555` and `127.0.0.1:5575` observed only one keyframe over approximately three seconds despite `i-frame-interval:int=1`. A speculative interval-zero change was discarded. The production encoder option remains unchanged.
- When the client queue overflows, it keeps the queue bounded at eight frames, discards subsequent dependent frames, and requests a fresh video boundary from its own guest session. The decoder flushes on recovery. Requests retry at most once per second while waiting for a keyframe.
- The new additive protocol operation is gated by the host's `guest.video_refresh.v1` inventory capability. An older host retains its existing recovery limitation and needs the matching host update. No unsupported request is sent to an older host.
- The authenticated Windows connection routes refresh only to its own active guest or preview. The pinned, unmodified scrcpy v4 helper receives its supported reset-video control message, byte 17. Preview recovery does not grant Android input access. BlueStacks binaries, images, games, services, virtualization, and security configuration are untouched.

Fresh verification:

- The stalled-decoder regression first failed with 32 queued frames. Returning to the existing bounded, nonblocking channel made that regression pass.
- `cargo test --lib guest_video --features flutter`: 4 passed, 0 failed. Coverage includes reference preservation, backlog recovery, bounded/nonblocking ingest, and refresh authorization.
- `cargo test --lib server::emulator --features flutter`: 124 passed, 0 failed, 10 ignored.
- `cargo test --lib real_local_guest_reset_video_emits_fresh_keyframe --features flutter -- --ignored --nocapture` with the explicitly selected local guest `127.0.0.1:5555`: passed in 0.99 seconds. The live measurement tests now have socket read timeouts so a stalled guest cannot leave the test blocked indefinitely.
- Scoped `git diff --check`: passed; the existing LF/CRLF conversion warnings remain.
- The broader `cargo test --lib --features flutter` run is **not green**. Before it was stopped, 584 tests passed, 5 failed, and 17 were ignored. The failures were `common::tests::test_secure_tcp_rejects_unverified_versions_before_reply`, `rendezvous_mediator::tests::a_declined_udp_punch_still_replies`, and KCP tests `test_kcp_io_treats_socket_errors_as_loss`, `test_kcp_stream_close_delivers_all_frames`, and `test_kcp_stream_loopback_roundtrip_and_close`. The run was stopped after the port-forward tests `a_channel_opened_during_a_bulk_transfer_is_served_promptly` and `many_channels_echo_concurrently` remained unfinished. No unrelated networking fix or clean full-suite claim is included in this change.

Regression surface:

- `src/client/emulator.rs`: active guest and dashboard-preview decode ingest/recovery. These paths need to request a new keyframe after losing a reference; desktop video decoding remains separate.
- `src/client/io_loop.rs`: one guest-refresh capability flag, initialized and cleared with the existing connection state. This prevents unsupported recovery requests after reconnecting to an older peer.
- `libs/base/protos/message.proto`: one additive guest-refresh message/operation; existing field numbers remain intact.
- `src/server/emulator/remote.rs` and `src/server/emulator/connection.rs`: authenticated refresh authorization and connection-owned session lookup, required to avoid cross-session access.
- `src/server/emulator/remote_windows.rs`: capability advertisement and forwarding refresh through the owned guest control worker.
- `src/server/emulator/guest_runtime.rs`: the pinned helper control-message constant and local measurements. Encoder configuration is unchanged.

Deployment evidence:

- Final Windows release build completed with `cargo build --locked --features flutter,hwcodec,vram --lib --release`. `librustdesk.dll` is 42,684,928 bytes, SHA-256 `6E736C7E268C3F1FAE065971DFD3461D0614FCDF93EB553CCB330220ACB5F5CF`, staged under `C:\Users\gregr\Downloads\MIRPG-Remote-Freeze-Recovery-2026-10-06`.
- The prepared `MIRPG-RustDesk-Freeze-Recovery-Update.cmd` / `.ps1` validates the source hash and service installation path, backs up the existing DLL, stops only the installed RustDesk processes, installs the new library, records the change, and attempts rollback if installation fails. Re-running it against the same verified DLL is a no-op.
- Automatic approval review rejected the attempted elevated host update with only `blocked by policy`; no equivalent elevation route was retried. The user launched the prepared updater manually. The installed DLL now matches `6E736C7E268C3F1FAE065971DFD3461D0614FCDF93EB553CCB330220ACB5F5CF`; the installed RustDesk service was independently verified Running/Automatic with new PID `36932`. Its update record reports `2026-10-07T06:15:48Z` (UTC) and preserves the previous `98F3F53E5157...` DLL backup.
- Android native release build completed through `tools/build_android_native_windows.ps1`; its temporary dependency build-script edits were restored byte-for-byte. The final ARM64 `librustdesk.so` is 37,785,080 bytes with SHA-256 `7BE5074BF2B3CD4DF5EAE30B2078D60D928E22FA6A68D8309D29029F0722458F`.
- `:app:packageDebug -PmirpgTestApk=true` completed successfully. APK `C:\Users\gregr\Downloads\MIRPG-Remote-test2088-freeze-recovery.apk` is 130,816,598 bytes, SHA-256 `3B6F0487A8C7AE65AEC9D8984E630EC3D8389C596F62B388B39F6B17B2A63146`. Package identity is `com.carriez.flutter_hbb.mirpgtest`, versionCode `4088`, versionName `1.5.0-test2088`; its embedded JNI hash matches the final ARM64 library. Signature and alignment checks pass. Its debug certificate SHA-256 `b324e23f43e4d8a4fe761d39d40cd72821aa06af2027f57a624bba7d48457d18` matches the previous test2086 APK.
- The connected phone was confirmed as Galaxy S25 Ultra (`SM-S938W`) at `10.0.4.92:43051`. `adb install -r` returned Success, and a subsequent independent package query confirms `4088` / `1.5.0-test2088`. Existing app data was preserved. APK `test2087` was built but not installed. Sustained physical-phone playback and preview/fullscreen switching remain acceptance work.
- Launching the installed test app reconnected to `jarvis`; the captured phone Overview showed `Direct · 6 ms`, both live PC-monitor cards, and the connected workspace tabs. The app remained alive with no new crash recorded after launch. A subsequent screenshot showed the phone launcher, so further UI automation was stopped instead of continuing against a different foreground screen. This confirms install/reconnect, not sustained BlueStacks playback. The local screenshots are `C:\Users\gregr\AppData\Local\Temp\mirpg-freeze-check.png` and `mirpg-freeze-instances.png`; the attempted UI-automation tree dump did not reach idle and is not counted as evidence.
- Existing dirty edits are preserved. No git push, public release, unrelated Gateway restart, or BSOD investigation was performed.
