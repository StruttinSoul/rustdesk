# BlueStacks 5 clean gaming implementation plan

Spec: `docs/superpowers/specs/2026-10-01-bluestacks-clean-gaming-design.md`

## Task 1 — Provider and inventory foundation

Interfaces produced: `BlueStacksProvider`, `BlueStacksInventory`, current-release config parser/editor helpers, instance/process normalization.

1. Add failing unit tests for config parsing, instance enumeration, Android-version mapping, process command-line matching, and direct-launch arguments.
2. Implement registry/install/config discovery and the `EmulatorProvider` adapter.
3. Add a read-only ignored local smoke test for the installed BlueStacks.
4. Run focused Rust tests and commit.

## Task 2 — Cleanup, components, Android packages, restore

Interfaces produced: `CleanupProfile`, `CleanupSelection`, `CleanupJournal`, component/package classification, apply/restore/set-default/launch actions.

1. Add failing tests for Standard/Clean Gaming selections, current-key guarding, idempotent journal behavior, restore conflict protection, component classification, package protection, and action rejection for protected packages.
2. Implement reversible config/startup/shortcut changes, journal persistence, update fingerprinting, optional component metadata, ADB package inventory/disable/restore, and per-instance default app state.
3. Run focused Rust tests and commit.

## Task 3 — Flutter bridge

Interfaces produced: `mainGetCommon("bluestacks-inventory")`, `mainSetCommon("bluestacks-action", json)`.

1. Add tests around serialization/action parsing in the Rust module.
2. Wire inventory and actions through the existing bridge with Windows-only guards and structured error results.
3. Run focused Rust tests and commit.

## Task 4 — Windows BlueStacks Settings UI

Interfaces produced: `BlueStacksModel` and a Windows-only BlueStacks Settings tab.

1. Add failing Dart tests for inventory decoding and profile/custom-selection behavior.
2. Implement Installation, Instances, Startup, Optional Components, Android Apps, Cleanup, and Advanced sections.
3. Add explicit confirmation for component/package uninstall actions; profile apply remains reversible and excludes uninstalls.
4. Run Flutter tests/analyze for touched code and commit.

## Task 5 — Verification and review

1. Run the complete relevant Rust test suite plus the ignored read-only BlueStacks discovery smoke.
2. Run Flutter tests/analyze.
3. Review the branch against the spec, fix Important/Critical findings with RED→GREEN tests, and record any deferred minor issues.
4. Leave the branch local; do not push, merge, release, or publish.

## Review focus

- A BlueStacks update that removes or renames a config key must not cause a guessed write.
- Restore must not overwrite a value the user manually changed after cleanup.
- Unknown/unclassified Android packages must never be disabled or uninstalled by profile cleanup.
- BlueStacks X/BlueAI removal must never occur through profile apply.
- ADB use must stay local to the discovered instance endpoint and must not be enabled automatically.
