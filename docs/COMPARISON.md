# JBar vs Spotlight — code & performance review

Head-to-head measurements taken **2026-08-19** on this Mac (MacBook Air, Apple M-series, 10 cores, 16 GB, macOS 26.5.2), *after* Spotlight had fully rebuilt its index (so this is Spotlight at its best, not mid-rebuild). Reproduce with:

```bash
make app && build/JBar.app/Contents/MacOS/JBar --benchmark 300
```

The harness ([`Benchmark.swift`](../Sources/JBar/CLI/Benchmark.swift)) times **JBar's own engine** and **Spotlight via `NSMetadataQuery`** in the same process, on the same queries, and compares coverage on a random sample of real files.

## Headline

| Metric | JBar | Spotlight | Notes |
|---|---:|---:|---|
| **Warm search latency (median)** | **1.5 ms** | 556 ms | JBar ≈ **360× faster** |
| Search latency (worst query) | 3.9 ms (p50), 10 ms (p95) | 3 004 ms (`x`) | Spotlight's single-char query takes 3 s |
| **Cold index build** | **2.5 s** (181 k files) | hours (full reindex) | one-time; JBar streams partial results in ~1 s |
| Warm start (typical launch) | **0.1–0.4 s** | n/a | loads its on-disk snapshot |
| **Resident memory** | **82 MB** warm / 122 MB peak crawl | mds/mds_stores 200–400 %+ CPU during reindex | see below |
| Coverage (random real files) | 92 % in top-50 (100 % indexed) | 100 % exact-name | different by design (see Coverage) |
| Ranking for launcher queries | apps-first, acronym/pinyin/frecency | opaque, file-name substring | see Ranking |
| Permissions required | none (no Accessibility/FDA) | system service | — |

## Latency, per query (300 warm iterations each)

```
query            matches   JBar p50  JBar p95  JBar max      Spotlight   top JBar result
vsc                10992    3.40 ms   3.60 ms   4.48 ms       480 ms      Visual Studio Code [app]
code               10290    3.91 ms   4.10 ms   4.35 ms      1217 ms      Visual Studio Code [app]
xc                  6821    1.31 ms   1.42 ms   1.52 ms       788 ms      Xcode [app]
chrome              1081    0.76 ms   0.78 ms   1.32 ms       141 ms      Google Chrome [app]
wx                  1594    0.35 ms   0.38 ms   0.43 ms       145 ms      WeChat [app]      (pinyin 微信)
term               10257    3.73 ms   3.97 ms   4.40 ms       364 ms      Terminal [app]
report              3400    1.53 ms   1.58 ms   2.77 ms       365 ms      reports [dir]
report pdf           196    0.19 ms   0.20 ms   0.21 ms       122 ms      report.pdf [file]
readme              3976    1.97 ms   2.09 ms   4.62 ms       816 ms      README.md [file]
index               1620    0.48 ms   0.51 ms   0.74 ms      1510 ms      Index [dir]
x                  19008    2.05 ms   2.38 ms  10.48 ms      3005 ms      Xcode [app]
```

Every JBar keystroke lands well inside one 60 fps frame (16 ms). Spotlight's `NSMetadataQuery` gathering scales with the number of matches — the high-frequency terms (`index`, `x`, `code`) cost 1–3 s.

Why JBar is fast: it holds a **flat, cache-linear index** in memory (parallel arrays + a lowercase UTF-8 name arena) and filters each keystroke with a **64-bit character-presence mask** before running the fuzzy scorer only on survivors. Spotlight round-trips to the `mds` daemon and returns *every* match unranked; the launcher UI then does its own (opaque) ranking on top.

## Coverage

The sample is 120 random real files drawn from JBar's index, so **JBar indexes 100 % of them by construction**. The interesting number is *retrieval*: does an exact-name search surface the specific file?

- **JBar: 92 % in the top 50.** The 8 % "misses" are common filenames with many copies (`index.js`, `__init__.py`, `package.json` appear hundreds of times) — they are indexed, just out-ranked by other files of the same name. A launcher deliberately shows the most-relevant top-K; you disambiguate by adding a path fragment (`report/index`).
- **Spotlight: 100 % exact-name** — because `mdfind` returns the *entire* unranked match set, so the target is always somewhere in it. That is not the same as surfacing it first.

The failure mode that motivated JBar is the opposite case: right after an unclean shutdown or an OS update, Spotlight's index is **incomplete for hours** (we measured 0 of 1,101 `~/Downloads` files indexed while it rebuilt). JBar owns its index and refreshes it in 2.5 s, so it never has that hole. See [`DIAGNOSIS.md`](DIAGNOSIS.md).

## Ranking

Spotlight's file-name predicate is a substring match with no launcher-oriented ranking exposed through `NSMetadataQuery`. JBar ranks for *launching*:

- **Apps first**, then files/folders; an exact app-name match always wins.
- **Acronyms**: `vsc` → Visual Studio Code, `gc` → Google Chrome, `xc` → Xcode.
- **Pinyin + CJK**: `wx` / `weixin` / `微信` → WeChat; `报告` finds Chinese-named PDFs.
- **Frecency + recency**: things you open often/recently rise; developer junk (`node_modules`, `.venv`, `vendor/`, build dirs) is de-ranked.
- **Type + multi-term**: `report pdf` puts `report.pdf` first and keeps non-PDFs out.

## Memory & CPU

- **JBar**: ~82 MB resident after a warm (snapshot) start; ~122 MB peak during the one-time cold crawl; **~0 idle CPU** (FSEvents-driven, no polling).
- **Spotlight**: the system service is "free" to the app, but its indexing is not free to the Mac — during a rebuild we measured `mds`/`mds_stores` at 160–400 % CPU for over an hour, and 34 GB of index writes in 31 minutes on a near-full disk. JBar's crawl is 2.5 s of bounded work and then quiet.

## What this review changed (performance work in this pass)

Measured before → after on the same machine:

| Improvement | Before | After |
|---|---:|---:|
| Cold index build (parallel per-root crawl across 10 cores) | 6.9 s | **2.5 s** (~2.7×) |
| Peak crawl memory (drain autorelease pool per directory) | 303 MB | **122 MB** (~2.5×) |
| Search latency | 1.5 ms | 1.5 ms (already optimal; unchanged) |

Correctness: two adversarial multi-agent review rounds. The first found and fixed 8 bugs (store-swap race, cache invalidation, cancelled-render, XDG path, login-item toggle, 3 crawler edge cases). The second — reviewing this pass's new concurrency code — found and fixed 3 more: the parallel item cap was enforced per-root instead of globally, the `hitItemCap` flag and `items` stat were mis-merged, and a path-depth computation was off by one for roots that are immediate children of `/`. The parallel-crawl merge (`IndexBuilder.append`) is covered by parity tests proving a merged store is equivalent to a serial one, with duplicate synthetic-parent roots deduped so incremental FSEvents updates stay correct.

One proposed optimization was **rejected on measurement**: lowering the search-parallelism threshold to spread ~10k-candidate warm scans across all cores looked good on paper but measured *slower* (thread-dispatch overhead exceeds the tiny per-candidate work), so the single-threaded-below-20k path was kept. 297 unit tests pass.

## Honest limitations

- JBar indexes **file/app names and metadata**, not file *contents* — Spotlight can search inside PDFs and documents; JBar (v1) cannot. It is a launcher, not a content search.
- JBar's index scope is the configured roots (home minus junk) — Spotlight indexes the whole Mac.
- The 92 % top-50 figure reflects the launcher's deliberate top-K cut, not missing data.
- Latency numbers are warm (index already in memory); the first query after launch, before the snapshot loads, is ~30–40 ms.
