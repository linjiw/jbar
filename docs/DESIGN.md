# JBar design and current product contract

JBar is a native Swift/AppKit menu-bar launcher for macOS. It searches a local, bounded index of application and file **names/metadata**, opens or reveals a selected item, and maintains local frecency history. Interactive search does not depend on Spotlight.

This is a description of the current implementation, not a declaration that v1 is released. The intended support contract is macOS 13+, Apple Silicon and Intel in one Universal 2 artifact, any system language/input source, and an English v1 interface. The physical compatibility matrix, Developer ID signing, notarization, Gatekeeper, and clean-machine release verification remain mandatory gates; see [SUPPORT.md](SUPPORT.md) and [RELEASING.md](RELEASING.md).

## 1. Scope

Implemented product capabilities:

- global configurable hotkey and a non-Dock AppKit search panel;
- app, file, and folder search by name;
- acronym/fuzzy, multi-term, extension-only, CJK substring, and pinyin matching;
- Finder-localized application display names plus bundle/plist/localized aliases;
- apps-first result grouping, file/app type signals, recency, and local frecency;
- live path browsing and folder autocomplete;
- keyboard selection, scrolling, open, reveal, and copy-path actions;
- local binary index snapshot, FSEvents updates, JSON config hot reload, and JSON history;
- menu-bar status, rebuild, login-item, config, about, and quit actions; and
- source-build, packaging, CI, benchmark, and release-gate tooling.

Important non-capabilities/current gaps:

- no document-content search;
- no interactive Spotlight fallback and no `useSpotlightFallback` setting;
- no translated JBar interface yet (localized Finder application names are separate from UI localization);
- no in-app settings or clear-history window;
- no Open With, calculator, clipboard history, window switching, or web-search feature;
- launch failures still use limited feedback rather than a full inline recovery UI; and
- no public build should be called released until the support and notarization gates are recorded against the exact artifact.

## 2. Architecture

```text
Carbon hotkey
      │
      ▼
SearchPanel (AppKit, MainActor) ──► AppLauncher / Finder / pasteboard
      │
      ▼ await
SearchEngine actor ──► immutable IndexStore + thread-safe FrecencyStore
      ▲
      │ generation swap
IndexCoordinator ──► AppScanner + Crawler + FSEventsWatcher + Snapshot
```

The Swift package has two main layers:

- `JBarCore` is independent of AppKit and owns configuration, exclusions, index structures, crawl/merge/snapshot logic, parsing, matching, ranking, path enumeration, pinyin aliases, and frecency.
- `JBarApp` owns the AppKit panel/table, Carbon hotkey, menu bar, LaunchServices actions, login item, headless CLI, and benchmark harness.

The search store is immutable after construction. The coordinator publishes monotonically numbered generations; the engine rejects an older generation that arrives after a newer one. Heavy search and directory work runs on a private worker queue while the actor remains re-entrant. Each new request advances a counter that older workers poll so superseded results can be abandoned, and the UI also maintains its own epoch before rendering a response.

## 3. Indexing

### 3.1 Data model

`IndexStore` uses parallel arrays and byte arenas rather than one object per file. An item records references to its directory and folded/display name bytes plus mask, initials, timestamp, kind, flags, depth, extension ID, and optional application side-table metadata. Directory parent/name entries reconstruct paths on demand.

This representation stores path/name metadata. It does not store document bodies. Exact filenames and directory structure are still sensitive; see [PRIVACY.md](PRIVACY.md).

### 3.2 Application discovery and localization

`AppScanner` checks configured application roots and known system app locations, discovers bundles to the supported depth, resolves symlinks for deduplication, drops dangling targets, and reads bundle metadata. The primary displayed name is `FileManager.default.displayName(atPath:)`, matching Finder for the active locale when the system supplies a localized display name.

`CFBundleDisplayName`, `CFBundleName`, and values from `Contents/Resources/*.lproj/InfoPlist.strings` are retained as searchable aliases after deduplication and limits. CJK names also receive pinyin full/initial aliases at index time. Thus a Chinese system can display the Finder-localized app name while searches using another known bundle/localized alias can still match it.

This implementation behavior has automated fixtures. It still requires physical verification with real applications under the required system-language/input-source matrix.

### 3.3 File crawling and hard limits

Default roots and exclusions are defined in `AppScanner` and `Exclusions`; configuration can replace them. Excluded dependency/cache/system-noise trees are not descended, while configured downrank names remain indexed with a ranking penalty.

Safety-relevant values are validated before use:

- `maxIndexedItems`: `1...2,000,000`;
- `maxDepth`: `0...64`;
- at most 128 app roots and 128 file roots;
- bounded exclusion/name collections and UTF-8 path/name lengths; and
- a shared app-plus-file item budget, including rebuild and incremental update paths.

Reaching the item cap is an explicit incomplete-index condition rather than permission to publish an oversized generation. Incremental merge logic validates retained IDs, root mappings, array/arena bounds, and shared remaining capacity before publication.

### 3.4 Updates and persistence

The coordinator can publish an early application index, perform a file crawl, write a snapshot, and then use FSEvents to trigger incremental directory work or a full rebuild when event history is not trustworthy. A snapshot is accepted only when its schema/header hash matches the active roots, exclusions, scoring constants, and item cap.

Snapshot/config/history reads operate on the descriptor actually opened, reject non-regular files and symbolic links, and enforce byte/count/arena bounds before allocation. Product-state writes use a descriptor-opened parent, an owner-only temporary file, `fsync`, and atomic rename; JBar-owned state directories/files are tightened to `0700`/`0600`. A corrupt or mismatched snapshot is a cache miss and causes a rebuild.

## 4. Query and ranking

### 4.1 Modes

`QueryParser` produces one of four modes:

- **empty** — return local frecency rows, unless `showRecentsOnEmpty` is false;
- **search** — fuzzy/multi-term/acronym/alias search;
- **extension-only** — a leading extension such as `.md`; or
- **path** — an absolute or tilde-prefixed directory/filter query.

Queries are bounded to 4,096 user-perceived characters and 16 KiB of UTF-8 before expensive parsing. Search terms are folded case/diacritic/width-insensitively. Multi-term matching is AND-based; extension aliases can satisfy an extension term. A trailing space marks the last term complete and requires its contiguous occurrence.

### 4.2 Normal search

The normal pipeline is:

1. reject items that cannot contain the query's character mask;
2. perform greedy/subsequence and dynamic-programming scoring on survivors;
3. retain a bounded best-candidate window;
4. reconstruct paths only for that window and add frecency/query-pick facts; and
5. apply deterministic ranking/grouping and build highlighted rows.

The stage-one rerank window is 300 items. Consequently a highly frecent path outside the best 300 text candidates cannot be promoted into the final result, and scored normal/extension searches cannot return more than 300 rows even though configuration validation permits `maxResults` up to 500. This is a deliberate bounded-work tradeoff; empty-history and path modes have their own bounds.

Extending every term can reuse the prior matched-candidate list. Deletion or an incompatible edit forces a full scan. New queries cancel older scans; cancelled responses contain no rows and must not repaint the panel.

The ranking order is deterministic: exact/prefix application tiers precede general matches, then score and tie-break facts apply. `appsFirstCap` reserves predictable application placement before file rows; the total normal request is bounded by `maxResults`.

### 4.3 Empty query and history

Frecency records an exact path, decayed score/timestamp, and—when the committed query is long enough—a normalized query-to-path pick. It is bounded to 500 paths and 200 query picks. Missing targets are pruned and the result persisted on startup off the UI/search path.

`showRecentsOnEmpty: false` is honored by the panel. It displays only the hint/indexing row, advances cancellation state, and uses a UI epoch so an older in-flight result cannot repopulate the supposedly empty panel. This setting hides history; it does not delete it.

### 4.4 Path mode

Path mode enumerates one directory level on a worker queue. It consumes entries incrementally and holds only a bounded best-K heap; it does not materialize the entire directory. The current retained-row cap is:

```text
min(validated maxResults × 4, 2,000 rows)
```

For the default `maxResults = 40`, this is at most 160 retained rows. Enumeration can still take time proportional to the directory size because JBar counts every match when it can finish. Cancellation is polled during enumeration, matching, metadata lookup, sorting, and row construction.

Ordering is:

1. prefix/unfiltered group before fuzzy group;
2. fuzzy score descending inside the fuzzy group;
3. folders before files when group and relevant score are equal; and
4. Finder-style name comparison plus a binary deterministic tie-break.

Hidden dot-names are excluded unless the filter begins with `.`. A readable empty directory reports an exact zero; an unreadable/missing/incomplete enumeration is not mislabeled as zero. The badge is `PATH` for a complete untruncated result, `PATH · shown/total` when retained rows are truncated, and `PATH · ?` when completeness is unknown.

The opt-in 20,000-entry release benchmark records retained-row bounds, exact/incomplete totals, and cancellation distributions. It must be rerun on the candidate artifact; older local timings are not carried forward as current evidence. See [COMPARISON.md](COMPARISON.md).

## 5. Panel and input behavior

### 5.1 Viewport and result pool

`maxResults` is the scrollable result request (`1...500`; scored normal/extension results are additionally bounded by the 300-item rerank window). `visibleRows` is the requested viewport (`1...20`). They are intentionally independent.

`PanelLayoutMetrics` is the single source of truth for:

- screen capacity;
- effective visible rows (`min(configured, screen capacity)`);
- actual visible row count;
- panel height;
- overflow/next-row peek;
- table viewport; and
- Page Up/Page Down stride.

This keeps a 12- or 20-row configuration functional on a large display while reducing it coherently on a short display. Results beyond the viewport remain reachable by arrows, page movement, scroll wheel, or trackpad. Installing an empty row model does not ask AppKit to scroll row zero, avoiding the former empty-table exception path.

### 5.2 Keyboard layouts and IMEs

Configured hotkey letters/digits refer to fixed US-ANSI physical key positions. This makes the binding stable while the user switches input sources. `⌘1...⌘8` also checks physical ANSI digit key codes, so the same top-row positions work on AZERTY/QWERTZ/Dvorak layouts. These shortcuts target the first eight results in the pool, independent of scroll position.

The field editor and `NSTextInputContext` own editing/composition:

- Control alone never closes the panel;
- physical Delete (key code 51), held Delete, and forward Delete are editing keys, not close keys;
- only physical Escape with no Command/Control/Option modifier can close the panel;
- when marked text exists, Escape, Command shortcuts, navigation, candidate selection, and command selectors are returned to AppKit/IME;
- the marked-text state captured at resign time participates in the deferred-dismiss decision; and
- programmatic clearing commits/ends composition safely before replacing field text.

Automated tests exercise these policies and Chinese/Korean marked-text fixtures. They are regression evidence, not proof for real Sequoia 15.x Simplified Chinese Pinyin or every supported input source. The physical steps are in [UX-TESTS.md](UX-TESTS.md).

### 5.3 Actions

- Applications use asynchronous `NSWorkspace.openApplication` with activation requested.
- Files/folders use `NSWorkspace.open`.
- Reveal uses Finder selection.
- Copy writes the exact POSIX path to the general pasteboard.

An application open is not treated as success until LaunchServices calls back with an application and no error. Only confirmed success records frecency and hides the panel. Synchronous file/folder failures and missing paths likewise do not record history. Current failure feedback is intentionally conservative but limited (primarily an audible beep/log); a richer inline recovery state remains product work.

## 6. Configuration contract

The config defaults to `~/.config/jbar/config.json`, or `$XDG_CONFIG_HOME/jbar/config.json` only when that environment variable is absolute. Missing files are created with documented defaults. Unknown keys are ignored, missing keys use defaults, and a wrong type/out-of-range value is rejected as one invalid configuration. Hot reload keeps the last valid state on error.

Current keys are:

```text
hotkey, launchAtLogin, maxResults, visibleRows, appsFirstCap, screen,
restoreQueryOnReopen, showRecentsOnEmpty, appDirectories, fileRoots,
excludePaths, excludeNames, downrankNames, includeHidden, maxDepth,
maxIndexedItems
```

There is no `useSpotlightFallback` key. Older configurations that predate `visibleRows` migrate the legacy positive `maxResults` value into a bounded viewport while restoring a useful result pool; unsafe legacy values are rejected.

## 7. Performance evidence and gates

Performance targets and measured evidence are separate:

| Area | Product intent/gate | Current evidence |
|---|---|---|
| deterministic scale | bounded, correct work at 300k/500k/1M | three independent release processes per size × 100 samples passed schema/workload/identity gates; 1M cold-`x` process p50 ranged 171.521–181.592 ms and p95 178.376–188.499 ms, with a 193.135 ms worst sample |
| serial typing/deletion | preserve exact ordered rows and totals through cache extension/invalidation | 1M common→selective `r` process p50 ranged 251.063–269.888 ms and p95 268.004–291.179 ms; this is engine call latency, not key-to-paint UI latency |
| supersession | stale work never replaces the newest response | every older request was cancelled (900/900 across the synthetic matrix), with zero unexpected newest cancellations; 1M newest-query p50 ranged 40.284–45.404 ms |
| real cold crawl/search | complete an isolated crawl without mutating benchmark history/snapshot state | available as an opt-in gated workload, but not run in the current formal campaign; older-binary figures are not current release evidence |
| path mode | bounded top-K, explicit incomplete totals, and responsive cancellation | the automated semantic/ceiling gate exists; the older timing distribution was not rerun on this candidate |
| memory/energy/startup | publish per-artifact RSS, peak crawl RSS, idle CPU/energy, and panel latency | current release-artifact and cross-machine energy/startup evidence remains pending |

The current record is a precisely captured clean-candidate development-machine campaign from commit `183fc3c2e526e21dccc7976203e5f00ba371426c`, generated at 2026-08-21T00:20:08Z on an Apple M4 Mac16,12 running macOS 26.5.2 (25F84) with Xcode 26.2 (17C52) and Swift 6.2.3. It is not a notarized release or a support-wide SLA. Every response expected to complete was non-cancelled and directly checked for identical ordered rows and exact totals; deliberately superseded older requests were instead required to cancel. The evidence manifest is `7a64cb87…0de6ab`, and every process used binary `ec449660…356654f`. The benchmark commands, methodology, full ranges, and limitations are in [COMPARISON.md](COMPARISON.md). A smoke ceiling in a shared test runner prevents catastrophic regressions; it does not establish an advertised SLA.

## 8. Privacy and security boundaries

JBar has no telemetry/network client and does not request Accessibility, Input Monitoring, or Full Disk Access. It may encounter Files and Folders consent for protected configured roots. Normal logs contain operational metadata and numeric errors but omit raw queries, names, and paths.

The local index and history are not encrypted. History contains exact opened paths and normalized query picks. Copy Path exposes a selected path to the general pasteboard, and apps opened through LaunchServices can maintain their own state. Locations, retention, and exact-file deletion steps are in [PRIVACY.md](PRIVACY.md).

Security boundaries currently enforced in core code include input/config allocation limits, a shared hard index cap, fail-closed snapshot validation, descriptor-based no-symlink bounded reads, owner-only atomic product-state writes, and stale/cancelled response rejection. Automated local evidence includes Debug/Release strict-concurrency-complete builds with warnings as errors; the local ASan runtime was blocked by the installed Xcode platform policy and is not claimed as passing. Release review must still include hostile filesystem races, runnable sanitizers, installer rollback, notarization, and physical runtime evidence.

## 9. Build and distribution

`scripts/build-app.sh` builds `arm64` and `x86_64` by default, checks both slices, validates bundle metadata/version, and strictly verifies the signature. Its default signature is ad-hoc for development. The current local gate verified both slices at minOS 13.0 plus native arm64 and Rosetta x86_64 CLI execution; Rosetta is not native Intel or macOS 13 runtime evidence. `scripts/package-app.sh` validates architecture, minimum OS, signature, version, archive structure, executable permission, and checksum.

The public channel is intended to be one Developer ID signed, Hardened Runtime, notarized/stapled Universal 2 ZIP. A Homebrew Cask should install that exact ZIP. Homebrew formulae, npm packages, Electron, or a language rewrite do not remove macOS signing, Gatekeeper, TCC, minimum-OS, or CPU requirements. Swift/AppKit avoids a second runtime and is the simplest architecture for the native panel, text-input, LaunchServices, FSEvents, login-item, and hotkey APIs used here.

Until the release gate passes, `make install` is a source/development flow and downloaded ad-hoc artifacts must not be presented as a normal install. Do not instruct users to strip quarantine. Follow [RELEASING.md](RELEASING.md).

## 10. Validation model

Evidence levels are cumulative:

1. **Automated:** unit/integration checks for logic and architecture.
2. **Runtime:** the built app launches, searches, opens, relaunches, and leaves no crash report on that OS/CPU.
3. **Input/UI:** a human uses the actual language, IME, keyboard layout, display configuration, and accessibility settings.
4. **Release:** the exact downloadable archive passes signature, notarization/stapling, Gatekeeper, checksum, clean install, update, rollback, and uninstall.

The current executable matrix is [UX-TESTS.md](UX-TESTS.md). Compilation or a marked-text fixture alone must never be used to mark the Sequoia Chinese/Intel/notarized matrix complete.
