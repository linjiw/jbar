# Contributing to JBar

Thanks for taking a look. JBar is a small, dependency-free Swift package — everything
below runs with the stock Xcode toolchain.

## Getting started

```bash
git clone https://github.com/linjiw/jbar.git
cd jbar
make test      # debug test suite; count and duration vary by commit/machine
make install   # build JBar.app and install it to /Applications
```

## Ground rules

- **No third-party dependencies.** System frameworks only (AppKit, Carbon, CoreServices,
  ServiceManagement, Foundation, os). This keeps the app small, fast to build, and free of
  supply-chain risk.
- **Three targets.** `JBarCore` holds all indexing, matching and ranking logic with no AppKit import.
  `JBarApp` is the AppKit layer — a *library* so tests can `@testable import` it (an executable target
  cannot be imported, which is why the UI once had zero coverage). `JBar` is a three-line executable
  shim that calls `runJBar()`.
- **UI logic belongs in testable helpers.** Panel geometry, row modelling, badges and Tab autocomplete
  are static functions covered by `Tests/JBarAppTests`; keep new UI decisions out of view callbacks so
  they can be tested headlessly. `docs/UX-TESTS.md` is the manual checklist for what cannot be.
- **Keep automated UI and architecture evidence in scope.** The packaged-clone AppKit smoke drives
  synthetic Control, text, Delete, Down, and Return events through a real `NSApplication`, but opens
  only an in-memory fixture through a recording workspace. It does not prove a physical keyboard or
  IME, LaunchServices, Gatekeeper, or notarization. Likewise, two `lipo` slices plus a macOS 13 minimum
  version prove bundle structure, not native Intel UI behavior. A compatibility job on a native
  x86_64 runner proves only the exact packaged synthetic path exercised there; retain the physical
  keyboard/IME and clean-machine matrix in `docs/SUPPORT.md` and `docs/UX-TESTS.md`.
- **Tests come with the change.** New logic needs focused regression tests, and ranking changes need
  a golden test that pins the expected order. Run both debug and release suites; do not copy a test
  count or coverage percentage into documentation unless the exact commit/report is attached.
- **Coverage is target-scoped.** CI enforces at least 95% line and 90% function coverage for
  `JBarCore`. It reports `JBarApp` separately and never combines the two percentages. The gate is a
  regression floor, not permission to omit focused AppKit tests or the physical UX matrix.
- **Measure performance claims.** Use `scripts/benchmark-release.sh` and the isolated workloads
  described in `docs/COMPARISON.md`. If you change the crawler or search hot path, include complete
  before/after distributions from the same recorded environment, retain high-tail outliers, and attach
  the source, binary, harness, report-gate, workload/corpus/history, and final evidence-manifest
  identities. Label dirty-working-tree evidence as such; it is not a notarized artifact or a
  cross-machine SLA. Keep JBar fuzzy-ranking and Spotlight filename-substring results separate; their
  different semantics do not support a speed or recall ratio.
- **Ranking weights live in one place.** `RankingWeights` in `Sources/JBarCore/Match/Ranking.swift`.
  Don't scatter magic numbers through the scorer.

## Useful commands

| command | what it does |
|---|---|
| `make build` / `make test` | debug build / unit tests |
| `make test-release` | optimized tests, including bounded-work and catastrophic-regression ceilings; not a benchmark or SLA |
| `make app` | assemble the default ad-hoc signed Universal 2 `build/JBar.app`; this is not a public release |
| `make cli Q="visual studio"` | headless search, prints ranked rows and timings |
| `make bench` | headless index benchmark (items, time, RSS) |
| `scripts/benchmark-release.sh 100` | schema-v1/workload-v2 fixed-seed release evidence; three independent processes per 300k/500k/1M size by default |
| `JBAR_BENCHMARK_INCLUDE_REAL=1 scripts/benchmark-release.sh 100` | add one isolated real crawl and same-root Spotlight semantic reference; no cross-tool ratio |
| `scripts/tests/appkit-smoke.sh /absolute/path/JBar.app` | synthetic packaged-clone lifecycle/event smoke with a recording workspace; pass a new absolute second argument to retain evidence |
| `ruby scripts/tests/coverage-gate.rb <JBar.json>` | validate LLVM coverage and enforce the JBarCore-only line/function floors |

## Architecture

Read [`docs/DESIGN.md`](docs/DESIGN.md) first — it covers the data model (flat parallel arrays
plus a UTF-8 name arena), the fzf-style scorer, the crawl/FSEvents pipeline, and the ranking
signals. [`docs/DIAGNOSIS.md`](docs/DIAGNOSIS.md) explains why the project owns its index
instead of querying Spotlight.

## Reporting bugs

Include your macOS version, `sw_vers`, whether the index had finished building (the menu-bar
item shows its status), and any relevant lines from:

```bash
log show --last 10m --predicate 'subsystem == "com.linji.jbar"' --style compact
```
