# Codex Checkpoint 3: Read-only Android UI

## Goal

Expose Codex as a read-only native mobile surface on an authenticated RustDesk remote-control session while keeping Codex credentials, raw app-server JSON-RPC, and process ownership on Windows.

## Constraints

- Keep the existing Desktop remote-control path unchanged.
- Use optional protobuf additions so older RustDesk peers ignore Codex support cleanly.
- Android may send only typed, allowlisted Codex read requests.
- Do not expose `CODEX_HOME`, raw app-server messages, credentials, or arbitrary JSON-RPC.
- Filter internal worker/subagent threads from the top-level list.
- Persisted Desktop thread identity is readable, but a bridge-owned app-server must not claim ownership of the exact live Desktop runtime.
- Use paginated `thread/turns/list` and `thread/items/list` for retained history; do not depend on deprecated full-history hydration.
- Checkpoint 3 is read-only. Sending, steering, interruption, resume/start, and approvals remain later checkpoints.
- Perform review inline; the user explicitly requested no subagents.

## Implementation

1. Add typed Codex protocol messages to `message.proto`:
   - advertise Codex read support in `Features`;
   - read-only requests for thread list, history page, and event subscription;
   - normalized thread/history/event/error responses;
   - standalone request/response variants on `Message`.

2. Extend the Windows Codex bridge:
   - paginate thread history through current app-server APIs;
   - normalize user/agent/tool/history items to a narrow display model;
   - normalize supported app-server notifications without forwarding raw payloads;
   - make unsolicited notifications drainable without issuing a dummy RPC request.

3. Add a process-local Codex read service on Windows:
   - own one bridge/app-server child at a time;
   - serialize read requests on a dedicated worker thread so RustDesk network loops do not block on app-server I/O;
   - reconnect on bridge failure;
   - broadcast normalized live events only to authenticated subscribers.

4. Wire RustDesk host/client transport:
   - accept Codex requests only on authenticated Remote sessions on Windows;
   - send typed responses through the normal encrypted RustDesk stream;
   - classify the new request in session-scope validation;
   - route responses to the client UI handler.

5. Add Flutter mobile model/UI:
   - surface `Codex` only when the peer advertises support;
   - add a native read-only Codex page from the mobile remote toolbar;
   - list top-level threads with normalized state and last activity;
   - open paginated conversation/history and apply live normalized events;
   - show explicit empty/error/unavailable states and label the surface read-only for this checkpoint.

6. Verify:
   - focused Rust bridge/protocol/service tests;
   - protobuf compatibility/round-trip tests where useful;
   - Flutter model/widget tests for list/history/state behavior;
   - real local Codex thread/history smoke test where supported;
   - `cargo test --lib` with the repo-required vcpkg/clang environment;
   - Flutter analyze/test for touched mobile code;
   - direct rustfmt on touched Rust files and `git diff --check`;
   - manual security/ownership review before local commits.

## Acceptance

- A supported Windows peer advertises Codex availability.
- Android can request and render filtered Codex threads without desktop pixel streaming as the data source.
- Opening a thread shows retained conversation/history through typed RustDesk messages.
- App-server notifications are normalized into typed Codex events; raw JSON-RPC never crosses to Android.
- No Checkpoint 4 mutation method is reachable from the Android protocol.
