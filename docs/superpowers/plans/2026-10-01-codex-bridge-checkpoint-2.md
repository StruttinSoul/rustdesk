# Codex Bridge Checkpoint 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Windows-host Codex bridge foundation that discovers Codex, connects through supported local app-server paths, negotiates core capabilities, and enumerates user-facing threads.

**Architecture:** Keep Codex-specific JSON-RPC and lifecycle logic under `src/server/codex/`. Use one typed line-oriented app-server client for both `codex app-server proxy` and bridge-owned `codex app-server --listen stdio://` children. The public bridge exposes normalized installation, connection, capability, and thread types while keeping raw arbitrary RPC private.

**Tech Stack:** Rust, `serde`/`serde_json`, standard process/stdio APIs, existing RustDesk error/logging conventions, Codex app-server v2 JSON-RPC.

**Spec:** `docs/codex-remote-control-architecture.md`

## Global Constraints

- Codex communication stays local to Windows; do not expose app-server to the LAN/internet.
- Do not send Codex credentials, tokens, cookies, or arbitrary raw RPC to Android.
- Do not terminate Codex Desktop or its app-server.
- Prefer a healthy supported managed daemon/proxy path; fall back to bridge-owned direct stdio.
- Keep protocol/version-specific logic inside the Codex subsystem.
- Preserve existing Desktop and emulator runtime paths.
- Add no new dependency unless the existing RustDesk stack cannot provide the required primitive.
- Avoid `unwrap`/`expect` in production paths.

## Review Focus

- Codex missing from PATH/default install locations -> discovery returns unavailable cleanly; test in Task 1.
- Managed daemon unavailable or proxy startup fails -> connection falls back to direct stdio without leaving an orphan; test in Task 2.
- JSON-RPC notification arrives while waiting for a response -> notification is retained/forwarded and the matching response still completes; test in Task 2.
- Older app-server returns method-not-found for an optional method -> only that capability downgrades; test in Task 3.
- Internal sub-agent threads appear in `thread/list` -> top-level enumeration excludes them while keeping ordinary Desktop-created threads; test in Task 4.

---

### Task 1: Codex installation discovery

**Files:**
- Create: `src/server/codex/mod.rs`
- Create: `src/server/codex/discovery.rs`
- Modify: `src/server.rs`
- Test: inline `#[cfg(test)]` module in `src/server/codex/discovery.rs`

**Interfaces:**
- Consumes: Windows environment and filesystem only.
- Produces: `CodexInstallation`, `CodexDiscovery`, `discover_installation()` and command construction helpers used by Task 2.

- [ ] **Step 1: Write failing discovery tests**

Test explicit executable override/default candidate ordering, version-output parsing, and missing-install behavior without invoking the real installation.

- [ ] **Step 2: Run discovery tests and verify RED**

Run: `cargo test codex::discovery --lib`
Expected: compile/test failure because the discovery module does not exist yet.

- [ ] **Step 3: Implement discovery**

Create normalized installation metadata with executable path, parsed version string, and configured/effective Codex-home candidate. Keep process execution bounded and do not inspect credential files.

- [ ] **Step 4: Run discovery tests and verify GREEN**

Run: `cargo test codex::discovery --lib`
Expected: PASS.

- [ ] **Step 5: Commit**

Commit message: `feat: add Codex installation discovery`

### Task 2: Typed local JSON-RPC transport and lifecycle fallback

**Files:**
- Create: `src/server/codex/rpc.rs`
- Create: `src/server/codex/process.rs`
- Modify: `src/server/codex/mod.rs`
- Test: inline unit tests using a fake child/stdio harness where practical.

**Interfaces:**
- Consumes: `CodexInstallation` from Task 1.
- Produces: `CodexConnectionMode`, `CodexProcess`, `JsonRpcClient`, typed `request(method, params)` internal primitive, notification receiver/queue, and managed-proxy -> direct-stdio fallback selection.

- [ ] **Step 1: Write failing transport/lifecycle tests**

Cover matching response IDs, interleaved notifications, JSON-RPC error parsing, child shutdown/reaping, and fallback when the managed-proxy path cannot connect.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `cargo test codex::rpc codex::process --lib`
Expected: compile/test failure because transport/process modules do not exist yet.

- [ ] **Step 3: Implement the minimal local transport**

Use newline-delimited app-server JSON-RPC over child stdin/stdout. Never bind a network listener. Start `codex app-server proxy` only when managed-daemon health is confirmed; otherwise start `codex app-server --listen stdio://`. Own and reap only children started by the bridge.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run: `cargo test codex::rpc codex::process --lib`
Expected: PASS.

- [ ] **Step 5: Commit**

Commit message: `feat: add Codex app-server transport`

### Task 3: Initialize and capability tracking

**Files:**
- Create: `src/server/codex/protocol.rs`
- Modify: `src/server/codex/mod.rs`
- Test: inline tests in `src/server/codex/protocol.rs`

**Interfaces:**
- Consumes: `JsonRpcClient` from Task 2.
- Produces: `CodexServerInfo`, `CodexCapability`, `CapabilityState`, typed initialize/core-probe methods, and method-not-found downgrade behavior.

- [ ] **Step 1: Write failing protocol tests**

Test initialize decoding (`userAgent`, `codexHome`, Windows platform fields), core capability success, method-not-found downgrade, and unrelated RPC errors that must not silently disable a capability.

- [ ] **Step 2: Run protocol tests and verify RED**

Run: `cargo test codex::protocol --lib`
Expected: compile/test failure because the protocol module does not exist yet.

- [ ] **Step 3: Implement typed initialization/capability state**

Keep supported method names in one allowlisted enum/table. Core probes use read-only methods. Optional method availability starts unknown and changes to unavailable on JSON-RPC `-32601` for that exact operation.

- [ ] **Step 4: Run protocol tests and verify GREEN**

Run: `cargo test codex::protocol --lib`
Expected: PASS.

- [ ] **Step 5: Commit**

Commit message: `feat: add Codex protocol capability tracking`

### Task 4: Thread enumeration and real local proof

**Files:**
- Create: `src/server/codex/threads.rs`
- Modify: `src/server/codex/mod.rs`
- Test: inline unit tests plus ignored local integration test.

**Interfaces:**
- Consumes: protocol/client interfaces from Tasks 2-3.
- Produces: `CodexThreadSummary`, `CodexThreadStatus`, `list_threads()` with pagination and user-facing filtering.

- [ ] **Step 1: Write failing thread-model/filter tests**

Cover `notLoaded`/`idle`/`active`/`systemError`, approval/input active flags, pagination accumulation, and filtering of threads with `parentThreadId` or `agentRole` while preserving normal Desktop-originated top-level threads.

- [ ] **Step 2: Run thread tests and verify RED**

Run: `cargo test codex::threads --lib`
Expected: compile/test failure because the thread module does not exist yet.

- [ ] **Step 3: Implement typed thread listing**

Use `thread/list` pagination, retain stable thread IDs and user-facing metadata, and keep raw persisted path/source internals out of the public Android-facing model.

- [ ] **Step 4: Add an ignored real-local integration test**

The test starts the supported local bridge connection, initializes it, and asserts that at least one real thread can be enumerated when Codex is installed. Keep it ignored for CI portability.

- [ ] **Step 5: Verify focused and real-local tests**

Run: `cargo test codex::threads --lib`
Expected: PASS.

Run: `cargo test codex_local_thread_enumeration --lib -- --ignored --nocapture`
Expected on the audited machine: PASS and at least one thread enumerated.

- [ ] **Step 6: Run the full Rust lib suite and static checks**

Run: `cargo test --lib`
Expected: no regressions.

Run: `cargo fmt --check`
Expected: clean.

Run: `git diff --check`
Expected: clean.

- [ ] **Step 7: Commit**

Commit message: `feat: add Codex thread enumeration`
