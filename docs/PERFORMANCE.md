# Performance program

The [October 3, 2026 review](PERFORMANCE-REVIEW-2026-10-03.md) records the current implementation
pass, index measurements, agent CLI, reproducible comparisons and remaining bottlenecks. Earlier
measurements below remain historical evidence.

JBar should remain a small launcher with an exceptionally fast name-search path. Content search is
a separate workload: it needs document extraction, a durable inverted index, freshness rules, and
new privacy/storage controls. Mixing body text into `IndexStore` would make every launch query pay
for a feature it may not use.

## Current name-search review

The existing engine already has the right broad shape: immutable structure-of-arrays generations,
pre-folded UTF-8 arenas, character masks, reusable scorer scratch, bounded top-K ranking,
incremental candidate reuse, cancellation, and stage-2 path/frecency materialization for only a
small window.

The remaining cold-query bottlenecks found in this review were:

1. A new or incompatible query still entered the hot loop through the entire store even when one
   required character was selective.
2. Parallel scans created one 300-item heap per 8,192-item chunk. At one million items this meant
   dozens of heaps/tasks and a barrier paced by the slowest worker.
3. The general fuzzy DP made several passes for a one-byte query even though its score is exactly
   the best boundary bonus among occurrences.

The implemented fast path adds 38 packed character-presence bitsets (~4.75 bytes per item), scans
the rarest safe bitset directly, uses a one-pass exact scorer for one-byte terms, and balances work
over at most four parallel chunks. Apps are in every bitset because an alias may contain characters
absent from the bundle name. Extension-satisfiable terms deliberately fall back when a filename
character filter would be unsound.

Local development measurements on the same 2026-08-21 M4 machine and deterministic benchmark
fixture are encouraging but are not release evidence:

| Workload | Previous recorded p50 range | Optimized spot-check p50 |
|---|---:|---:|
| 300K, cache-cold `x` | 43.7–55.2 ms | ~10 ms |
| 300K, first typed `r` | 71.3–84.2 ms | ~16 ms |
| 1M, cache-cold `x` | 171.5–181.6 ms | ~34 ms |
| 1M, first typed `r` | 251.1–269.9 ms | ~54 ms |

The spot-check used only a few samples, while the previous numbers came from the repository's
three-process, 100-observation campaign. Ordered rows, exact totals, and result fingerprints were
unchanged in the spot-check. A clean candidate must rerun the full release harness before any table
or public claim is replaced.

## Can content search beat Spotlight?

For a deliberately bounded corpus and well-defined text formats, likely yes on warm interactive
token/prefix queries. JBar can exclude dependency/cache trees, keep a smaller index, specialize
ranking, and avoid unrelated system metadata work. It should not claim to beat Spotlight across the
whole Mac, all document formats, OCR, semantic search, or initial ingestion. Spotlight has broader
format coverage and mature system integration.

The defensible product goal is therefore:

- beat a settled Spotlight index on latency for the same supported files, roots, and query
  semantics;
- report recall/freshness separately from latency;
- keep name-only launch search independent, available, and fast while content indexing catches up;
- make unsupported, oversized, encrypted, cloud-placeholder, and permission-denied files explicit.

## Recommended content architecture

Keep `IndexStore` unchanged and add an opt-in `ContentIndex` service with its own snapshot/version,
worker budget, status, and failure surface.

1. **Simple query mode.** Use an explicit `content:` prefix at first. It avoids surprising disk/index
   work and preserves today's launcher semantics. Name matches can still render immediately above a
   separately labelled content group.
2. **Phase-one formats.** Index bounded UTF-8/UTF-16 plain text, source, Markdown, JSON, CSV, and
   similar formats. Add PDF/RTF/Office/iWork only through isolated, cancellable extractors with
   per-file byte/time limits. Never parse documents in the keystroke path.
3. **Durable inverted index.** Store normalized term/prefix postings and compact per-document
   positions on disk; memory-map immutable segments and maintain a small mutable delta for FSEvents
   updates. Merge segments in the background. Do not retain full bodies in RAM or in the filename
   snapshot.
4. **Two-stage ranking.** Retrieve a bounded document/position pool from the inverted index, then
   combine content relevance with filename score, type, recency, and frecency. Build snippets only
   for visible rows.
5. **Freshness identity.** Key extracted content by stable file identity plus size, mtime, and a
   bounded content fingerprint. Rename-only events should update paths without re-extracting.
6. **Backpressure.** Pause or lower-priority ingestion on battery/thermal pressure and cap concurrent
   extractors, file size, total indexed bytes, segment count, and merge I/O. Content search must
   remain usable against the last complete generation during updates.
7. **Privacy.** Make content indexing opt-in, document exactly what text/snippets are stored, keep
   owner-only permissions, exclude sensitive/default-noise roots, and provide a separate clear
   action. The existing privacy statement must change before shipping this feature.

## Benchmark and release gates

Add a versioned content workload rather than extending the filename workload ambiguously:

- deterministic corpora at multiple document counts and body sizes, with common, selective,
  prefix, phrase, multi-term, Unicode, and no-match queries;
- warm query p50/p95/p99/max, first-query-after-launch latency, cancellation latency, index build and
  incremental-update throughput, steady/peak RSS, disk bytes, CPU time, and energy;
- exact expected document ids and positions/snippets for correctness, plus explicit unsupported and
  stale-document counts;
- a same-root Spotlight `kMDItemTextContent` reference only after both indexes report settled, using
  equivalent query semantics and separate timeout/miss/ranking-miss reporting;
- repeated independent processes on Apple Silicon and Intel, plus thermal/load notes and the exact
  signed candidate identity.

Do not publish a speed ratio unless query semantics, corpus membership, freshness, and result
correctness are equivalent. A fast incomplete result is not a win.

## Next optimization queue

1. Rerun the full 300K/500K/1M release campaign and tune the four-worker cap on Intel and lower-core
   Macs; make it hardware-adaptive only if multi-machine data supports that complexity.
2. Add snapshot-load, accelerator-build, and first-query-after-load distributions. The packed
   bitsets are derived rather than serialized, so startup cost must remain visible.
3. Profile broad single-character ranking to decide whether a small precomputed static rank
   component can reduce the remaining one-million-item ~34–54 ms path without bloating the store.
4. Benchmark path mode on real large directories; it is filesystem-metadata bound and is not covered
   by the in-memory gains above.
5. Prototype phase-one content search behind a build flag with a standalone index and correctness
   corpus before changing UI, configuration, snapshot schema, or privacy promises.
