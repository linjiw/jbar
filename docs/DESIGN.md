# JBar design and current product contract

For the proposed product roadmap that evolves the development-only Codex slice into lightweight
Assisted Find, safe organization, and local-first voice input, see
[ASSISTED-WORKFLOWS-DESIGN.md](ASSISTED-WORKFLOWS-DESIGN.md). This document continues to describe the
current implementation contract.

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
- development-only metadata Assistant (`?`) and reviewed Organize (`!`) surfaces plus an explicitly
  separate Developer Agent (`>`); and
- source-build, packaging, CI, benchmark, and release-gate tooling.

Important non-capabilities/current gaps:

- no document-content search;
- no interactive Spotlight fallback and no `useSpotlightFallback` setting;
- no translated JBar interface yet (localized Finder application names are separate from UI localization);
- no in-app settings or clear-history window;
- no Open With, calculator, clipboard history, window switching, or web-search feature;
- assisted workflows remain development-only and have not completed release, billing, and compatibility gates;
- launch failures still use limited feedback rather than a full inline recovery UI; and
- no public build should be called released until the support and notarization gates are recorded against the exact artifact.

## 2. Architecture

```text
Carbon hotkey
      │
      ▼
SearchPanel (AppKit, MainActor) ──► AppLauncher / Finder / pasteboard
      ├── local text ──► SearchEngine actor ──► immutable IndexStore + thread-safe FrecencyStore
      ├── explicit ? + Return ──► tool-free Luna SearchPlan ──► native assistedSearch ──► result window
      ├── explicit !/！ + Return ──► typed global search ──► destination + ID-only copy plan ──► Preview / Copy
      └── explicit > + Return ──► Developer Agent ──► isolated ~/jbar Codex thread
IndexCoordinator ──► AppScanner + Crawler + FSEventsWatcher + Snapshot ──► generation swap
```

The Swift package has three main layers:

- `JBarCore` is independent of AppKit and owns configuration, exclusions, index structures, crawl/merge/snapshot logic, parsing, matching, ranking, path enumeration, pinyin aliases, and frecency.
- `JBarActions` owns side-effect-free palette intent routing and the narrowly scoped Codex app-server transport, account/config/model/thread gates, and event validation.
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

Extending every term can reuse the prior matched-candidate list. A cache-cold query, deletion, or incompatible edit starts from the least-populated bitset for any required character and validates the full combined mask; apps are conservatively present in every bitset because aliases may contain characters absent from the bundle name. Queries whose terms can all be satisfied by extension fall back to the full extension/name candidate space. New queries cancel older scans; cancelled responses contain no rows and must not repaint the panel.

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

### 5.4 Development-only Assistant, Organize, and Developer Agent

A leading `?` selects Ask mode locally. Editing updates only local draft rows; the action handler is
called solely by a non-empty Return submission. That submission opens the Assistant result window and
closes the launcher. Codex receives the question, locale, time zone, and a JBar-authored `Indexed
files` scope ID. `turn/start.outputSchema` requires a versioned `SearchPlan` with bounded name,
extension, kind, date, size, sort, and limit fields. JBar rejects unknown keys, a changed scope,
unsupported values, invalid ranges, and traversal-like terms before running a local search.

The Assistant thread is ephemeral and rooted in JBar's owner-only scratch directory with no runtime
workspace roots, instruction sources, writable user roots, dynamic tools, or network-enabled agent
tools. It never receives candidate metadata or paths in this slice. `SearchEngine.assistedSearch`
executes the validated plan over an immutable index snapshot in a cancellable child task and retains
at most 40 rows. Size is not present in the compact index, so size-filtered plans inspect at most
10,000 matching paths and report an incomplete result if the cap is reached. Open, Reveal, and Copy
Path use native JBar actions. Stop or window close cancels planning/search.

A leading `!` or `！` selects Organize locally and submits only on Return. Codex first returns a
typed metadata `SearchPlan`; JBar executes it over one complete immutable index generation across all
configured file roots. An incomplete/capped scan, more than 40 matches, or a non-file-only plan stops
safely. Only then does the user choose one owned copy destination. Directories, apps, packages,
symlinks, hard links, and special files are excluded. Codex receives opaque source IDs, filenames,
byte sizes, and modification dates; it does not receive source/destination paths or file contents. A
closed `OrganizePlan` schema permits only direct-child destination folders and names for known IDs.

The preview is generated and revalidated locally and lists every ready, colliding, changed, invalid,
or planner-omitted match before enabling a separate Copy button. Native descriptor-relative
operations recheck destination and source identities, open each source read-only, create only
direct-child folders, and create every destination with exclusive semantics. A racing/existing target
is skipped. A failed partial copy is removed. Original files are never moved, renamed, edited, or
deleted, so this workflow intentionally has no destructive Undo phase. Assistant follow-ups, metadata
reranking, multi-selection, content reading, and voice are also not implemented.

A leading `>` is the explicit Developer Agent route. It opens a terminal-style transcript and reuses
one app-server process and one ephemeral Codex thread for explicit follow-up turns. Return sends,
Shift-Return inserts a newline, Stop interrupts only the current turn, and closing the window stops the
app-server and discards JBar's in-memory transcript. The deterministic workspace is the existing
`~/jbar` directory. It must be a real, user-owned,
non-group/world-writable directory rather than a symlink, and its device/inode identity is rechecked
before connection and every turn. A repository-root `AGENTS.md` defines project scope, implementation
conventions, safe mutation rules, and verification expectations so each new ephemeral thread starts
with useful local context and no workspace picker or persistent session database is needed.

The client requires Codex 0.149.0 or newer, launches `codex app-server --listen stdio://` directly,
and sets `CODEX_HOME` to `~/Library/Application Support/JBar/CodexHome`. First use delegates ChatGPT
OAuth to Codex. JBar opens the HTTPS authorization URL but does not register its own OAuth client or
read the resulting access token. Binary discovery includes standard user CLI locations and the
official Codex executable in an installed ChatGPT desktop app, so a stale Homebrew CLI does not make
the GUI integration depend on a development-only environment override.

Opening the browser must not tear down the owning assisted window: the same app-server owns the
temporary localhost callback listener. While login is pending, the window reports that the browser
must finish sign-in; closing the window cancels the login and terminates the listener. Its old browser URL is
not replayable. Later milestones report account/safety validation, Luna preparation, and answer
generation without including prompts, account data, or URLs.

Before `turn/start`, the implementation validates a ChatGPT account, no provider/endpoint override,
the live Luna catalog entry, and the complete thread response. The requested thread is ephemeral,
`openai`/Luna-only with fallback disabled, rooted exactly at `~/jbar`, approval `never`, and a
workspace-write sandbox with network access disabled. Every turn repeats those constraints. Shell and
patch execution stay enabled; broad apps, browser/web, plugins, computer use, images, skill discovery,
workspace dependencies, and multi-agent features remain disabled. No dynamic tool is supplied and no
capability-root override is sent. Instruction sources and reported command/file paths must remain inside the workspace.
Unexpected server requests, model reroutes, unsafe account changes, or tool families interrupt and
fail the task. A normal post-login account refresh is revalidated against the same ChatGPT-only gate.

Agent-message and command-output deltas update the visible transcript at a bounded frame rate, but
they are not treated as authoritative completion. Completed commands show authoritative output and
exit code; completed file-change items show their paths and kinds. The final answer is accepted only
after matching successful item and turn completion. Only one turn may be active per window.

`workspaceWrite` is a write boundary, not a complete read boundary in the installed Codex 0.149
schema. The command sandbox can also use its standard temporary directories, and the Codex child has
the current macOS account's readable filesystem view. JBar rejects a command whose reported working
directory or file-change path escapes `~/jbar`, but it cannot infer every path a shell command may
read. Restricted read policy support plus adversarial packaged-app verification is a release gate.

This source implementation is local test work, not a shipping claim. OAuth against the packaged app,
user allowance/credits disclosure, usage attribution, endpoint/provider hostility, notarization, TCC,
and real-account billing evidence remain release gates.

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

JBar has no telemetry or JBar cloud service and does not request Accessibility, Input Monitoring, or
Full Disk Access. Ordinary search is local. A `?` question leaves the Mac only after Return through the
user's isolated local Codex client; JBar does not send its index, search history, or files. It may
encounter Files and Folders consent for protected configured roots. Normal logs contain operational
metadata and numeric errors but omit raw queries, names, paths, assisted prompts, plans, and answers.

The local index and history are not encrypted. History contains exact opened paths and normalized query picks. Copy Path exposes a selected path to the general pasteboard, and apps opened through LaunchServices can maintain their own state. Locations, retention, and exact-file deletion steps are in [PRIVACY.md](PRIVACY.md).

Security boundaries currently enforced include input/config allocation limits, a shared hard index cap,
fail-closed snapshot validation, descriptor-based no-symlink bounded reads, owner-only atomic product-state
writes, stale/cancelled response rejection, owner-only isolated Codex directories, credential environment
scrubbing, and protocol-level Codex billing/model/tool gates. Automated local evidence includes
Debug/Release strict-concurrency-complete builds with warnings as errors; the local ASan runtime was
blocked by the installed Xcode platform policy and is not claimed as passing. Release review must still
include hostile filesystem races, runnable sanitizers, installer rollback, notarization, and physical
runtime evidence.

## 9. Build and distribution

`scripts/build-app.sh` builds `arm64` and `x86_64` by default, checks both slices, validates bundle metadata/version, and strictly verifies the signature. Its default signature is ad-hoc for development. The current local gate verified both slices at minOS 13.0 plus native arm64 and Rosetta x86_64 CLI execution; Rosetta is not native Intel or macOS 13 runtime evidence. `scripts/package-app.sh` validates architecture, minimum OS, signature, version, archive structure, executable permission, and checksum.

The current public channel is an explicitly labelled ad-hoc Universal 2 developer-preview ZIP on
GitHub Releases. The npm package is a Node-18+ launcher that downloads and verifies that exact ZIP;
it does not bundle Node or change the native app. A future paid Developer ID release can replace the
preview with a Hardened Runtime, notarized/stapled ZIP. Neither channel removes macOS signing,
Gatekeeper, TCC, minimum-OS, or CPU requirements. Swift/AppKit avoids a second runtime and is the
simplest architecture for the native panel, text-input, LaunchServices, FSEvents, login-item, and
hotkey APIs used here.

The preview is intentionally presented as a developer install, not a trusted/notarized public release. `make install` remains the preferred path when a user wants to build from source. Do not instruct users to strip quarantine. Follow [RELEASING.md](RELEASING.md).

## 10. Validation model

Evidence levels are cumulative:

1. **Automated:** unit/integration checks for logic and architecture.
2. **Runtime:** the built app launches, searches, opens, relaunches, and leaves no crash report on that OS/CPU.
3. **Input/UI:** a human uses the actual language, IME, keyboard layout, display configuration, and accessibility settings.
4. **Release:** the exact downloadable archive passes signature, notarization/stapling, Gatekeeper, checksum, clean install, update, rollback, and uninstall.

The current executable matrix is [UX-TESTS.md](UX-TESTS.md). Compilation or a marked-text fixture alone must never be used to mark the Sequoia Chinese/Intel/notarized matrix complete.
