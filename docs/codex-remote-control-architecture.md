# Codex Remote Control — Checkpoint 1 Architecture Audit

Date: 2026-10-01

## Goal

Add a first-class Codex target beside Desktop and Android Emulator targets while keeping Codex credentials, app-server traffic, and lifecycle local to the Windows host.

```text
RemoteTarget
├── Desktop
├── Emulator
│   ├── LDPlayer
│   └── BlueStacks
└── Codex
```

The native Codex path is a typed RustDesk feature. Android must never receive an arbitrary app-server JSON-RPC tunnel. Desktop control remains the fallback when a live Codex Desktop session cannot be safely controlled through a supported app-server connection.

## Installed Codex audit

The audited machine is running Codex CLI/app-server `0.155.1` on Windows.

- Primary CLI: `C:\Users\gregr\AppData\Local\Programs\OpenAI\Codex\bin\codex.exe`
- Codex Desktop also bundles a CLI under its installation tree.
- `CODEX_HOME` is not explicitly set in the environment.
- The effective Codex home reported by `initialize` is `C:\Users\gregr\.codex`.
- Codex Desktop is running and launches its own `codex.exe ... app-server --analytics-default-enabled` child process.

The Desktop child does not specify `--listen`, so the documented/default transport is `stdio://`. Its live RPC stream is therefore owned by the Desktop parent process and is not an attachable local socket for RustDesk.

## Supported local app-server transports and lifecycle

`codex app-server --help` in 0.155.1 advertises:

- `stdio://`
- `unix://` / `unix://PATH`
- `ws://IP:PORT`
- `off`

The supported managed lifecycle is exposed through `codex app-server daemon` with `bootstrap`, `start`, `restart`, `update`, `enable-remote-control`, `disable-remote-control`, `stop`, and `version` commands. `codex app-server proxy` proxies stdio bytes to the managed app-server control socket.

On the audited machine, `daemon version` cannot currently reach the expected control socket and `daemon start` fails from the current Codex execution host because its Windows Job Object prevents daemon detachment. This is a host limitation observed during the audit. A direct `codex app-server --listen stdio://` child works and is the verified fallback.

The initial bridge lifecycle order is therefore:

1. discover the user-scoped Codex CLI;
2. detect a healthy managed daemon and use `codex app-server proxy` when available;
3. optionally request supported daemon startup from a normal interactive-user host;
4. fall back to a bridge-owned `codex app-server --listen stdio://` child;
5. if native startup/attachment is unavailable, expose Desktop handoff.

The bridge owns only processes it starts and must terminate/reap a bridge-owned direct child on shutdown. It must not terminate Codex Desktop or Desktop's app-server.

## Protocol findings

The locally generated 0.155.1 schema establishes the v2 surface used by this feature. Relevant client methods include:

```text
initialize
thread/list
thread/read
thread/loaded/list
thread/resume
thread/start
thread/fork
thread/items/list
thread/turns/list
turn/start
turn/steer
turn/interrupt
thread/unsubscribe
```

Relevant notifications include:

```text
thread/started
thread/status/changed
thread/queue/changed
turn/started
turn/completed
item/started
item/completed
item/agentMessage/delta
item/commandExecution/outputDelta
item/fileChange/outputDelta
item/fileChange/patchUpdated
turn/diff/updated
serverRequest/resolved
```

The server can request approvals through methods including:

```text
item/commandExecution/requestApproval
item/fileChange/requestApproval
item/permissions/requestApproval
item/tool/requestUserInput
```

Command and file approval decisions include `accept`, `acceptForSession`, `decline`, and `cancel`; command approvals can also carry policy amendments. The first Android implementation should expose the narrow user intent needed for ordinary approve/deny and translate that to explicit supported decisions. It should not accept arbitrary decision JSON from Android.

`initialize` reports `userAgent`, `codexHome`, `platformFamily`, and `platformOs`. The bridge should treat this response as authoritative runtime identity after connection.

## Thread identity and runtime ownership

`thread/list` returns stable thread identity and useful user-facing metadata including `id`, `sessionId`, `name`, `cwd`, `projectId`, `gitInfo`, `model`, `reasoningEffort`, `source`, `originator`, `parentThreadId`, `agentRole`, timestamps, and runtime `status`.

The 0.155.1 thread runtime status is:

```text
notLoaded
idle
systemError
active
  ├── waitingOnApproval
  └── waitingOnUserInput
```

`thread/loaded/list` is explicitly the set of thread IDs loaded in the current app-server process.

The audit verified this behavior against the live machine:

- a fresh direct app-server reported an empty `thread/loaded/list`;
- the currently visible RustDesk/Codex Desktop thread was readable by ID but reported `status: notLoaded` in that fresh app-server;
- resuming an older Desktop-created thread with `thread/resume` and `excludeTurns: true` succeeded;
- after resume, that thread appeared in `thread/loaded/list` and reported `status: idle` in the bridge-owned app-server.

This proves that persisted thread identity is shared, while loaded/active runtime state is app-server-process-local. A separate bridge can resume the same persisted thread ID, but it must not describe that as co-controlling the exact live Codex Desktop runtime.

For normal thread lists, child/worker sessions should be filtered from top-level display when `parentThreadId`, `agentRole`, or equivalent sub-agent metadata identifies them.

## Codex remote-control feature is not the RustDesk bridge transport

The app-server also exposes `remoteControl/*` and a `remoteControl/status/changed` notification with `disabled`, `connecting`, `connected`, and `errored` states plus remote identity fields. Official Codex source shows that this belongs to Codex's managed remote-control facility.

RustDesk should not depend on or repurpose that feature as its local bridge. RustDesk needs only the supported local app-server JSON-RPC surface over a local process/IPC path.

## Windows service and user-session boundary

RustDesk already has the primitives needed to keep Codex in the interactive user's security context:

- active Windows session tracking in `src/platform/windows.rs`;
- `run_exe_in_session(..., as_user = true, ...)` / `run_as_user(...)` for user-context launch;
- service-scoped IPC authorization tied to the active session;
- peer-executable validation for protected IPC channels;
- one-time-token handshakes in `src/server/portable_service.rs`;
- a terminal-helper pattern that launches a restricted helper as the logged-in user and restricts local IPC to SYSTEM plus that user.

Codex credentials and `CODEX_HOME` belong to the logged-in user. A SYSTEM/service process must not copy tokens or impersonate Codex state by reading private credential files. The durable design is a small `CodexBridge` process/component in the active user's session, with the RustDesk service/server talking to it over authenticated local IPC.

Checkpoint 2 can initially implement the bridge/provider logic inside the user-session RustDesk server process because that process is already the correct execution boundary in normal interactive operation. The protocol and discovery code should remain isolated so a dedicated helper can be introduced without changing the Android-facing RustDesk API.

## Normalized host model

The first host model should keep app-server transport details private:

```text
CodexBridge
├── CodexInstallation
├── CodexConnection
│   ├── ManagedProxy
│   └── DirectStdio
├── CodexCapabilities
├── CodexThreadSummary
└── typed request methods
```

Suggested normalized state mapping:

```text
app-server unavailable        -> Unavailable
starting child/daemon         -> Starting
connected, no selected thread -> Ready
thread notLoaded              -> Resumable
thread idle                   -> Idle
thread active                 -> Working
active + waitingOnApproval    -> WaitingForApproval
active + waitingOnUserInput   -> WaitingForInput
thread systemError            -> Failed
connection lost               -> Disconnected
```

Completion is a turn-level fact (`turn/completed`) rather than a durable thread runtime state and should not be inferred from elapsed time.

## Capability strategy

App-server 0.155.1 does not return a single exhaustive server-method capability object during `initialize`. The bridge should combine:

1. authoritative runtime identity from `initialize`;
2. safe read-only probes for core methods such as `thread/list` and `thread/loaded/list`;
3. typed optional operations that downgrade themselves if the server returns JSON-RPC method-not-found;
4. protocol-version telemetry for diagnostics only, not as the sole feature gate.

This allows newer/older Codex versions to keep core thread listing while optional actions such as steer/fork can degrade independently.

## Approval and replay boundary

Approval cards must be keyed to the authenticated RustDesk session plus the exact Codex `threadId`, `turnId`, `itemId`, request method, and request lifecycle. Where present, `approvalId` is retained as additional identity.

`serverRequest/resolved`, turn completion/interruption, disconnect reconciliation, or a newer request for the same item must retire the actionable card. Android sends a typed approve/deny action against that identity; Windows converts it to the supported app-server decision.

## Logging boundary

Safe diagnostics include Codex version, selected connection mode, lifecycle transitions, thread IDs, method category, and compatibility failures.

Do not log auth tokens, cookies, API keys, full prompt text by default, arbitrary source-file contents, or sensitive environment values.

## Checkpoint 2 implementation boundary

Checkpoint 2 will add only the host bridge foundation:

- Codex installation discovery;
- supported managed-proxy/direct-stdio connection selection;
- typed JSON-RPC request/response plumbing;
- initialize and capability state;
- user-facing thread enumeration/filtering;
- deterministic unit tests plus an ignored real-local integration test.

No Android UI or RustDesk wire-protocol messages are added in this checkpoint. Those remain later checkpoints after the host bridge is proven.
