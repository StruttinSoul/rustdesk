# MIRPG Remote P1 Application Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Execution remains inline without agents at the user's explicit request. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give MIRPG Remote one coherent graphite/mint mobile shell with truthful Computers/Overview navigation and explicit session-ending semantics while preserving the existing authenticated dashboard and remote-control behavior.

**Architecture:** Keep `RemotePage` as the authenticated session owner and keep `TargetDashboardPage` as the connected workspace. Apply a feature-scoped MIRPG theme to the mobile root and connected workspace, then adapt existing navigation/widgets rather than adding protocol or Windows-host surface. Session-ending actions continue through RustDesk's existing `clientClose` path so audit/lock semantics stay intact.

**Tech Stack:** Flutter/Dart, existing RustDesk FFI/session models, existing Material widgets and mobile pages.

**Spec:** `docs/superpowers/specs/2026-10-04-mirpg-remote-redesign-baseline.md`

## Global Constraints

- Primary phone target is Samsung Galaxy S25 Ultra (`SM_S938W`).
- Palette values are background `#101416`, surface `#191F22`, raised `#242C30`, primary text `#F1F4F5`, secondary text `#AEBAC0`, accent `#70D8C1`.
- Connected navigation vocabulary is exactly `Overview`, `System`, `Files`, `Shell`, `Codex` for destinations that are actually available.
- Keep one authenticated RustDesk session; do not create parallel connections for workspace pages.
- Preserve existing auth, capability gates, input permissions, view-only behavior, live previews, Boot, target ownership, and Direct/Relay state.
- P1 is Flutter-only: no protobuf, Rust host, BlueStacks, driver, security-setting, or update behavior changes.
- Do not fake background session minimization by opening a second Home page. True minimize/resume is P3 work.
- Exact board fidelity is unverified because the fourteen referenced design-board assets are not present.
- Execute inline without subagents, per the user's standing instruction.

## Review Focus

- 130% text scale and narrow portrait widths must not overflow the five-destination connected navigation or header actions.
- A host missing System, Files, Shell, or Codex capability must still produce a valid selected index and no phantom destination.
- System Back from a fullscreen guest/monitor must release active input and return to Overview; Back from Overview must not silently disconnect.
- Explicit `End session` must use the existing RustDesk close flow so connection audit and `lock_after_session_end` behavior are preserved.
- Theme scoping must not recolor ordinary desktop/web RustDesk or mutate global `MyTheme` constants.

---

### Task 1: Add the scoped MIRPG mobile theme

**Files:**
- Create: `flutter/lib/mobile/widgets/mirpg_remote_theme.dart`
- Create: `flutter/test/mirpg_remote_theme_test.dart`

**Interfaces:**
- Consumes: ambient `ThemeData` from the existing app.
- Produces: `abstract final class MirpgRemoteTheme` with the six fixed palette constants and `static ThemeData build(ThemeData base)`.

- [ ] **Step 1: Write the failing theme test**

Assert `MirpgRemoteTheme.build(ThemeData.light())` uses the six exact palette values, Material 3, dark brightness, the graphite scaffold/card/navigation surfaces, mint primary/selected indicator, and readable primary/secondary text.

- [ ] **Step 2: Run the test to verify it fails**

Run from `flutter/`: `flutter test test/mirpg_remote_theme_test.dart`

Expected: FAIL because `mirpg_remote_theme.dart` and `MirpgRemoteTheme` do not exist.

- [ ] **Step 3: Implement `MirpgRemoteTheme`**

Create `flutter/lib/mobile/widgets/mirpg_remote_theme.dart` with `static const Color background`, `surface`, `raised`, `textPrimary`, `textSecondary`, `accent`, and `static ThemeData build(ThemeData base)`. Use `base.copyWith(...)`; do not change global `MyTheme` constants.

- [ ] **Step 4: Run the theme test**

Run: `flutter test test/mirpg_remote_theme_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

Commit message: `feat: add MIRPG remote mobile theme`

### Task 2: Apply the shell to the mobile root

**Files:**
- Modify: `flutter/lib/mobile/pages/home_page.dart`
- Modify: `flutter/lib/mobile/pages/connection_page.dart`
- Test: `flutter/test/home_page_shell_test.dart` (create focused shell helpers/widgets as needed for deterministic testing)

**Interfaces:**
- Consumes: `MirpgRemoteTheme.build(Theme.of(context))`.
- Produces: root destination vocabulary `Computers`, `Chat`, `Share`, `Settings`; root navigation uses Material `NavigationBar` while preserving the current page list and selected-index behavior.

- [ ] **Step 1: Write the failing root-shell tests**

Cover the outgoing Android page set and assert the remote root is labeled `Computers`, Chat/Share/Settings remain reachable, navigation selection changes the body, and 130% text scale on a phone-width surface produces no layout exception.

- [ ] **Step 2: Run the tests to verify the current shell fails the new contract**

Run: `flutter test test/home_page_shell_test.dart`

Expected: FAIL on the current `Connection`/legacy bottom-navigation vocabulary or missing testable shell helper.

- [ ] **Step 3: Implement the root shell**

Wrap the mobile Home scaffold in `MirpgRemoteTheme`, present the remote page as `Computers`, and replace the legacy `BottomNavigationBar` with a Material `NavigationBar` without changing page construction, last-PC reconnect, chat unread handling, incoming/outgoing feature gates, or connection logic.

- [ ] **Step 4: Run root-shell and connection tests**

Run: `flutter test test/home_page_shell_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

Commit message: `feat: refresh MIRPG mobile root shell`

### Task 3: Redesign connected workspace navigation and header

**Files:**
- Modify: `flutter/lib/mobile/pages/target_dashboard_page.dart`
- Modify: `flutter/test/target_dashboard_test.dart`

**Interfaces:**
- Consumes: negotiated `hostManagement`, file permission, terminal feature, Codex feature, hostname, and `ffiModel.direct` state.
- Produces: connected labels `Overview`, `System`, `Files`, `Shell`, `Codex`; MIRPG scoped theme; a header that keeps hostname plus truthful `Connecting`/`Direct`/`Relay`; an overflow session menu with `App settings` and `End session`.

- [ ] **Step 1: Update widget tests first**

Change the current navigation tests to require `Overview` and `Shell`, retain dynamic capability omission/index behavior, and add a 130% text-scale compact-width case. Add a session-menu test that exposes `App settings` and `End session` without a second bottom-navigation surface.

- [ ] **Step 2: Run the target-dashboard tests to verify they fail**

Run: `flutter test test/target_dashboard_test.dart`

Expected: FAIL because the current labels are `Devices`/`PowerShell` and the explicit session menu is absent.

- [ ] **Step 3: Implement the connected shell**

Apply `MirpgRemoteTheme` around the connected workspace. Keep the private section/capability model, but present the fixed new labels and graphite/mint header/navigation styling. Replace the ambiguous leading close button with stable connected-workspace chrome. Add `App settings` by pushing the existing `SettingsPage`; add `End session` through the existing `clientClose(widget.ffi.sessionId, widget.ffi)` path.

- [ ] **Step 4: Run the target-dashboard tests**

Run: `flutter test test/target_dashboard_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

Commit message: `feat: unify connected PC workspace shell`

### Task 4: Make Back and return-to-Overview semantics explicit

**Files:**
- Modify: `flutter/lib/mobile/pages/target_dashboard_page.dart`
- Modify: `flutter/lib/mobile/widgets/monitor_control_view.dart` only if a label/affordance change is needed; do not change gesture math in P1.
- Modify: `flutter/test/target_dashboard_test.dart`
- Modify: `flutter/test/monitor_control_view_test.dart` only for shell/navigation wording.

**Interfaces:**
- Consumes: existing `_dashboard()`, `_releaseMonitor()`, guest `onReturn`, and chooser lifecycle.
- Produces: fullscreen Back/return always releases active input and lands on Overview; Overview-level system Back never calls the session-close path; only explicit `End session` ends the connection.

- [ ] **Step 1: Add failing navigation-state tests**

Pin these behaviors: returning from a selected target calls the Overview path without invoking End session; Overview Back is intercepted without session close; chooser dismissal does not change target; view-only remains non-interactive.

- [ ] **Step 2: Run focused dashboard/monitor tests**

Run: `flutter test test/target_dashboard_test.dart test/monitor_control_view_test.dart`

Expected: at least the new Overview-Back contract FAILS before implementation.

- [ ] **Step 3: Implement the Back contract**

Keep `_releaseMonitor()` ahead of target changes. Remove any Overview-level implicit pop that exposes the legacy remote canvas as if it were a disconnect/minimize action. Give the user an unobtrusive connected-session explanation when Back is pressed at Overview and keep `End session` as the explicit exit. Do not implement fake background minimization.

- [ ] **Step 4: Run focused dashboard/monitor tests**

Run: `flutter test test/target_dashboard_test.dart test/monitor_control_view_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

Commit message: `fix: make remote session exit semantics explicit`

### Task 5: Regression verification and Android artifact

**Files:**
- No feature expansion; only correct defects found by the checks below.

**Interfaces:**
- Consumes: final P1 Flutter change set.
- Produces: verified source plus a local Android test APK matching the updated source.

- [ ] **Step 1: Run focused Flutter regressions**

Run from `flutter/`:

`flutter test test/mirpg_remote_theme_test.dart test/home_page_shell_test.dart test/target_dashboard_test.dart test/monitor_control_view_test.dart test/emulator_model_test.dart test/codex_page_test.dart test/codex_model_test.dart`

Expected: PASS.

- [ ] **Step 2: Analyze touched Dart code**

Run `flutter analyze` on the touched/new mobile files and tests, using the repository's existing analyzer baseline. Correct new errors/warnings caused by P1; record unrelated pre-existing informational diagnostics separately.

- [ ] **Step 3: Inspect the diff against the P1 boundary**

Run `git diff --check` and inspect `git diff --stat` plus the actual diff. Confirm no Rust/protobuf/BlueStacks/security behavior changed and no existing connection/capability guard was bypassed.

- [ ] **Step 4: Build the Android test artifact**

Use the repository's existing MIRPG test-upgrade build path/signing identity already used by the live-dashboard work. Verify the APK build succeeds and record its path and SHA-256. Do not publish it or install it to a phone unless the current task separately authorizes that destination/action.

- [ ] **Step 5: Commit any verification-only corrections**

Use a narrow commit message describing the actual correction. Leave the branch locally reviewable; do not push as part of this plan unless separately authorized.

## Self-Review

- Spec coverage: P1 covers N01 and the P1 half of N19, plus S01/S03 shell vocabulary. Readable/minimap/precision, quality/reconnect, host security, and phone workspace are intentionally deferred to P2-P5.
- Step scan: each implementation step is limited to one shell behavior or verification action; protocol work is excluded.
- Type consistency: `MirpgRemoteTheme.build(ThemeData base)` is the only new cross-task interface. Existing `ConnectedPcTabBar`, session models, and `clientClose` remain the behavioral seams.
- Review Focus coverage: compact text/capability gating/session Back/explicit End/theme scoping each has an owning test or diff check above.
- Proportion: the plan records decisions and checks without transcribing widget implementations.
