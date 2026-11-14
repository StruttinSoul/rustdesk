# RustDesk / MIRPG - Project Rules

This checkout contains the RustDesk-based remote-desktop and emulator-control app. Work only within the requested change; preserve pre-existing edits, users' connection settings, security boundaries, and working remote-control paths.

## Architecture and ownership

- Rust app: src/; remote session/video/audio/input/network: src/server/ and src/platform/.
- Current desktop/mobile UI: flutter/ (flutter/lib/desktop/, mobile/, common/, models/). src/ui/ is deprecated Sciter UI.
- Shared protocol and config: libs/hbb_common/ is a Git submodule; libs/base/ is the client crate; libs/base/src/config/keys.rs owns client config options.
- Capture: libs/scrap/; input: libs/enigo/; file transfer: libs/base/src/fs.rs.
- Prefer changes in the feature's owner. Avoid churning hbb_common if a client-only fix belongs in libs/base. Preserve existing platform behavior when a new feature is disabled.

## Reliable implementation

- Keep Rust idiomatic: handle fallible operations with Result/? or explicit errors; do not silently ignore errors or add unnecessary clones/dependencies. unwrap()/expect() are for tests or justified poisoned-lock handling, not routine production errors.
- Assume Tokio is already running. Never nest runtimes, block_on inside async code, hold locks across await, or sleep a Tokio task with std::thread::sleep. Use async operations or spawn_blocking for blocking work.
- Do not add unthrottled debug-or-higher logging in per-packet, per-frame, per-input, or peer-driven loops. Use trace or the project's throttled log utility.
- Make the smallest coherent safe change for the requested outcome. Do not refactor unrelated paths. If the user explicitly requests a UI redesign or structural improvement, scoped refactoring is permitted and may be preferable to duplicating obsolete code.
- Diagnose before fixing: reproduce where possible, inspect logs and current behavior, apply a focused solution, and validate affected existing flows. Test user-visible behavior rather than private implementation details. Distinguish verified tests from untested claims.

## Load detailed instructions only when relevant

- Production edits, regression analysis or PR review: docs/agents/CHANGE_REVIEW.md. Its very conservative additive-only advice is a default for narrow bug fixes, not a prohibition on expressly authorized redesign.
- Translating or adding locale keys: docs/agents/LOCALIZATION.md. Preserve key names, placeholders, escapes, and the manually maintained Italian translations.
- For Flutter UI tasks, inspect the actual running application and its current components. Do not spend time redesigning unrequested screens or legacy Sciter UI.

Do not create a PR, push, publish, or deploy unless the current task explicitly authorizes the action. End with a concise list of changed files, actual checks, regression surface, and any remaining limits.