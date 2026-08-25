# JBar Agent Guide

## Scope

- This repository is the native macOS JBar launcher, built with Swift Package Manager and AppKit.
- Preserve unrelated user changes in the dirty worktree. Never reset, revert, install, publish, or ship unless the user explicitly requests it.
- A question, review, diagnosis, or plan is read-only. Edit files only when the request clearly asks to build, fix, or change something.

## Implementation

- Keep launcher typing local. Codex work begins only after an explicit Return submission.
- Keep the Codex account isolated in JBar's `CODEX_HOME`; never add an API-key/provider fallback.
- Agent turns may write only inside this repository and run with network access disabled.
- Keep AppKit state on `MainActor`, bound streamed UI work, and stop child processes when their window closes.
- Prefer focused native code over new dependencies. Use `apply_patch` for hand-authored changes.

## Verification

- Run focused tests while iterating.
- Before handoff, run Debug and Release tests with `-Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete`.
- Build distributable-looking artifacts only in a temporary directory; do not replace `/Applications/JBar.app`.
