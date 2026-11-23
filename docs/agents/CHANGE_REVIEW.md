# RustDesk - Change Hygiene and Review Guidance

These rules apply when editing production code or reviewing changes. Prefer conservative, minimal changes; an explicitly requested redesign or architectural improvement can justify a scoped refactor instead of forced duplication. The root AGENTS.md scope and user task take precedence where guidance conflicts.

## Editing Hygiene

* Change only what is required.
* Prefer the smallest valid diff.
* Do not refactor unrelated code.
* Do not make formatting-only changes.
* Keep naming/style consistent with nearby code.

### Imports

* One `use` per crate. Everything a file takes from the same crate goes in a
  single braced block, not one statement per item:

  ```rust
  // no
  use base::fs;
  use base::message_proto::*;

  // yes
  use base::{fs, message_proto::*};
  ```

* The only reason to split is a `#[cfg(...)]` that does not apply to the whole
  block -- an attribute binds to one item, so a differently-gated import has to
  stand on its own. A `pub use` re-export likewise cannot join a plain `use`.

  ```rust
  #[cfg(not(feature = "flutter"))]
  use base::fs;
  use base::message_proto::*;
  ```

* When splitting an existing `use` because some of its items moved to another
  crate, fold each side into that crate's existing block rather than leaving a
  second statement behind.

### Comments

* Avoid comments unless they explain a non-obvious reason, constraint, or workaround.
* Never restate what the code does; prefer clearer code instead.
* If the code is self-explanatory, add no comment.

### Be minimally invasive

* Prefer purely additive changes: layer new (`#[cfg]`-gated) blocks or new functions around existing code instead of restructuring it. The ideal diff for a fix adds lines and modifies/deletes none.
* Do not extract or reshape existing code just to enable your new code; look for a mechanism that leaves existing lines untouched (e.g. hide/show an existing object instead of refactoring its construction into a helper for rebuilding).
* Accept a little duplication over a restructure. A new function that repeats a few lines of an existing one is a better diff than reshaping the original so both can share it.
* Put new logic in self-contained functions in the module it belongs to (platform-specific logic in `src/platform/`, with `use` inside the function body to avoid churning shared import blocks). Call sites in shared files (`src/tray.rs`, `src/core_main.rs`, `src/server/connection.rs`, …) should be thin one-line hooks.

### Scope check before touching shared code

* Before changing a shared trait, a shared struct, or the signature of a widely used function, check whether the bug or feature is specific to one path. If it is, keep the change inside that path unless that is impossible, and say in the PR why it was.
* If an unrelated caller needs `Default::default()`, `None`, or another placeholder solely to satisfy a signature you changed, the diff is too broad: stop and redesign.
* The expected shape of a fix is a new function in the feature's own module, plus at most a new field or a thin hook in the shared code it needs. Feature-specific state belongs beside the feature's existing state, not in a new abstraction every caller has to learn.

### Mandatory regression-surface check

Before considering any implementation complete, perform a minimization pass over the final diff.

* Inspect every modified existing file and every modified existing code path. Each must be strictly necessary for the requested change. Revert changes that are merely cleanup, refactoring, consistency improvements, or fixes for pre-existing issues.
* For new features, preserve the existing implementation path when the feature is disabled or unsupported whenever practical. `feature off` should run the old code, not a rewritten equivalent.
* Do not route existing behavior through a new abstraction merely to share code with the new feature. Prefer a parallel new function or a small amount of duplication over changing a proven existing path.
* Keep new implementation logic in new or feature-specific modules. Changes to shared/core files should normally be thin hooks, capability checks, or protocol plumbing.
* Do not fix unrelated pre-existing bugs in the same PR. Put them in a separate change unless they directly block correctness or security of the requested work.
* For submodule bumps, inspect the exact commit range and ensure unrelated changes are not being pulled into the parent PR.
* Before finalizing, explicitly report the regression surface: list the existing files and existing runtime paths whose behavior changed, and explain why each change is unavoidable.
* During review, treat an unnecessarily modified legacy path as a review finding even if tests pass and the rewritten behavior appears equivalent.

### Corner cases raised in review

A refactor added to cover a corner case rarely converges. Each new counter, timestamp, cache or eviction/expiry rule interacts with state that existing code relies on, and the next review round finds the problems it introduced.

* A corner case is still worth fixing when the fix is easy and low-risk: a local change of a few lines that adds no state and changes no existing lookup, such as moving a check or refusing bad input earlier.
* When the only fix needs new state, a new lifecycle rule or a restructure, and the code already fails cleanly there or behaves as master does, document it as a known limit in the PR instead. Anything beyond the easy fix needs the maintainer's explicit go-ahead first.
* Before adding state that reorders, expires or reuses existing data, list every lookup that reads that data and check each one still holds.
* Prefer a clean failure, where the operation reports an error, over machinery that tries to make a rare case succeed.
* A severity label from any reviewer (P1, Critical, Major) is not a triage result. Apply the next rule by consequence, not by label.
* A corner case whose fix needs new state is fixed only when it crashes, loses data, weakens security, or a user has reported it. A rare cosmetic or layout glitch (e.g. rotation during an active drag, a feature that is off by default) is a known limit: reply once, list it under "Known limits" in the PR body, and leave the code alone.
* When a finding is about behavior an earlier commit of this same PR introduced, fix it by removing or simplifying that commit, not by adding a layer on top.
* Judge growth across all rounds, not per round. If review follow-ups have grown the non-test diff by more than half of the first fix, or added a new kind of state (handles into another component, cross-component references, deferred / post-frame callbacks, timers, caches, flags), stop and ask the maintainer before pushing.
* When keeping the user's preferred state is hard in a rare case, fall back to a deterministic default computed from the current inputs. Do not coordinate mutable state across components or frames to preserve the preference.

## Tests

* A fix gets regression tests for the reported behavior only: they fail on master and pass with the fix. One to three tests is normal.
* Assert what the user sees or what the API returns. Do not test private state, the order an algorithm runs its steps in, or each corner case raised in review.
* Do not add test infrastructure (browser runners, golden/screenshot harnesses, new mock layers, test-only hooks in production code) for a bug fix unless the maintainer asks.
* If the test diff is more than twice the fix, cut it back to the tests that pin the reported behavior. A state that needs long setup to reach is usually too rare to fix.
* When the number of tests needed to describe the behavior keeps growing, the implementation is too complex: simplify it instead of adding tests.

## Reviewing a PR

* Review only what the diff introduces. Verify ownership with `gh pr diff` before reporting a finding — if the offending lines are untouched context, it is a pre-existing problem, not this PR's.
* List pre-existing problems in a separate section at the end, or leave out the ones that are not fatal. Never mix them into the findings the author has to fix.
* Before re-reviewing, read the author's reply comments. Do not re-raise items they declined on scope grounds.
* State a finding's consequence exactly: distinguish "the value is lost" from "the shortcut is inert but the value still saves".
* Do not report a rare corner case as blocking when fixing it needs new state; mark it as a known limit the author may leave unfixed.
* Treat growth across review rounds as a finding: if the latest commits add more state than the original fix, say so instead of asking for more handling.

