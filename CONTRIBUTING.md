# Contributing to JBar

Thanks for taking a look. JBar is a small, dependency-free Swift package — everything
below runs with the stock Xcode toolchain.

## Getting started

```bash
git clone https://github.com/linjiw/jbar.git
cd jbar
make test      # 297 unit tests, ~45 s
make install   # build JBar.app and install it to /Applications
```

## Ground rules

- **No third-party dependencies.** System frameworks only (AppKit, Carbon, CoreServices,
  ServiceManagement, Foundation, os). This keeps the app small, fast to build, and free of
  supply-chain risk.
- **`JBarCore` stays UI-free.** All indexing, matching and ranking logic lives in `JBarCore`
  with no AppKit import, so it is unit-testable. `JBar` is the thin AppKit shell.
- **Tests come with the change.** `JBarCore` sits at 90 %+ line coverage; new logic needs
  tests, and ranking changes need a golden test that pins the expected order.
- **Measure performance claims.** `JBar --benchmark` and `JBar --bench-index` produce the
  numbers in `docs/COMPARISON.md`. If you change the crawler or the search hot path, include
  before/after numbers from your own machine — a change that looks faster on paper and
  slower on a real index does not land (this has already happened once; see the
  "rejected on measurement" note in `docs/COMPARISON.md`).
- **Ranking weights live in one place.** `RankingWeights` in `Sources/JBarCore/Match/Ranking.swift`.
  Don't scatter magic numbers through the scorer.

## Useful commands

| command | what it does |
|---|---|
| `make build` / `make test` | debug build / unit tests |
| `make test-release` | tests with optimization (enforces the perf budgets) |
| `make app` | assemble a signed `build/JBar.app` |
| `make cli Q="visual studio"` | headless search, prints ranked rows and timings |
| `make bench` | headless index benchmark (items, time, RSS) |
| `build/JBar.app/Contents/MacOS/JBar --benchmark` | head-to-head vs Spotlight |

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
