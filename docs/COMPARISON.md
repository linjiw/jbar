# JBar and Spotlight: scope and measurement notes

JBar and Spotlight do different work, so their timings must not be turned into a speedup ratio. JBar performs fuzzy filename/application-alias ranking over its configured, exclusion-filtered in-memory index. Spotlight's benchmark reference performs case/diacritic-insensitive filename-substring metadata queries over the existing portions of the same configured roots. Spotlight also indexes content and system-wide metadata that JBar does not.

This document records current evidence without converting a development-machine observation into a product guarantee.

## Reproduce the benchmark

Use an optimized build and keep other disk-intensive work idle:

```bash
# Fixed-seed 300k, 500k, and 1M fixtures; three sequential processes per size.
scripts/benchmark-release.sh 100

# Also add one isolated real cold crawl and same-root Spotlight reference.
JBAR_BENCHMARK_INCLUDE_REAL=1 scripts/benchmark-release.sh 100
```

The script and `--benchmark` implementation:

- build one optimized binary from a frozen source manifest, then verify that binary and the benchmark
  tooling identities before and after every process;
- print Swift, OS, hardware, architecture, report/workload/generator versions, fixed seed, corpus and
  history fingerprints, and actual sample counts;
- run three sequential, independent processes for each synthetic size by default so process state does
  not accumulate across corpora or repeats;
- use an isolated temporary snapshot for a real crawl and delete it afterward, without reading, replacing, or deleting JBar's production snapshot;
- separate engine-cache-cold scans, repeated identical queries, typing, deletion/backspace, and rapid supersession;
- require every response expected to complete to match complete ordered result rows and its exact
  total across every workload, separately require deliberately superseded older requests to cancel,
  and use fingerprints only as report identities;
- report caller-observed wall-time distributions with nearest-rank p50/p95/p99/max and no best-of-N selection;
- cap expensive cache-cold candidate scans at 100 samples and Spotlight gathers at 5 samples, while printing those actual counts;
- scope Spotlight to existing minimal roots derived from JBar's configured file/app roots;
- keep Spotlight timeouts, exact misses, and ranking misses separate; and
- write status files and a self-verifying SHA-256 manifest to a private evidence directory.

“Engine-cache cold” means JBar's candidate cache is cleared before a sample. It does **not** mean the filesystem, VM page cache, CPU cache, or Spotlight service is cold. A publication-quality result must record machine load and repeat runs. Even though the default invocation includes independent processes, one machine and one local session remain local evidence rather than a support-wide result.

## Evidence currently recorded

The current PASS bundle is local at
`/private/tmp/jbar-benchmark-evidence.lf1nUyeT`. It was generated at 2026-08-21T00:20:08Z on a
Mac16,12 with an Apple M4, 10 active processors, 16 GiB physical memory, arm64, and macOS 26.5.2
(25F84), using Xcode 26.2 (17C52) and Swift 6.2.3. This is an optimized development binary from the
**clean candidate commit** `183fc3c2e526e21dccc7976203e5f00ba371426c`; it is not a
signed/notarized release artifact.

| Evidence identity | Recorded value |
|---|---|
| report / workload / fixture generator | schema v1 / workload v2 / generator v2 |
| release-mode binary SHA-256, unchanged before/after | `ec4496606f09e30f3ac5ea65b8fcdd16a7c77d8e21b1402f508b73d93356654f` |
| `scripts/benchmark-release.sh` SHA-256 | `13cd7e53b116bf939fe51b895cffd4c3c94022be9b7d3808f88a98499fe30842` |
| `benchmark-report-gate.rb` SHA-256 | `6c0436e2a15241d5679a4560e370ae3018b4d6851241f642ecaa13b2141fe6e7` |
| source-manifest file SHA-256, identical before/after | `7da3d07f27a0da2b128c3acc38876fcf8f5136b9a9626e246ee878a0915fdead` |
| tooling-manifest file SHA-256, identical before/after | `7b78ccb538ef93e6cc237b1069a37f8d2946a18154b911fbd102499058c8590f` |
| final `SHA256SUMS` SHA-256 | `7a64cb87f45e11a04b116be1a05c78e6da3077e9cf5f422fcd23a86c070de6ab` |

All nine synthetic executions exited successfully, their report gates and repeat-identity checks
returned zero, the scratch directory was removed, and the terminal result was `PASS` with the
checksum manifest verified. The run plan explicitly recorded `includeIsolatedRealCrawl=0`.

The synthetic reports used built-in defaults and deterministic in-memory production-stage-2
frecency; they did not load or save the user's history. The gate required all three reports at each
size to have the same schema, workload, configuration, corpus, and history identity:

| Items | corpus fingerprint | history fingerprint | repeat identity SHA-256 |
|---:|---|---|---|
| 300,000 | `0x1463216a6781e9af` | `0x1fa912e577fd57bf` | `22a0cb0b85f695a569bf8e127fb39870f6080240a63d80172e2404f9c27fef59` |
| 500,000 | `0x70afa87226f03302` | `0x8f41d00c4da09fa9` | `2b41ec0cb30bd3291622c4e0321a7176b8c846a9f10776a1d3f4d4c4a6b8697d` |
| 1,000,000 | `0xb1233b6118c6d7fa` | `0x43cefa0d337f665d` | `708e0ac80646565b768b703b7250af97eb60ac9271f2f1c0c3667b49c5aaa95c` |

### Deterministic synthetic results

Each entry below is the range of the corresponding **process-level** statistic across three
sequential independent processes, with 100 observations in each process. `typing r` is the first
step of the `common→selective` typing sequence. The last number is the worst maximum across the three
processes, not a range.

| Items | engine-cache-cold `x`: p50 / p95 / p99 / worst max (ms) | typing `r`: p50 / p95 / p99 / worst max (ms) | supersession newest `chrome`: p50 / p95 / p99 / worst max (ms) |
|---:|---:|---:|---:|
| 300,000 | 43.689–55.232 / 49.349–57.592 / 49.470–59.391 / 59.413 | 71.341–84.240 / 76.207–92.882 / 77.723–98.259 / 100.719 | 13.419–14.085 / 14.770–16.891 / 14.867–17.316 / 23.740 |
| 500,000 | 90.123–90.996 / 96.980–97.031 / 98.619–98.682 / 99.343 | 132.956–143.578 / 148.162–156.551 / 156.403–172.096 / 181.244 | 22.625–24.058 / 25.698–27.505 / 26.353–28.802 / 29.407 |
| 1,000,000 | 171.521–181.592 / 178.376–188.499 / 179.651–189.826 / 193.135 | 251.063–269.888 / 268.004–291.179 / 270.453–306.044 / 320.136 | 40.284–45.404 / 47.079–50.047 / 48.457–52.138 / 53.612 |

For **each** size, all 300 older superseded scans cancelled as intended and zero of the 300 newest
scans cancelled unexpectedly. High-tail samples are deliberately preserved rather than discarded
through best-of-N selection.

### Real-corpus status

The current formal campaign did not enable the opt-in real crawl or Spotlight reference. Results
from an older binary are intentionally omitted: they cannot be promoted to current-candidate or
release evidence. A future real-corpus publication must pass the same JSON/report/integrity gates
from the exact release binary. Spotlight remains a semantically different filename-substring
reference; no latency ratio, cross-tool percentage, or whole-disk recall claim is made.

These results are observations from this identified machine and binary. They are not an absolute
latency SLA, an Intel result, a cross-machine comparison, or evidence for the eventual notarized
Universal 2 artifact.

## Path-mode isolated development benchmark

Path browsing has a separate opt-in release benchmark because filesystem percentiles are especially sensitive to concurrent disk activity:

```bash
JBAR_RUN_PATH_BENCHMARK=1 swift test -c release \
  --filter PathModeStreamingTests/testPathModeTwentyThousandIsolatedReleaseBenchmark
```

The current evidence bundle did not run this opt-in test, so no older path-mode latency distribution
is presented as current. The test uses a 20,000-entry fixture and checks bounded retained results,
exact totals after complete enumeration, and superseded-scan cancellation. Its timings are a local
development diagnostic, not a product SLA or a universal speedup claim.

## What the products do differently

| Dimension | JBar | Spotlight |
|---|---|---|
| primary purpose | launch/open by name | system search, metadata, and content |
| indexed scope | configured app/file roots, with exclusions and a hard item cap | system-managed scope |
| matching | fuzzy terms, acronyms, extensions, localized app aliases, pinyin | benchmark reference uses filename substring predicates |
| ranking | launcher-specific grouping, text score, type, frecency, recency | system-defined; benchmark gathers are not JBar-equivalent ranking |
| file contents | not indexed | supported by Spotlight for compatible types |
| path browsing | live, bounded directory scan | not the same interaction model |
| persistence | local binary metadata snapshot + local JSON history | macOS-managed metadata stores |
| interactive dependency | no Spotlight call | Spotlight service itself |

JBar's persistent index stores names, directory structure, types, timestamps, and app metadata; it does not ingest document bodies. See [PRIVACY.md](PRIVACY.md).

## Search and ranking behavior

Normal search parses a bounded query, applies a character mask, fuzzy-scores surviving items, keeps a bounded rerank window, then applies launcher ranking and result grouping. Newer searches supersede older scans. Extending a query can reuse the prior candidate set; deletion invalidates that incremental cache.

Applications are matched against their bundle filename, Finder display name for the current locale, plist names, localized `InfoPlist.strings` names, and generated pinyin aliases for CJK names. The displayed app name follows Finder's current localized name where available.

Path mode is intentionally separate. It streams one top-level directory, keeps a bounded best-K heap, and orders prefix matches before fuzzy matches; comparable folders precede files and final ties are deterministic. A visible badge distinguishes a complete result set, a truncated set, and an unavailable/incomplete enumeration.

## Performance acceptance policy

A release claim requires more than a passing unit-test ceiling or one benchmark run. At minimum, record:

1. the exact commit and release artifact checksum;
2. OS version/build, CPU architecture, model, memory, filesystem, power mode, and thermal state;
3. configured roots/exclusions and resulting index count;
4. at least 100 observations for any advertised p99, with warm-up and cache state stated;
5. multiple independent process runs rather than a selected best run;
6. p50, p95, p99, max, cancellation rate/latency, and JBar-process RSS;
7. separate real-corpus and fixed-seed synthetic results; and
8. the required Intel/Apple Silicon and macOS support matrix from [SUPPORT.md](SUPPORT.md).

The design target may remain lower than the present observation, but documentation must say so. Current evidence does not prove that every keystroke meets a frame budget or that the search SLA is met on supported hardware.

## Honest limitations

- JBar searches filename/application metadata, not document contents.
- Its results cover configured, readable roots after exclusions and caps—not every file on the Mac.
- A bounded top-K can omit one of many identically named files even when all are indexed.
- A path-mode total is authoritative only when enumeration completes; unreadable/incomplete directories show `PATH · ?`.
- Automated tests and synthetic fixtures do not replace physical IME, OS-version, architecture, energy, or clean-install validation.
- This benchmark's optimized binary was thin arm64; separate Universal-bundle and packaged AppKit
  gates do not transfer these performance observations to Intel or to a signed release artifact.
- The current source build is ad-hoc signed. Public performance claims should be rechecked on the exact notarized artifact because build/signing/runtime context can differ.
