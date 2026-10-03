# JBar performance and CLI review — October 3, 2026

This pass audits filename/application search, scoring, history, snapshots, filesystem updates,
startup, UI delivery, and standalone agent use. It adds a native CLI and measured optimizations while
preserving local-only launcher typing, explicit Return submission for Codex, repository-only agent
writes, disabled agent network access, and the existing descriptor-based crawler protections.

The measured gains are strongest in repeated queries, word prefixes and snapshot processing.
Cold broad/acronym queries still show regressions in this local comparison. This is a substantial
optimization and CLI delivery pass, with explicit remaining work; it does not establish the fastest
Mac search product or full-content search capability.

## Findings and implemented changes

| Area | Finding | Change |
|---|---|---|
| Fuzzy matching | Contiguous word-start matches paid for general DP | An exact upper-bound shortcut returns the same score; mandatory literal constraints reject candidates before DP |
| Repeated queries | Candidate reuse still rescored and ranked all matches | Reuse a bounded stage-one pool within the same integer second; rebuild current history boosts, grouping and highlights |
| History | The same query was folded and locked once per retained result | Normalize and read the selected path once per rerank |
| Result capacity | Requests for 500 rows could stop at a 300-row reranking window | Expand the bounded window to the validated requested limit |
| Snapshot codec | Validation allocated one Swift String per indexed file | Validate strict UTF-8, components, suffixes and complete path budgets directly from bytes |
| Metadata updates | Generation/event-id changes rebuilt all character bitsets | Share the immutable payload and accelerators |
| App refresh | An unchanged catalog rebuilt every file array | Preserve the store generation and query caches when the catalog is unchanged |
| UI delivery | A stalled callback queue retained successive large generations | Coalesce pending store callbacks and deliver the newest generation |
| Freshness | Incremental merges reset the last-full-crawl timestamp | Preserve the original crawl time so scheduled full recrawls remain effective |
| Completeness | Denied/capped incremental directory crawls could be published as complete | Fall back to a full crawl that reports its actual coverage |
| Root discovery | Files and hidden names consumed the home directory's root allowance; truncation was invisible | Bound physical listing separately from qualifying roots, report incomplete discovery, and reject incomplete cache reuse/writes |
| Agent interface | Legacy headless mode loaded the app target, crawled on demand and printed diagnostics | Separate `jbar-cli` linked only to JBarCore; explicit indexing, saved snapshots and bounded JSONL serving |
| Directory browsing | A lookup could expand every indexed directory into a full path | Retain only the last matching directory IDs and stream existing index columns into bounded top-K results |
| CLI scope | Overlapping roots could duplicate entries or lose independent depth coverage | Reject overlapping roots explicitly; report missing roots and preserve the previous complete snapshot after an incomplete crawl |

The repeated-query cache stores candidates and match facts rather than finished responses. It
invalidates on store epoch, query semantics, weights, integer-second time boundaries, or insufficient
capacity. This keeps mutable history picks, recency thresholds, home display and result limits
correct. The default 40-row benchmark workload retains its original ordered results and totals.

The CLI uses independent scope/policy caches, reports snapshot age and coverage, and never silently
crawls during `search`. Directory browsing also uses the snapshot. It cannot escape the configured
scope by following a directory that was later replaced by a symlink. JSONL input is bounded; invalid
constraints are rejected. `serve` retains one index and engine, and rechecks age on each query.
Path boundary checks operate on UTF-8 bytes, including slash-adjacent combining marks. Directory
lookup has a regression fixture with a 3 KB root prefix and 10,000 directories so it cannot quietly
return to retaining expanded paths for the whole index.

## Index measurements

Release measurements on this Mac: Apple M4, 10 active processors, 16 GiB RAM, arm64,
macOS 26.6.2 (25G83), Swift 6.2.3. The deterministic index fixture has 1,000 directories and
25% Chinese filenames. Entries below are medians of five observations. They measure in-memory
serialization, decoding, merging and generation metadata updates; disk-cache coldness and whole-Mac
crawl time are separate workloads.

| Items | Operation | Before (ms) | After (ms) |
|---:|---|---:|---:|
| 100,000 | Snapshot encode | 23.09 | 1.89 |
| 100,000 | Snapshot decode | 25.24 | 4.78 |
| 100,000 | Store merge | 7.55 | 5.16 |
| 100,000 | Metadata generation update | 2.22 | 0.000959 |
| 1,000,000 | Snapshot encode | 237.40 | 17.98 |
| 1,000,000 | Snapshot decode | 301.12 | 89.96 |
| 1,000,000 | Store merge | 129.28 | 106.32 |
| 1,000,000 | Metadata generation update | 71.29 | 0.0015 |

Snapshot size is unchanged: 11,587,857 bytes at 100,000 items and 118,687,857 bytes at one million.
The metadata update becomes constant work because arrays and accelerators share their existing
storage. Its structural sharing is tested directly; the tiny measured latency is observational.
Raw logs are retained locally under `.build/performance/index*-{before,after}.log`.

Reproduce the codec workload:

```bash
JBAR_INDEX_BENCHMARK_ITEMS=1000000 swift test -c release \
  -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete \
  --filter IndexPerformanceTests
```

## Production search measurement method

The final comparison uses one independent process per binary at 300,000 and 1,000,000 deterministic
items, with 100 observations per query/sequence step. The baseline is the original clean checkout
at `c1000ba38dd137211ecf1d3a57121892f8be11f1`; the final executable is built in a fresh scratch
directory after tests. Both use production Release optimization with warnings as errors and complete
strict concurrency, without `-enable-testing`. Compiler and test processes are stopped before the
measurement sequence. The correctness comparison requires identical ordered rows, scores,
highlights, exact totals and workload/environment identity.

This is engine-cache coldness, not a rebooted/cold-VM filesystem or AppKit benchmark. Repeated-query
measurements use the deterministic reference time so history and recency stay comparable; real
stage-one reuse is restricted to the same integer-second bucket. Corpus construction uses analyzed
synthetic names rather than crawling real files. The CLI benchmark below supplies a separate real
filesystem workload.

Raw search logs/reports are `.build/performance-review/production-{before,after}-{300000,1000000}.{log,json}`;
validated comparisons are `production-comparison-{300000,1000000}.json`. Binary SHA-256 values:

- Baseline: `9d277cb5d3087cc3b51e8acd82674b009e19eb410e973561e41e92d324da9fc8`
- Final JBar: `5b7052512bed9728d4ce9ab978a4b2b527d3f36aafdd5f58c023f49fc3b7da4f`

### Search results

At one million items, timings in milliseconds:

| Workload/query | Before p50 | After p50 | Before p95 | After p95 | After p99 |
|---|---:|---:|---:|---:|---:|
| Cold `x` | 30.745 | 33.625 | 31.786 | 34.934 | 36.176 |
| Cold `chrome` | 13.964 | 7.257 | 14.575 | 7.942 | 8.389 |
| Cold `vsc` | 17.031 | 18.158 | 17.541 | 20.056 | 22.060 |
| Cold `report pdf` | 26.533 | 20.814 | 33.269 | 23.354 | 25.266 |
| Cold `.pdf` | 3.896 | 4.039 | 4.368 | 4.620 | 4.713 |
| Repeated `x` | 27.754 | 0.326 | 31.195 | 0.343 | 0.399 |
| Repeated `chrome` | 10.748 | 0.398 | 11.539 | 0.422 | 0.430 |
| Repeated `vsc` | 9.405 | 0.399 | 10.242 | 0.428 | 0.480 |
| Repeated `report pdf` | 10.435 | 0.337 | 10.992 | 0.355 | 0.409 |
| Repeated `.pdf` | 3.903 | 0.258 | 4.042 | 0.265 | 0.304 |

The broad repeated query is about 85× faster; cold `chrome` is about 48% faster. At 300,000 items,
cold `chrome` improves from 3.537 to 1.804 ms and repeated `x` from 8.747 to 0.325 ms. The stage-one
pool also accelerates repeated extension queries; the benchmark's candidate-mask cache description
refers to the separate normal-query mask cache.

Regressions remain visible: cold `x` p50 increases 15.2% at 300,000 items and 9.4% at one million;
one-million cold `vsc` increases 6.6% and `.pdf` 3.7%. The worst one-million typing step (`r` in the
multi-term sequence) increases 26.8%, and the worst deletion step (`report pd`) 15.7%. These are
per-step regressions, not a claim about whole-sequence UI latency. A trial one-byte inline scorer
showed no gain and was removed. There is no demonstrated cause for the residual broad-query cost;
it remains the first profiling priority. Query supersession's newest `chrome` p50 improves 46.3% at
one million items, with every older request cancelled and no newest request cancelled.

Fixture construction is effectively unchanged: 1.217 → 1.211 seconds at 300,000 items and
4.035 → 4.093 seconds at one million. Process RSS is observational and allocator-dependent;
the report retains both build-time and final RSS, rather than treating them as an index memory bound.

### Standalone CLI results

The final Universal 2 CLI uses 10,000 actual empty regular files distributed across 100 directories,
100 samples per search mode, and an independent private snapshot. Indexing takes 89.80 ms wall time
(79.47 ms command startup/build/persistence work), about 111,357 generated files/second. The snapshot
contains 10,101 items including directories and occupies 974,121 bytes. This is a generated filename
workload with warm filesystem caches, not a whole-Mac ingestion estimate.

| Request path | p50 (ms) | p95 (ms) | p99 (ms) | Max (ms) |
|---|---:|---:|---:|---:|
| One-shot process + snapshot + search | 7.106 | 7.831 | 9.068 | 9.492 |
| Persistent stdio filename round trip | 0.394 | 0.435 | 0.494 | 0.495 |
| Persistent snapshot directory round trip | 0.253 | 0.270 | 0.309 | 0.335 |

The persistent process is ready in 5.42 ms; its first filename request takes 1.06 ms. Every one-shot
and served filename response preserves the same ordered rows and exact 2,500 matches. The 500-row
request returns 500 rows, and the snapshot directory query reports all 100 expected direct children.
Raw samples and provenance are in `.build/performance-review/cli-benchmark-final/report.json`.
CLI binary SHA-256: `51071b0c217e37c0603b67c0c60c80464e1fa086b2f9f12e3ca2037d0e1335fa`.

## Reproduce search and CLI evidence

The existing search benchmark reports caller-observed nearest-rank p50/p95/p99/max, with exact
ordered-row validation across cold, repeated, typing, deletion and supersession workloads. The new
comparison tool rejects changed corpus, history, configuration, environment, scores, highlights or
totals before reporting timing differences:

```bash
scripts/compare-benchmarks.rb /absolute/before.json /absolute/after.json
```

The standalone benchmark creates actual empty regular files under a new temporary directory,
measures indexing and snapshot size, then separates one-shot process latency from persistent stdio
requests. Every response must retain the same ordered results and exact expected total:

```bash
python3 scripts/benchmark-cli.py --binary /absolute/path/to/jbar-cli \
  --output-dir /absolute/path/to/a/new/temporary-directory --items 10000 --samples 100
```

The full publication campaign remains `scripts/benchmark-release.sh 100`: three independent
processes at 300,000 / 500,000 / 1,000,000 items. Local comparisons from this development session are
not a claim that JBar is the fastest search product across all Mac hardware or workloads.

Rebuild the measured executable with `swift build -c release --product JBar` after running Release
tests. A `swift test -c release` build enables testability and exports otherwise internal symbols;
this can change optimizer behavior even though both binaries report Release mode. Compare matching
production build commands and record binary hashes. An initial testability-mismatched comparison
from this session is retained for diagnosis and excluded from the final performance conclusions.

## Verification and delivery

The initial performance pass passed **695 tests in Debug and 695 in Release**, each with zero failures and three
opt-in skips, using `-Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete`. Skips are the
external Codex/OAuth integration, the separately measured index benchmark, and the isolated path
benchmark. IP network access was denied during verification; local Unix sockets remained available
for the existing special-file safety test. Logs are `.build/performance-review/{debug,release}-tests-verified.log`.

Ruby benchmark gates/comparison tests, shell/Python syntax, CI YAML parsing and `git diff --check`
pass. The CLI benchmark watchdog was also checked against a process that stalls after a partial JSON
reply: it times out and reaps its child. CI now exercises indexing, one-shot search, 500-row capacity,
snapshot directory queries and stdio requests against the staged standalone binary.

That pass produced a Universal 2 CLI archive for macOS 13+, containing `bin/jbar-cli`, its usage guide
and LICENSE, with a SHA-256 sidecar. Packaging checks both architectures, version alignment, an ad-hoc
signature and absence of a direct AppKit dependency. At that checkpoint it was a local, unnotarized
candidate, with Intel code cross-built and runtime verification on this Apple silicon Mac. The
installed launcher was untouched. The subsequent 0.2.0 code/safety review and authorized release
update are documented in [the safety review](SAFETY-REVIEW-2026-10-03.md).

Candidate: `.build/performance-review/cli-distribution-final/JBar-CLI-0.1.0-universal.tar.gz`.
Archive SHA-256: `ccdf87f6b74d852239d03ab616e3d82db05b5b4bd2d35799a086495ba504d8be`.
The archive was extracted into a fresh directory, its guide and signature verified, and its included
binary passed the 2,000-file/three-sample CLI smoke, including an actual 500-row result.
`.build/performance-review/production-manifest.json` records source/artifact hashes, build flags,
verification counts and benchmark provenance. See [CLI usage](CLI.md) and [release preparation](RELEASING.md).

### 0.2.0 safety-reviewed remeasurement

The fresh production 0.2.0 app also passed the one-million-item, 100-sample engine comparison
against the same original baseline: ordered rows, highlights, scores and exact totals were identical.
Cold p50 was 31.253 ms for `x`, 6.956 ms for `chrome`, 16.686 ms for `vsc`, 17.169 ms for `report pdf`
and 3.700 ms for `.pdf`. Repeated p50 was 0.327 / 0.399 / 0.396 / 0.334 / 0.258 ms respectively.
The broad repeated query remains about 85 times faster. Cold `x` remains 1.7% slower than baseline;
other cold results in this run improve. The differing cold observations across the two production
runs illustrate measurement variability; no causal speedup is attributed to the safety fixes.

Raw report and gated comparison: `.build/release-review/production-{after,comparison}-1000000.json`.
App binary SHA-256: `f01a18da7fbff43348b3f9ea020c1949e95fcb45cec61f23172f44201ca3a099`.

The fresh production Universal 2 candidate passed the same 10,000-file, 100-sample CLI workload
after the scope and cache-safety fixes. Indexing took 84.70 ms wall time, with 10,101 indexed items
and a 974,117-byte snapshot. One-shot p50/p95/p99 was 6.738 / 7.527 / 8.199 ms; persistent filename
round trips were 0.370 / 0.431 / 0.492 ms; directory round trips were 0.239 / 0.269 / 0.305 ms.
The process was ready in 5.683 ms and its first filename query took 1.094 ms. Ordered rows, exact
totals, directory coverage and the actual 500-row response all passed. These are separate observations
with warm generated fixtures, not a controlled claim that the safety changes improved performance.

Evidence: `.build/release-review/cli-benchmark-0-2-0/report.json`.
CLI binary SHA-256: `25630b877080487f5cb2dee2c182466cf0e8d9fcd2d8b3a586e9c05b08e74984`.
The safety-reviewed source passed 714 tests in each strict Debug/Release suite, with three skips,
plus all 24 npm tests and the isolated prebuilt installer fault/race suite.

## Remaining work, in priority order

1. **Cold broad queries and traversal.** Profile the first broad letter, DP-heavy noncontiguous
   terms, single large roots and partial crawl publications. Publications still rebuild bitsets and
   can trigger builder copy-on-write. Validate worker-count tuning on Intel and lower-core Macs.
2. **Startup and memory.** Separate cold filesystem reads from decode/accelerator building and app
   refresh; measure allocator peak RSS and energy. Snapshot loading currently copies bytes into
   arrays. Memory mapping would need a versioned format and rigorous lifetime/bounds validation.
3. **UI latency.** Record hotkey-to-visible and key-to-painted-results with real AppKit runs. Engine
   timings exclude rendering, event-loop contention and input-method composition.
4. **CLI freshness.** Add an opt-in watcher or explicit refresh protocol with immutable generation
   handoff. This version deliberately exposes a saved, non-watching snapshot; agents must reindex
   and restart serving for fresh filesystem state.
5. **Content capability.** Add an opt-in durable inverted content index with bounded extraction,
   privacy controls, Unicode/phrase correctness and separate ingestion/energy benchmarks. Keep it
   out of the filename keystroke path. The current engine and CLI search names and paths, not bodies,
   PDF text, OCR or semantic embeddings.
6. **Comparative evidence and distribution.** Use equivalent roots, corpus membership, freshness
   and query semantics before comparing Spotlight or another product. The 0.2.0 CI adds mandatory
   Intel CLI runtime checks and a reviewed GitHub asset path; notarization and broader comparative
   measurements remain prerequisites for wider public performance claims.

The existing Spotlight reference has different filename-substring semantics and system-service
costs. Its timing cannot be used as a JBar speedup ratio. Faster incomplete results also do not count
as a performance improvement.
