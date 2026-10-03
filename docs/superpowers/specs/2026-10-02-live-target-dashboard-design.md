# Live BlueStacks and PC monitor dashboard

Date: 2026-10-02
Status: Implemented inline, built and installed on the authorized phone. Initial dashboard/direct-connection/fullscreen checks passed; remaining physical scenarios are recorded in the implementation plan.

## Intended outcome

Opening the Android app reconnects to the last PC through normal RustDesk authentication, then shows an OSLink-style overview of BlueStacks instances and individual PC monitors. Running targets have continuous live video cards. A stopped instance has a Boot button. Opening a card enters fullscreen control, with a left-side switcher between all supported targets and right-side Android navigation controls outside the game image.

The user explicitly requested live views, monitor switching, and inline implementation without agents. Periodic screenshots do not satisfy the live-preview requirement. LDPlayer remains outside this dashboard, without removing its existing integration.

## Chosen approach

Use one authenticated RustDesk connection with multiple identified video streams: lighter streams for visible previews and higher quality for the selected fullscreen target. Reuse existing monitor capture subscriptions and guest capture helpers where their permissions and lifecycle permit it. Extend the emulator protocol additively for preview ownership and target selection.

Separate full remote connections per card would duplicate authentication and session ownership and increase load. A screenshot dashboard would be cheaper but would not meet the agreed behavior. Neither is the selected approach.

## User experience

### App opening and authentication

- Read the last PC through the existing RustDesk configuration, rather than introducing another peer identity store.
- Attempt one automatic connection on app opening. Authentication, saved credentials, acceptance requirements, and permissions follow existing RustDesk behavior.
- After successful authentication and dashboard capability negotiation, open the dashboard instead of briefly exposing a desktop stream as the main screen.
- No last PC, rejected authentication, unavailable PC, or cancelled connection leads to the existing connection screen with useful status and a manual retry. Do not create an automatic retry loop.
- An older host without dashboard support retains its existing remote desktop/emulator selection behavior and a clear compatibility notice.
- Returning from fullscreen opens the dashboard without disconnecting. Leaving the remote session releases its subscriptions and returns to the connection screen.

### Dashboard

- Header: PC identity/name, actual Direct/Relay transport state, and a way to leave or choose another PC.
- Cards: BlueStacks instances first, then one card per currently available PC monitor. Use the incumbent Flutter theme and Material controls rather than reproducing OSLink branding.
- Each card has a target name, source/type badge, and truthful state. Running cards show continuous decoded video, not a desktop window crop or a periodically fetched screenshot.
- A stopped instance displays Boot. Boot is explicit, waits for actual Android readiness, and uses its configured default application only through the existing launch behavior. A running instance or monitor can be opened by tapping its card.
- Starting, unavailable, permission denied, and capture failed states have visible messages and an appropriate retry action. An error on one preview does not fail the entire connection.
- On compact phones use a scrolling card list; on expanded widths use a grid. Keep target labels, controls, font scaling, dark theme, and system insets usable.

### Fullscreen and switching

- Reserve black side rails around the fitted remote image. A left-side switcher button opens a live target chooser containing BlueStacks instances and PC monitors. It also provides a return to the dashboard.
- The right rail contains Back, Home, and Recents for an Android target. PC targets expose appropriate existing desktop controls, without sending Android navigation to Windows.
- Rails use at least 48 dp touch targets and safe-area padding. They do not overlap the remote image even when the aspect ratio would otherwise leave no black margin; reserve the required space before fitting the image.
- Preserve guest dimensions/orientation. Use landscape for a landscape guest and portrait for a portrait guest; restore ordinary app presentation on returning to the dashboard. Monitor content fits its actual display aspect ratio.
- Switch within the same authenticated session. Do not close a running instance when switching away, boot other stopped instances implicitly, or require Multi-instance Manager.
- Clear/cancel the previous target's active gesture before changing input ownership. Enable input for the new target only after selection is acknowledged. Stale frames and selection responses cannot replace the newly selected target.
- Guest touch mapping uses the actual fitted image bounds after rails/insets. Taps on rails or letterboxing cannot become guest touches. Monitor input uses existing RustDesk display coordinates and input handling.
- System Back dismisses the chooser first, then returns fullscreen to the dashboard. Android guest Back remains a separate explicit rail control.

## Streaming architecture

### Current constraints

The current host owns one `GuestSession` per connection and suspends desktop subscriptions while it streams a guest. The client owns one guest decoder, and the mobile image model exposes one current image. Existing RustDesk monitor capture already supports multiple display subscriptions. Supporting simultaneous guest and monitor cards requires feature-specific stream ownership and rendering, rather than a cosmetic picker change.

### Target inventory and protocol

- Model a target as either a BlueStacks instance identifier or a currently valid desktop display identifier; keep the namespaces separate.
- Merge the existing BlueStacks inventory and current monitor inventory into the dashboard. Revalidate monitor identity after hotplug, rather than persisting an obsolete display index as if it were stable.
- Add a dashboard capability and optional messages/fields in `libs/base/protos/message.proto`. Preserve current emulator protocol behavior for peers that do not negotiate the new capability.
- Describe subscribed streams with target identity, per-stream identity, dimensions, state, and whether they are preview or selected streams. Keep request and selection correlation explicit.
- Reject invalid targets, unsupported operations, oversized subscription requests, unauthenticated requests, and input addressed to an inactive target.
- Do not add a second unauthenticated HTTP/WebSocket video endpoint or change peer authentication to accommodate previews.

### Host ownership

- Feature-specific connection state owns the dashboard subscriptions and the selected input target. Keep shared server hooks thin.
- Monitor previews use existing capture/video services where possible. Dashboard subscriptions coexist with guest previews instead of being indiscriminately suspended by the old single-guest selection path.
- BlueStacks previews use the existing Android helper/capture boundary through ADB. Preview attachment is view-only and never boots a stopped instance. Boot and game-launch actions require the existing control authority.
- Preview workers cannot inject input. Only the acknowledged selected target receives input, with current RustDesk permissions enforced throughout the session.
- Preserve existing audio behavior; preview cards are silent. Adding guest audio capture is outside this change.
- Stop capture/decoding work when a target leaves the visible subscription set. Cancel all connection-owned workers on disconnect or revoked viewing permission. Restore applicable desktop service subscriptions when leaving dashboard mode.
- Do not kill the shared ADB server, alter BlueStacks binaries/settings for capture convenience, or attach to an unrelated ADB device.

### Client and Flutter ownership

- Route each guest stream to its own bounded decoder and image slot; keep desktop display IDs distinct from guest video channels.
- Maintain target-keyed images only while this feature is active. Keep the existing single-image desktop path for unsupported/ordinary sessions.
- A frame/status update for one target must not clear or overwrite other target images. Dispose replaced images and closed stream resources.
- Preserve the repaired guest decoder's handling of inter-frame dependencies: decode required frames, present the freshest completed image, and recover safely after overflow. Do not drop arbitrary dependent encoded frames to simulate preview throttling.
- Keep discovery, subscriptions, boot state, selection state, and errors in a feature-specific model; widgets display that state rather than managing independent competing sessions.
- Startup routing uses a thin mobile home/connection hook and an explicit authenticated-session event, with protection against duplicate dashboard routes.

## Performance policy

Implementation starting values, subject to measured tuning without changing the agreed workflow:

- Continuous guest previews: target approximately 360p at 6 frames per second, using encoder-side resolution/rate limits where supported. These are live video streams, with a lower preview frame rate rather than periodic screenshot polling.
- Start with a viewport density of at most four live preview cards, plus the selected fullscreen stream. The scrolling list/grid and chooser expose additional targets as the user scrolls; each exposed preview is live. Tune this initial density after measuring the phone and host, rather than showing extra visible cards as frozen images labelled Live.
- The selected guest retains the existing approximately 1280-pixel maximum capture size and 30 FPS target, subject to current runtime/network limits. A selected monitor follows existing RustDesk quality controls.
- Hidden dashboard/chooser previews pause while playing; opening the chooser resumes its visible live previews. Backgrounding the phone pauses preview work. Hidden cards must not carry a Live badge over an old image.
- Reuse monitor capture/QoS safely. Do not change global monitor quality in a way that degrades another controller's session merely to reduce dashboard preview load. If the existing service cannot independently reduce a preview, retain its supported quality and bound subscriptions rather than changing unrelated clients.
- Use bounded queues/resources per connection and prioritize active control responsiveness over preview bandwidth. No per-frame unthrottled logging.
- Do not promise OSLink-equivalent performance before the actual phone/host measurements.

## Network behavior

Keep the current direct-first connection policy and relay fallback. Same-LAN availability should benefit the existing transport selection; explicit Always use relay/proxy policy remains respected. Video previews and fullscreen streams share the selected authenticated connection.

The dashboard initially displays Direct or Relay from actual connection state. Do not label a connection LAN merely because both devices have private addresses or the session is direct. A LAN label would require verified selected endpoint information; adding that label is not required for this specification.

No port forwarding, router changes, relay disabling, firewall/security weakening, or network-policy override is part of this work.

## Error handling and compatibility

- Keep a failed card localized; allow retry or choosing another target.
- Inventory refresh and monitor reconfiguration remove invalid selections cleanly and return to the dashboard when necessary.
- A guest without ADB/capture availability reports that requirement and leaves desktop monitor access usable.
- Restarted streams use distinct identity so delayed frames cannot repaint a newer selection.
- Permission changes immediately prevent disallowed control; unavailable viewing releases affected preview work.
- Older clients/hosts keep existing paths; ignore or reject unsupported feature messages safely.
- Existing cleanup profiles, restore records, updater behavior, Codex bridge, and LDPlayer integration are outside the change.

## Verification and acceptance

1. On the phone, opening the app reconnects to the last PC, completes ordinary authentication, and shows the dashboard. Failure/cancellation allows manual connection without a retry loop.
2. Running BlueStacks and all available PC monitors appear as distinct cards. Visible moving content updates continuously, with no screenshot-polling implementation. Stopped instances show Boot without being started by inventory/preview enumeration.
3. Boot reports real readiness or a useful failure. A configured default game follows existing launch rules.
4. Open a guest fullscreen, switch to a PC monitor, switch to another monitor/instance, and return to the dashboard without reconnecting. Input goes only to the selected target; previews cannot control any target.
5. In landscape and portrait, right Android controls and left switching remain outside content. Touch mapping still reaches the corresponding guest positions and ignores rails/letterboxing.
6. Visible chooser cards remain live. Hidden/offscreen/background views release unnecessary capture/decoding work. Disconnect and permission revocation clean up streams without stopping running emulators.
7. Check the actual Direct/Relay status on the LAN and, when an existing authorized relay test route is available, confirm fallback. Do not claim a verified LAN route from a Direct badge alone.
8. Run focused Rust tests for stream authorization/identity/lifecycle and guest decoder continuity; Flutter model/widget tests for target selection, image separation, startup routing, and fitted input bounds; analyze touched Dart code; build Windows host and the Android test APK.
9. Test on the connected Samsung phone when wireless ADB remains available, capturing dashboard/chooser/fullscreen evidence. Record actual preview responsiveness and any unverified hardware cases rather than claiming success from unit tests alone.
10. Inspect the final diff and report every existing file/runtime path changed, explaining unavoidable shared hooks. Preserve unrelated edits and ordinary desktop behavior with this feature unsupported.

## Delivery boundaries

Build an installable Android test APK and the matching Windows host changes. Preserve source/artifact correspondence and existing signing identity for test upgrades. Direct installation to the previously authorized test phone may be attempted if its ADB endpoint is still available; an expired pairing/connection requires fresh connection details rather than guessing ports.

Do not publicly publish a new APK/source release or push unrelated changes based solely on implementation approval. Public delivery is a separate destination/action decision after reviewable artifacts exist.

## Approval and execution

The next step is user review of this written specification. After approval, produce the written implementation plan for review. Execution is inline in the current chat, without agents, matching the user's standing instruction.
