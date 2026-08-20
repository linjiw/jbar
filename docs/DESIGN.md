# JBar — Design Document (v1)

A keyboard-first launcher for this Mac (macOS 26.5 Tahoe, arm64) that opens **apps, files and folders** from its **own index**, independent of Spotlight's health. Written in Swift / AppKit, built with SwiftPM, assembled into a local ad-hoc-signed `.app`, zero third-party dependencies, zero privacy-sensitive permissions (no Accessibility, no Full Disk Access, no Input Monitoring).

> **Status (2026-08-19): v1 implemented and installed.** All modules in this document are built and passing 230 unit tests; `make install` produces a working `JBar.app`. Measured on this Mac: ~182k files + 148 apps indexed in ~7 s cold, 1–16 ms warm search latency, ~130 MB resident. See `README.md` for usage.

Companion document: `docs/DIAGNOSIS.md` explains why Spotlight is unreliable on this machine today (index rebuild in progress, junk-tree indexing, near-full disk) and motivates "own the index".

Status of claims: every API in §5 was verified on this Mac (SDK header grep + `swiftc` compile + in several cases runtime) or against Apple's documentation JSON; anything not verified is marked **UNVERIFIED** inline and collected in §13.

---

## 1. Goals / non-goals

**Goals (v1)**
- `⌥Space` → panel in < 50 ms warm; first keystroke → ranked results in < 30 ms for a 500k–1M item index.
- Find every app (`code`, `vsc` → Visual Studio Code; `wechat`, `微信`, `weixin`, `wx` → WeChat; `xc` → Xcode) and every file/folder under the home directory that a human would plausibly open, by fuzzy name match, ranked by launcher-specific signals (exact/prefix/acronym, type, frecency, recency).
- Open (Enter), reveal in Finder (⌘Enter), copy path (⌘C), path-browsing mode (`~/Dow` + Tab → `~/Downloads/` listing all ~1,191 entries, which Spotlight currently shows 129 of).
- Own index: crawl + FSEvents incremental updates + on-disk snapshot; Spotlight used at most as an asynchronous, time-boxed "more results" source.
- Menu-bar item with index status, Rebuild, Launch at Login, Open Config, Quit. JSON config with hot reload.
- `make install` from a clean checkout ends with the panel on screen; `make uninstall` removes everything.
- `JBarCore` (index, matcher, ranking, config, history) is pure Swift, no AppKit, ≥ 90% unit-test coverage; ranking expectations are golden tests.

**Non-goals (v1)** — see §12 for the ordered v2 backlog: Open With / per-kind default apps, `app:`/`f:` query prefixes, window switching, calculator, clipboard history, snippets (needs Accessibility — conflicts with the zero-permission principle, probably never), web search/bookmarks, System Settings panes, iCloud/Google Drive (FileProvider) content indexing, settings window/themes, notarized release / Homebrew cask / auto-update.

**Principles**
- Never block the main thread > 4 ms on the search path; never block first paint on Spotlight or on the file crawl (apps are searchable within ~1 s of launch).
- No destructive interaction with Spotlight (`mdutil -E` etc.) — the design does not depend on it.
- Every user-visible failure (hotkey not registered, config invalid, folder access denied, index cap hit) gets a line in the menu-bar menu.
- One `Ranking` struct holds all weights; constants are regression-tested, not tuned by feel.

---

## 2. Architecture

### 2.1 Toolchain decisions

| decision | choice | rationale |
|---|---|---|
| Language / package | Swift, SwiftPM, **`swift-tools-version:5.9`**, Swift 5 language mode (`Package.swift` already in repo) | Compiling the verified API test in Swift 6 language mode produced only global-actor-isolation errors on AppKit globals. Keep v5 mode; opt into `-strict-concurrency=complete` as warnings in `JBarCore` and put the index behind an `actor`. Migrate to tools 6.0 once the UI layer is `@MainActor`-clean. |
| Deployment target | `platforms: [.macOS(.v13)]` in `Package.swift`, **`LSMinimumSystemVersion 13.0`** | All APIs used are ≥ 13.0 (`SMAppService` is 13+). Note `NSApp.activate()` (no-arg) is 14+ → use `activate(ignoringOtherApps:)`. Dev/test machine is 26.5. |
| UI toolkit | **AppKit** (`NSPanel` + `NSTableView`), no SwiftUI in v1 | Non-activating panel key handling, row recycling at 60 fps, precise first-responder control. A SwiftUI row view can be hosted later via `NSHostingView` if wanted. Optional `NSGlassEffectView` (macOS 26) behind `#available` is v1.1 polish — **doc-verified only, not compile-tested**. |
| Hotkey | Carbon `RegisterEventHotKey` | Runtime-verified: returns `noErr` with no TCC prompt. `NSEvent.addGlobalMonitorForEvents` needs Input Monitoring/Accessibility for keyDown — not used. |
| Persistence | Custom binary snapshot of the flat index arrays (`index-v1.bin`, mmap-able) + `history.json` | **Implemented & verified**: `Snapshot.encode/decode` round-trip in tests; a fresh crawl writes it and a second launch loads it. SQLite was **not** used in v1 (the binary snapshot was sufficient), so `import SQLite3` never became a dependency. |
| Crawler | `FileManager.enumerator(at:includingPropertiesForKeys:options:)` (compile-verified) first; `fts_open` (BSD libc, **not compile-tested here**) only if measured > 30 s for the home dir | enumerator gives `isPackageKey`/`skipsPackageDescendants` for free; measure before optimizing. |
| Dependencies | none | System frameworks only: AppKit, Carbon.HIToolbox, CoreServices (FSEvents), ServiceManagement, Foundation, os. |

### 2.2 Targets and directory layout

```
jbar/
  Package.swift                 tools 5.9, platforms macOS 13, products JBar (exe) + JBarCore (lib)
  Sources/JBarCore/             pure logic, no AppKit
    Index/   IndexStore.swift (flat arrays, arena, dirs table), Snapshot.swift, Crawler.swift,
             AppScanner.swift, Exclusions.swift, FSEventsWatcher.swift (CoreServices only)
    Match/   Scorer.swift (fzf-V2 DP), Tokenizer.swift, Pinyin.swift, Mask.swift,
             Ranking.swift (weights + final ordering), Frecency.swift (history)
    Config/  Config.swift (Codable + defaults), ConfigWatcher.swift
    Query/   QueryParser.swift (terms, path mode, ext filter), SearchEngine.swift (actor, cancellation)
  Sources/JBar/                 AppKit app
    main.swift, AppDelegate.swift, Hotkey/CarbonHotkey.swift, UI/{SearchPanel,ResultsTable,RowView,InputField}.swift,
    Menu/StatusMenu.swift, Launch/AppLauncher.swift, Services/LoginItem.swift
  Tests/JBarCoreTests/          scorer golden tests, tokenizer, pinyin, ranking, crawler (fixture tree), config, snapshot, perf (500k synthetic names)
  Resources/Info.plist, Resources/AppIcon.icns (generated from Resources/icon.png by scripts)
  scripts/build-app.sh, scripts/install.sh, scripts/uninstall.sh, Makefile
  docs/DIAGNOSIS.md, docs/DESIGN.md, README.md
```

### 2.3 Modules and their contracts

```
 ┌──────────┐  hotkey   ┌──────────────┐  query   ┌──────────────────┐
 │ Hotkey   │─────────▶│   PanelUI    │────────▶│  SearchEngine    │ (actor, JBarCore)
 │ (Carbon) │          │ NSPanel +    │◀────────│  parse → mask →  │
 └──────────┘          │ NSTableView  │ results  │  greedy → DP →   │
                       └──────┬───────┘          │  rank → top N    │
                              │ open/reveal/copy └───────┬──────────┘
                       ┌──────▼───────┐                  │ reads
                       │ AppLauncher  │          ┌───────▼──────────┐
                       │ NSWorkspace  │          │   IndexStore     │ flat arrays + arena
                       └──────┬───────┘          └───────▲──────────┘
                              │ records             build│ │update
                       ┌──────▼───────┐          ┌───────┴─┴────────┐
                       │  Frecency    │          │ Indexer: AppScanner, Crawler,
                       │ history.json │          │ FSEventsWatcher, Snapshot
                       └──────────────┘          └──────────────────┘
 StatusMenu (NSStatusItem) ── status/rebuild/login item/config ── Config (JSON, hot reload) ── LoginItem (SMAppService)
```

- **Hotkey** — registers the configured combo; posts `toggle` to PanelUI; reports `OSStatus != noErr` to StatusMenu.
- **PanelUI** — owns the `NSPanel`, input field, results table; sends `(query, generation)` to SearchEngine; applies results only if generation is current; routes Enter/⌘Enter/⌘C/⌘1–8/Tab/Esc.
- **SearchEngine** (actor) — `search(_ q: String, limit: Int) async -> [ResultRow]`; cancels superseded queries; apps scored synchronously (< 1 ms), files in parallel chunks; merges optional Spotlight results below own results (dedupe by path).
- **IndexStore** — immutable-snapshot semantics: crawl/FSEvents build a new generation and swap atomically; readers never lock.
- **Indexer** — `AppScanner` (< 1 s, every launch + FSEvents), `Crawler` (utility QoS, streams items into the store in batches of ~5k so results appear during the first crawl), `FSEventsWatcher` (one stream over all roots), `Snapshot` (atomic write, versioned header incl. FSEvents last event id).
- **Matcher** — `Scorer.score(query:item:) -> Int16`, `Tokenizer`, `Pinyin`, `Mask`, `Ranking.finalScore(...)`.
- **Frecency** — `record(open: path, query:)`, `boost(path) -> Int`, 7-day half-life, persisted to `~/Library/Application Support/JBar/history.json` (max 500 paths, prune missing).
- **AppLauncher** — open app / file / folder / reveal / copy path via `NSWorkspace`; every open → `Frecency.record` → panel hides.
- **Config** — `~/.config/jbar/config.json`, defaults written on first launch, `DispatchSource` file watcher, invalid JSON keeps last-good + menu warning.
- **StatusMenu** — items and warning lines (§8).
- **LoginItem** — `SMAppService.mainApp` register/unregister/status.

### 2.4 Threading / concurrency model

- Main thread: UI only. `SearchEngine` is an `actor`; scoring of files runs on `DispatchQueue.concurrentPerform` over `activeProcessorCount` chunks inside the actor's `Task.detached(priority: .userInitiated)`; each chunk keeps a bounded top-K heap; merge on the actor.
- Crawler and FSEvents processing on a serial `utility`-QoS queue (never compete with the user or with mds); CloudStorage roots (if ever enabled) on `background` QoS with a wall-clock budget.
- Store swaps are a single pointer assignment of an immutable struct (`IndexStore.Generation`); in-flight searches keep their generation alive.
- Generation counter per query; results for stale generations are dropped before reaching the table.

---

## 3. Data model (IndexStore)

Flat, cache-linear arrays; names live in one lowercase-folded UTF-8 arena; full paths are **not** stored per item — a `dirs` table (`dirId → parentDirId, nameRange`) reconstructs paths on demand (< 1 µs).

Per item (~60 B without the bonus arena, ~85 B with):

| field | type | notes |
|---|---|---|
| `dirId` | Int32 | parent directory in `dirs` |
| `nameOffset`, `nameLen` | Int32, UInt8 | into the folded arena (APFS NAME_MAX 255 → UInt8 fits) |
| `origNameOffset` | Int32 | original-case name arena (for display and case-match bonus) — can share the arena when no folding changed bytes |
| `bonus` | [UInt8] slice | per-char boundary bonus precomputed at index time (optional; drop to save ~30%, costs ~15% scan time) |
| `mask` | UInt64 | bits 0–25 `a–z`, 26–35 `0–9`, 36 other ASCII punctuation, 37 any non-ASCII, 38–61 free (optionally pinyin initials) |
| `initials` | UInt64 | up to 8 packed lowercase word-initials |
| `mtime` | UInt32 | seconds since 2001 |
| `kind` | UInt8 | app, folder, document, image, video, audio, code, other, packageInternal |
| `flags` | UInt8 | junk, cloud, hidden, package, symlink, app-bundle |
| `depth` | UInt8 | components under the root |
| `extId` | Int16 | interned extension id (for ext filter + type classification) |

Side tables (only ~400 apps have them): `appAlias[itemId] → [folded display name, CFBundleName, localized names, pinyinFull, pinyinInitials]`, bundle id, bundle URL.

Budget: 400k items ≈ 25–35 MB, 1M ≈ 60–85 MB (measured arena ≈ 23 B/name on a 400k synthetic corpus; real names 25–40 B). Hard cap `maxIndexedItems` = 1,000,000 (menu warning when hit).

Snapshot (`~/Library/Caches/com.linji.jbar/index-v1.bin`): magic + schema version + FSEvents `lastEventId` + root list hash + array blobs; written atomically (temp file + rename) after the initial crawl and every ≥ 60 s when dirty; loaded via `Data(contentsOf:options:.mappedIfSafe)` in < 100 ms. Any mismatch (version, roots, exclude list hash) → discard and recrawl.

---

## 4. Indexer

### 4.1 App roots (depth ≤ 2; `.app` bundles are leaf items)

`/Applications` (incl. `/Applications/Utilities` if present — it does not exist on Tahoe), `/System/Applications`, `/System/Applications/Utilities`, `~/Applications` (incl. `Chrome Apps.localized` PWAs), `/System/Library/CoreServices/Applications`, `/System/Library/CoreServices/Finder.app`, `/Applications/Xcode.app/Contents/Applications` (Instruments, Simulator). Do **not** add `/opt/homebrew/Caskroom` as a root (casks symlink into `/Applications`); instead resolve symlinks, drop dangling ones (the development machine had 3, all leftovers from uninstalled apps) and dedupe by `realpath`. Per bundle read `Contents/Info.plist` (`CFBundleDisplayName`, `CFBundleName`, `CFBundleIdentifier`, `LSUIElement`) and every `Contents/Resources/*.lproj/InfoPlist.strings` (`PropertyListSerialization` parses binary and UTF-16 `.strings`) to collect localized names; `FileManager.default.displayName(atPath:)` is the primary display string (what Finder shows for the current locale). Measured: 132 real bundles on this Mac; app scan < 1 s; rescan on every launch and on FSEvents under the app roots. Skip CoreServices bundles with `LSUIElement == true` (helpers).

### 4.2 File roots (config `fileRoots`, default `["~"]`)

Crawl every non-hidden top-level directory under `~` **except** `Library`, `Applications`, `Public` (plus anything in the exclude list, e.g. a `miniconda3` install) — on the development machine that is ~20 directories: the standard `Desktop Documents Downloads Movies Music Pictures`, a `projects` tree, and a dozen loose repo checkouts. Root priority (first-come under the cap, also first-visited so TCC prompts cluster): `Desktop > Documents > Downloads > projects > others`. Optional, off by default in v1: `~/Library/Mobile Documents/com~apple~CloudDocs` (depth ≤ 4), `~/Library/CloudStorage/*` (names only, depth ≤ 3, background QoS, 5 s per-root budget, `cloud` flag; FileProvider directory listings can stall — the 68 s `find ~ -maxdepth 4` seen during diagnosis).

### 4.3 EXCLUDE list (never descended; the directory itself is still an item so the user can open it)

Names (case-insensitive, any depth): `node_modules .git .svn .hg __pycache__ .venv venv .tox .mypy_cache .pytest_cache .ruff_cache site-packages dist-packages .npm .yarn .pnpm-store .gradle .m2 Pods Carthage/Build DerivedData .build .swiftpm xcuserdata .Trash .cache Caches tmp temp $RECYCLE.BIN .Spotlight-V100 .fseventsd .DocumentRevisions-V100 .TemporaryItems`, plus `.cargo/registry`, `go/pkg/mod`, `.rustup .nvm .pyenv .conda`.
Paths: `~/Library` (entirely, except the two opt-in cloud roots above), `~/miniconda3`, `~/anaconda3`, `~/go/pkg`, `~/Creative Cloud Files*`, `~/Pictures/*.photoslibrary`, `~/Music/Music`, `~/Movies/TV`, `~/.Trash`.
Rules: skip hidden entries unless `includeHidden`; never follow symlinks (record them as items); packages other than `.app` (`.photoslibrary .xcodeproj .xcworkspace .playground .framework .bundle .numbers .pages .key .rtfd .scriptd .fcpbundle .lproj …`, detected via `URLResourceKey.isPackageKey` + `skipsPackageDescendants`) are single leaf items; skip `SF_DATALESS` files; `maxDepth` 12 (config); stop descending any directory with > 20,000 direct entries (log + menu note), auto-downrank children of directories with > 5,000 entries.
These lists mirror the Spotlight junk measured in `DIAGNOSIS.md` (`node_modules` = 34% of indexed home items, `miniconda3` 336k files, `projects/*/.venv`, `vendor/bundle`, `tmp/anonymous-source-bundle` 219k files).

### 4.4 DOWNRANK list (indexed, `junk` flag, −30)

`build builds out dist target bin obj .idea .vscode coverage logs log vendor third_party external deps Library(inside a project) Backups Backup "Application Support" Containers "Group Containers" "Creative Cloud Files*" generated gen .next .nuxt .parcel-cache .turbo .angular *.xcarchive`, names starting with `.` or `~$`, children of > 5,000-entry directories. Tested once per path component at crawl time and cached in `flags`, so ranking is O(1).

### 4.5 Crawl procedure

`FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey, .contentModificationDateKey, .nameKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])`, calling `skipDescendants()` for EXCLUDE names, packages, depth > max, and over-cap directories. Items are appended to a builder in batches of ~5k and published as a new store generation so the panel shows partial results during the first crawl. Expect 5–30 s cold for ~400k items when mds is idle; budget < 30 s for 500k (`JBar --bench-index`). Switch to `fts_open(FTS_PHYSICAL|FTS_NOCHDIR|FTS_XDEV)` or `getattrlistbulk` only if this is measured to fail.

### 4.6 Incremental updates (FSEvents)

One `FSEventStreamCreate(nil, callback, &ctx, roots as CFArray, sinceWhen, 1.0 /*latency*/, flags)` with `kFSEventStreamCreateFlagFileEvents | UseCFTypes | NoDefer | IgnoreSelf | WatchRoot`, scheduled with `FSEventStreamSetDispatchQueue(stream, utilityQueue)` (**not** `FSEventStreamScheduleWithRunLoop`, which is `API_DEPRECATED` since macOS 13 in `FSEvents.h`), then `FSEventStreamStart`. Per event path: ignore if under EXCLUDE; `kFSEventStreamEventFlagMustScanSubDirs` → depth-capped rescan of that subtree; otherwise re-list that one directory (non-recursive) and diff (add/remove/update mtime). Persist `FSEventStreamGetLatestEventId()` in the snapshot header every ~30 s and at quit; pass it as `sinceWhen` next launch so offline changes are replayed; on `EventIdsWrapped`/`RootChanged`/`UserDropped`/`KernelDropped`/missing id → full recrawl. Full recrawl also on schema change, exclusion change, every 7 days, and on "Rebuild Index". FSEvents needs no TCC permission.

### 4.7 Spotlight as secondary source (optional, off until own index proves insufficient)

`NSMetadataQuery` with `NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemDisplayNameKey, "*term*")` (or `kMDItemFSName`), `searchScopes = [NSMetadataQueryUserHomeScope]`, only for terms ≥ 3 chars, stopped after 150 ms or 200 results, scored with the same DP, always ranked below own-index results, deduped by path. Never block first paint on it. Do not trust `kMDItemFSContentChangeDate`/`FSSize` (they read 1970/0 during rebuilds on this Mac).

### 4.8 TCC (first run)

Reading `~/Desktop`, `~/Documents`, `~/Downloads` triggers the three standard *Files and Folders* consent dialogs (not Accessibility/FDA). Crawl those roots first so the dialogs appear together; `Info.plist` carries `NSDesktopFolderUsageDescription`, `NSDocumentsFolderUsageDescription`, `NSDownloadsFolderUsageDescription` = "JBar indexes file names so you can open files instantly. No content is read or uploaded." Denial → root skipped + menu line "⚠ Some folders not accessible — Fix…" (opens System Settings › Privacy & Security › Files and Folders). Always launch via `open -a` (LaunchServices) so TCC attributes the prompt to JBar, not Terminal. **UNVERIFIED:** whether ad-hoc re-signing on each `make install` changes the code identity enough to re-prompt (likely yes) — remedy is a self-signed "JBar Dev" certificate (`CODESIGN_IDENTITY="JBar Dev" make install`).

---

## 5. Verified API list

All verified on this Mac (MacOSX26.2 SDK, swiftc 6.2.3, `-target arm64-apple-macosx13.0`) unless marked. "doc" = Apple documentation JSON (`developer.apple.com/tutorials/data/documentation/<path>.json`) fetched and declaration confirmed; "compile" = compiled in a test file; "runtime" = executed.

| # | API | status | notes / doc |
|---|---|---|---|
| 1 | `RegisterEventHotKey(UInt32, UInt32, EventHotKeyID, EventTargetRef, OptionBits, *EventHotKeyRef)`, `InstallEventHandler`, `GetApplicationEventTarget()`, `kEventClassKeyboard`, `kEventHotKeyPressed`, `typeEventHotKeyID`, `kEventParamDirectObject` (`import Carbon.HIToolbox`) | header + compile + **runtime** (`noErr`, no TCC prompt, ⌥Space) | No live Apple doc page (Carbon reference removed). Apple engineer statement on modifier rule: https://developer.apple.com/forums/thread/763878 — macOS 15.0/15.1 rejected Option/Shift-only combos; relaxed in 15.2; still reported flaky after screen unlock → check `OSStatus`, offer fallback combo. |
| 2 | `NSEvent.addGlobalMonitorForEvents(matching:handler:)` | doc only — **not used** | requires Accessibility/Input Monitoring for key events. https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:) |
| 3 | `NSPanel(contentRect:styleMask:[.nonactivatingPanel,.borderless,.fullSizeContentView],backing:defer:)`, `level = .floating/.popUpMenu`, `collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.transient,.ignoresCycle]`, `becomesKeyOnlyIfNeeded`, `isFloatingPanel`, `hidesOnDeactivate`, `override var canBecomeKey`, `orderFrontRegardless()`, `makeKeyAndOrderFront` | doc + compile | https://developer.apple.com/documentation/appkit/nspanel , …/nspanel/becomeskeyonlyifneeded , …/nswindow/stylemask-swift.struct/nonactivatingpanel , …/nswindow/collectionbehavior-swift.struct/canjoinallspaces |
| 4 | `NSVisualEffectView` `.material = .popover/.hudWindow`, `.blendingMode = .behindWindow`, `.state = .active` | doc + compile | https://developer.apple.com/documentation/appkit/nsvisualeffectview/material-swift.enum/hudwindow |
| 5 | `NSGlassEffectView` (macOS 26) | **doc only, not compile-tested** — v1.1 polish behind `#available(macOS 26, *)` | https://developer.apple.com/documentation/appkit/nsglasseffectview |
| 6 | `NSWorkspace.shared.openApplication(at:configuration:completionHandler:)` (+ async), `NSWorkspace.OpenConfiguration().activates`, `open(_ url:) -> Bool`, `open(_:withApplicationAt:configuration:completionHandler:)`, `activateFileViewerSelecting([URL])`, `icon(forFile:)` (32×32 default — set `.size`), `urlForApplication(withBundleIdentifier:)`, `urlsForApplications(withBundleIdentifier:)` (12+) | doc + compile | https://developer.apple.com/documentation/appkit/nsworkspace/openapplication(at:configuration:completionhandler:) , …/nsworkspace/activatefileviewerselecting(_:) , …/nsworkspace/icon(forfile:) , …/nsworkspace/urlsforapplications(withbundleidentifier:) |
| 7 | `LSCopyApplicationURLsForBundleIdentifier` | compiles but `API_DEPRECATED` in `LSInfo.h` — **do not use** | use #6 `urlsForApplications(withBundleIdentifier:)` |
| 8 | `FileManager.urls(for:.applicationDirectory,in:)`, `enumerator(at:includingPropertiesForKeys:options:errorHandler:)`, `skipDescendants()`, `URLResourceKey.isPackageKey/isDirectoryKey/isSymbolicLinkKey/isHiddenKey/contentModificationDateKey/localizedNameKey`, `displayName(atPath:)` | doc + compile | https://developer.apple.com/documentation/foundation/filemanager/enumerator(at:includingpropertiesforkeys:options:errorhandler:) |
| 9 | `NSMetadataQuery` (`predicate`, `searchScopes`, `start()`, `stop()`, `resultCount`, `result(at:)`, `NSMetadataQueryDidFinishGathering/DidUpdate`, `NSMetadataQueryUserHomeScope`), `MDQueryCreate/Execute` | doc + compile | https://developer.apple.com/documentation/foundation/nsmetadataquery |
| 10 | `FSEventStreamCreate`, `FSEventStreamCallback`, `FSEventStreamSetDispatchQueue`, `FSEventStreamStart/Stop/Invalidate/Release`, `FSEventStreamGetLatestEventId`, flags `FileEvents/UseCFTypes/NoDefer/WatchRoot/IgnoreSelf`, `kFSEventStreamEventIdSinceNow` | header + doc + compile | https://developer.apple.com/documentation/coreservices/1443980-fseventstreamcreate , …/1444164-fseventstreamsetdispatchqueue ; `FSEventStreamScheduleWithRunLoop` is deprecated (macOS 13) — do not use |
| 11 | `SMAppService.mainApp.register()/unregister()/status`, `SMAppService.openSystemSettingsLoginItems()` (macOS 13+) | doc + compile + **runtime** | https://developer.apple.com/documentation/servicemanagement/smappservice/register() — **verified 2026-08-19**: an ad-hoc-signed `LSUIElement` `JBar.app` installed to `/Applications` registered successfully (log `login item registered`) and appears as "JBar" in the Login Items list. Registration is skipped (with a menu note) when the bundle runs from outside `/Applications`/`~/Applications`. |
| 12 | `NSStatusBar.system.statusItem(withLength: .variableLength/.squareLength)`, `NSStatusItem.button`, `NSImage(systemSymbolName:accessibilityDescription:)`, `NSApp.setActivationPolicy(.accessory)`, `LSUIElement` | doc + compile | status bar does not retain the item — keep a strong reference. https://developer.apple.com/documentation/appkit/nsstatusbar/statusitem(withlength:) , https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement |
| 13 | `NSApp.activate(ignoringOtherApps:)` | compile (13+) | `NSApp.activate()` no-arg is 14+ only |
| 14 | `String/NSString.applyingTransform(.mandarinToLatin, reverse:false)`, `.stripDiacritics`, `CFStringTransform`, `kCFStringTransformMandarinLatin` | doc + compile + **runtime** ("微信 网易云音乐 Xcode" → "wei xin wang yi yun yin le Xcode") | https://developer.apple.com/documentation/foundation/nsstring/applyingtransform(_:reverse:) ; heteronym caveat in §6.6 |
| 15 | `String.folding(options:[.caseInsensitive,.diacriticInsensitive,.widthInsensitive], locale:nil)` | standard Foundation (not separately compile-tested) | used for name folding |
| 16 | SwiftPM `swift build -c release --arch arm64`, `--show-bin-path`, `.app` assembly, `plutil -lint`, `codesign --force --deep --sign -`, `codesign --verify`, `iconutil -c icns`, `sips`, `open` | **runtime** (real package built; ad-hoc bundle launched; icns generated) | `spctl --assess` says "rejected" for ad-hoc — irrelevant, a locally built bundle has no quarantine xattr |
| 17 | `/Applications` is `drwxrwxr-x root:admin` and user is in `admin` → `cp -R` works without sudo; `~/Applications` fallback | **runtime** (touch test) | |
| 18 | `DispatchSource.makeFileSystemObjectSource` for config hot reload, `os_log`/`Logger(subsystem:)`, `os_signpost` | standard, not separately compile-tested | |
| 19 | `tccutil reset All com.linji.jbar` without sudo | **UNVERIFIED** | used only by the optional uninstall step |

---

## 6. Matching and ranking spec

### 6.1 Normalisation
Names and query: trim; `folding(options:[.caseInsensitive,.diacriticInsensitive,.widthInsensitive])`; store as UTF-8 bytes. Apps: strip `.app`. CJK handled via pinyin aliases (§6.6) plus contiguous substring match on the original name.

### 6.2 Tokenizer (index time)
Split `searchName` on whitespace and `- _ . / ( ) [ ] , : ; & +`, and at lower→Upper and letter→digit transitions (`iTermApp` → `i Term App`; `report2024` → `report 2024`). `initials` = first lowercase char of each token (max 8) packed in a UInt64. `ext` = substring after the last `.` if 1–6 chars, not a hidden file, regular file only → interned `extId`. The per-char `bonus` array uses the same boundaries so tokenizer and scorer agree.

Query: trim; split on whitespace into ≤ 6 terms; each folded; **never** split a term on `-`/`_` (users type `node-gyp`). Semantics = AND, any order; score = sum of per-term scores. A trailing space marks the last term complete (substring required, no fuzzy) to stop result jumping. Query containing `/` or starting with `~` → path mode (§7.5). Query starting with `.` (e.g. `.pdf`) → extension-only filter.

### 6.3 Scorer — fzf-V2-style Smith-Waterman with affine gaps (benchmarked on this Mac)
Two Int16 rows (H = score, C = consecutive-run length), `NEG = Int16.min/2`, O(n·m) per candidate (n ≤ 255, m ≤ 32).

Constants (Int16) — launcher-tuned; fzf's originals in parentheses:
```
SCORE_MATCH = 16 (16)   GAP_START = -3 (-3)   GAP_EXT = -1 (-1)
B_WHITE = 16 (10)  B_DELIM = 14 (9)  B_BOUNDARY = 12 (8)  B_CAMEL = 12 (7)  B_NONWORD = 4 (8)  B_CONSEC = 6 (4)  FIRST_MULT = 2 (2)
```
(Raising boundary bonuses ≥ SCORE_MATCH fixed `vsc` ranking `vas Screaming…` (77) above `Visual Studio Code` (72) with fzf constants.)

Char classes: 0 white, 1 nonword (other punctuation), 2 delimiter (`/ , : ; |`), 3 lower, 4 upper, 5 digit. `bonus[j]` for char j given prev class: word char after white → B_WHITE; after delimiter → B_DELIM; after nonword → B_BOUNDARY; lower→upper or non-digit→digit → B_CAMEL; cur is nonword/delim → B_NONWORD; else 0. Position 0 counts as "after white".

```
func score(q: [UInt8], t: [UInt8], bon: [UInt8]) -> Int16
  if m > n: return NEG
  greedy subsequence check; if fails: return NEG
  row 0: for j: s1 = t[j]==q[0] ? SCORE_MATCH + bon[j]*FIRST_MULT : NEG
                s2 = prevH>NEG ? prevH + (inGap ? GAP_EXT : GAP_START) : NEG
                H[j],C[j],inGap = s1>=s2 ? (s1,1,false) : (s2,0,true); prevH=H[j]
  rows 1..m-1: diagH=NEG,diagC=0,prevH=NEG,inGap=false
     for j: upH=H[j]; upC=C[j]
            s1=NEG; if t[j]==q[i] && diagH>NEG { b=bon[j]; if diagC>0 { b=max(b,B_CONSEC) }; s1=diagH+SCORE_MATCH+b; c1=diagC+1 }
            s2 = prevH>NEG ? prevH + (inGap ? GAP_EXT : GAP_START) : NEG
            H[j],C[j],inGap = s1>=s2 ? (s1,c1,false) : (s2,0,true)
            diagH=upH; diagC=upC; prevH=H[j]
  return max_j H[j]
```
Backtrace (match positions for highlighting, +4 per case-matching char when the query has uppercase) only for the final top ≤ 50 rows. Tie-break: higher score, shorter name, earlier first match, lower item index.

Measured (release, single thread, 400,003 synthetic names, this machine under load 10–18): index build 47–69 ms; `vsc` 3.1–4.8 ms, `gc` 6.8–10 ms, `x` 6.5 ms, `chrome` 3.4 ms, `report pdf` 1.4 ms, `visual studio` 0.7 ms, incl. sort. Extrapolated 1M items ≤ 25 ms single-threaded worst case; with `concurrentPerform` and the incremental cache, 1–5 ms typical.

### 6.4 Pre-filter pipeline (per keystroke)
1. Combined query mask vs item `mask` (`(item & q) == q`) — 8 B/item linear scan, ~1 ms/1M scalar; rejects 75–92% (measured: `vsc` 92.5%, `netw` 87.6%, `chrome` 88.5%, `gc` 76%, `x` 73%).
2. Greedy subsequence scan over folded bytes (memchr-like).
3. DP only for survivors; top-K heap (K = 200) per chunk; merge.
4. Incremental cache: if every new term extends the previous query's term, rescan only the previous match list (fzf does this); on deletion, full scan.
No n-gram inverted index (cannot prune non-contiguous matches without false negatives; costs 100s of MB).

### 6.5 Ranking key and signals
Ordering key = `(tier ASC, finalScore DESC, nameLength ASC, firstMatchPos ASC, itemIndex ASC)`, then **grouped for display**: apps group first (cap `appsFirstCap` = 5 when files also match, else ≤ 8), then files/folders, total ≤ `maxResults` (8).

- **Tiers**: 0 = query equals an app's display/localized/pinyin name (folded, trimmed); 1 = query is a prefix of an app name; 2 = everything else.
- **finalScore** = `textScore` (max over the item's searchable strings; sum over terms) + `initialsBonus` + `typeBoost` + `frecencyBoost` + `recencyBoost` − `depthPenalty` − `junkPenalty`.
- `initialsBonus`: single term ≤ 8 chars equal to `initials` → +60; prefix of `initials` → +40 (makes `vsc` → Visual Studio Code, `gc` → Google Chrome beat random subsequence hits).
- `typeBoost`: app +40, folder +12, document (pdf doc docx pages key numbers md txt xlsx pptx rtf epub) +8, image/video/audio +4, source code +4, other 0, package-internal/hidden −20.
- `frecencyBoost` (Mozilla-style exponential decay, 7-day half-life): per path `(f, last)`; on open `f = f·2^(−Δt/7d) + w` (w = 1, or 2 if launched from a typed query ≥ 2 chars); read `f' = f·2^(−Δt/7d)`; boost = `min(64, 16·log2(1+f'))`. Per-query learning: +30 if the exact current query previously resulted in picking this item (`query_pick` table in history). Tiers dominate, so stale items never beat an exact match.
- `recencyBoost` (files/folders, from mtime): < 1 d +12, < 7 d +8, < 30 d +4, < 180 d +1.
- `depthPenalty`: 2 per path component beyond depth 4 under `~`, cap 12 (direct children of Desktop/Documents/Downloads = depth 2 → none).
- `junkPenalty`: 30 if `junk` flag; extra 10 if name starts with `.` or `~$`.
- Extension term: a term equal to the item's ext (or alias: `jpeg~jpg`, `doc~docx`) → +30 and the term is satisfied (take max, not sum, if it also fuzzy-matches the base name). Term ≥ 8 chars equal to a whole token → +20. Whole query (with spaces) is a prefix of `searchName` → +30 (and tier 1 for apps).

Golden tests (must pass before tuning): `code`/`vsc` → Visual Studio Code; `gc` → Google Chrome; `xc` → Xcode; `wechat`, `微信`, `weixin`, `wx` → WeChat; `report pdf` → `*.pdf` containing "report" above non-PDFs; `chrome` exact above fuzzy; `jbar` → `~/jbar` folder; a recently opened item beats an equally scored stale one; junk-dir file below non-junk file of equal text score.

### 6.6 Pinyin
Apply only when the name contains CJK scalars (U+4E00–9FFF, U+3400–4DBF, U+20000–2A6DF): `applyingTransform(.mandarinToLatin)` then `.stripDiacritics` → space-separated syllables → `pinyinFull` (`weixin`), `pinyinInitials` (`wx`). ICU picks one reading per character (`音乐` → `yin le`, not `yin yue`), so apply a small override table before transliteration (`音乐→yinyue 银行→yinhang 行情→hangqing 长城→changcheng 相册→xiangce 会计→kuaiji 朝阳→chaoyang 乐视→leshi 快乐→kuaile 便签→bianqian 便利→bianli 觉醒→juexing 睡觉→shuijiao 还原→huanyuan 还有→haiyou …`) and emit both variants for chars in a tiny multi-reading set (`乐 行 重 长 朝 便 觉 还 都 发 和 藏 曾 弹 调 干 假 降 校 兴 参 薄 切 省`). 5–20 µs per name; run at index time off the main thread. Each app then has ≤ 4–6 searchable strings; `textScore` = max over them (+20 flat when the initials string matches exactly). OR pinyin chars into the same a–z mask bits.

---

## 7. UX spec

### 7.1 Hotkey
Default `option+space` (Raycast/Alfred default; avoids Spotlight's ⌘Space and the ⌃Space input-source switch). Press toggles show/hide. Config grammar `(cmd|ctrl|option|shift)+key` with key ∈ `space a–z 0–9 f1–f19` and punctuation, mapped to `kVK_*`; hot reload re-registers. On `OSStatus != noErr`: menu line "⚠ Hotkey unavailable", fall back to `ctrl+option+space`. README documents reclaiming ⌘Space (System Settings › Keyboard › Keyboard Shortcuts… › Spotlight › uncheck "Show Spotlight search", then `"hotkey": "cmd+space"`); warn that system symbolic hotkeys silently win.

### 7.2 Panel
`NSPanel` `[.borderless, .nonactivatingPanel, .fullSizeContentView]`, `level .floating`, `collectionBehavior [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]`, `hasShadow`, not movable, hidden on `resignKey`/click outside/hotkey again. Background `NSVisualEffectView(.popover, .behindWindow, .active)`, 16 pt corner radius, hairline border, solid fallback under Reduce Transparency. Width 680 pt; height = 60 pt input + 48 pt × rows (0–8) + 8 pt, max 452 pt; top edge anchored; no animation. Placed on the screen under the mouse (`screen: mouse|main|active`), centred horizontally, input-row centre 1/3 down the visible frame.
Input row: magnifyingglass symbol, borderless `NSTextField` 24 pt, placeholder "Search apps and files", programmatic Edit menu so ⌘V/⌘A work; "PATH" capsule in path mode.
Row: 32 pt icon (lazy, cached, cap 500), 15 pt name middle-truncated with matched chars bold + accent colour, trailing dimmed `~`-abbreviated parent path (≤ 45% width, head-truncated), badge `APP`/`FOLDER`/`EXT`; hairline between the app group and the file group; selection = accent @ 18%, 8 pt radius; hover highlights; click opens.
Empty query: frecency recents (first run: hint row with shortcuts). No results: dimmed "No matches for “q”".

### 7.3 Keys
`↑/↓` or `⌃N/⌃P` (wrap), `PgUp/PgDn` ±8, `Enter` open (no selection → first row), `⌘Enter` reveal in Finder, `⌘C` copy POSIX path (or selected field text), `⌘1…⌘8` open row N, `Tab` path-mode autocomplete (append `/` for folders) or, on a folder row in normal mode, jump into path mode rooted there, `Esc` close + clear query (`restoreQueryOnReopen` false), `⌘,` open config in default editor, `⌘Q` ignored inside the panel. Not in v1: `⌥Enter` Open With, `⇧Enter`, `⌘⌫`, `⌘I`.

### 7.4 Actions
App → `NSWorkspace.openApplication(at:configuration:)` with `activates = true`; file → `NSWorkspace.open`; folder → Finder via `NSWorkspace.open`; reveal → `activateFileViewerSelecting`; copy → `NSPasteboard`. Every open records history and hides the panel.

### 7.5 Path mode
Query starting with `/`, `~` or `~/` lists the directory live (`FileManager.contentsOfDirectory` on a background queue; "Loading…" row after 300 ms); trailing segment filters (prefix, then fuzzy); hidden entries only if the segment starts with `.`; folders first, alphabetical; scrollable beyond 8; `Tab`/`Enter`/`⌘Enter`/`⌘C` as above; depth penalty disabled.

### 7.6 Settings
v1 = hand-edited JSON only (`~/.config/jbar/config.json`, created with defaults, hot-reloaded via `DispatchSource`; invalid JSON → keep last good + "⚠ Config error"; unknown keys ignored). Keys: `hotkey` ("option+space"), `launchAtLogin` (true), `maxResults` (40 — the scrollable result pool), `visibleRows` (8 — rows on screen; a config written before this key existed has its old `maxResults` migrated into it), `appsFirstCap` (5), `screen` ("mouse"), `restoreQueryOnReopen` (false), `showRecentsOnEmpty` (true), `appDirectories` [...], `fileRoots` ["~"], `excludePaths` [...], `excludeNames` [...], `includeHidden` (false), `maxDepth` (12), `maxIndexedItems` (1000000). Paths accept `~` and a trailing `*` glob on the last component.

---

## 8. Menu bar, first run, login item

`NSStatusItem` (template `magnifyingglass`; custom "J" glyph later): **Open JBar ⌥Space** | status line (`Index: N items · updated X` / `Indexing… %` / `⚠ Some folders not accessible — Fix…` / `⚠ Index cap reached` / `⚠ Hotkey unavailable` / `⚠ Config error`) | **Rebuild Index** | **Launch at Login** (checkmark; `SMAppService.mainApp` register/unregister; shows `requiresApproval` state and offers `openSystemSettingsLoginItems()`) | **Open Config File… ⌘,** | **About** | **Quit JBar**. `LSUIElement = true`, activation policy `.accessory`, no Dock icon.
First run: icon appears, hotkey registers, panel auto-opens once with the hint row; apps searchable in ~1 s; Desktop/Documents/Downloads crawled first → the three folder-consent dialogs; login item registered per config.

---

## 9. Build, install, uninstall

`Resources/Info.plist`: `CFBundleIdentifier com.linji.jbar`, `CFBundleExecutable JBar`, `CFBundleName JBar`, `CFBundlePackageType APPL`, `CFBundleShortVersionString`, `CFBundleVersion`, `CFBundleInfoDictionaryVersion 6.0`, `LSMinimumSystemVersion 13.0`, `LSUIElement true`, `NSHighResolutionCapable true`, `NSPrincipalClass NSApplication`, `CFBundleIconFile AppIcon`, the three `NS*FolderUsageDescription` strings. No entitlements (unsandboxed, no hardened-runtime requirement for local ad-hoc).

`make install` (`scripts/install.sh`):
1. `swift build -c release --arch arm64` (bin path via `--show-bin-path`, i.e. `.build/arm64-apple-macosx/release/JBar`).
2. Assemble `build/JBar.app/Contents/{MacOS/JBar, Info.plist, PkgInfo, Resources/AppIcon.icns}`; icon via `sips -z N N` into an `.iconset` (16/32/128/256/512 + @2x) + `iconutil -c icns`; `plutil -lint` the plist.
3. `codesign --force --deep --sign "${CODESIGN_IDENTITY:--}" build/JBar.app`; `codesign --verify --verbose=2`.
4. Quit a running JBar (`osascript -e 'quit app "JBar"'`), remove the old bundle, `ditto` to `/Applications` (admin-group-writable, no sudo; fallback `~/Applications`).
5. `open -a /Applications/JBar.app`; print install path, hotkey, config path. No `launchctl` plist — the app registers its own login item.
Also `make build | app | run | test | uninstall | clean`. A downloaded (quarantined) copy needs `xattr -dr com.apple.quarantine` or right-click › Open; a locally built bundle has no quarantine xattr.

`make uninstall` (`scripts/uninstall.sh`): quit; run `JBar --unregister-login-item` (calls `SMAppService.mainApp.unregister()`); remove bundle(s) from `/Applications` and `~/Applications`; ask (default No) before deleting `~/.config/jbar`, `~/Library/Caches/com.linji.jbar`, `~/Library/Application Support/JBar`; optional `tccutil reset All com.linji.jbar` (**UNVERIFIED** without sudo). Brew cask / notarization deferred to v2.

---

## 10. Performance targets and how they are measured

| target | budget | measurement |
|---|---|---|
| full index, 500k items | < 30 s at utility QoS | `JBar --bench-index`; `log stream --predicate 'subsystem == "com.linji.jbar"'` |
| snapshot load | < 100 ms | `os_signpost` |
| search per keystroke (end-to-end) | < 30 ms p95; apps < 1 ms | signposts + 500k synthetic-name perf test in `JBarCoreTests` (measured 0.3–10 ms at 400k single-threaded on this loaded machine) |
| cold launch → panel visible | < 0.5 s | signpost `main()` → `orderFront` |
| hotkey → panel (warm) | < 50 ms | signpost |
| RSS | < 150 MB (design 60–85 MB + icon cache) | `ps -o rss` |
| idle CPU | ~0 (FSEvents only, no polling) | Activity Monitor, 10 min |
| main-thread hang | none > 4 ms on the search path | Instruments |

Machine-specific note: if the first crawl is slow, check that `~/Library` (incl. `CloudStorage`) and `Creative Cloud Files` are excluded before optimizing the crawler; mds may also be competing (see `DIAGNOSIS.md`).

---

## 11. Implementation order (module by module)

1. **Day 1 — skeleton end-to-end**: `Package.swift` (exists), `Resources/Info.plist`, `scripts/build-app.sh`/`install.sh`, `Makefile`; `AppDelegate` with `.accessory` policy, `StatusMenu` (Quit only), `CarbonHotkey` (⌥Space → log), empty `SearchPanel` toggling. Prove `make install` + TCC/signing path on this machine.
2. **Day 2 — apps**: `AppScanner` (roots, Info.plist/localized names, dedupe, dangling-symlink drop), `Tokenizer`, `Mask`, `Scorer` + golden tests, `Ranking` (tiers, initials, type), `ResultsTable`/`RowView` with highlighting, `AppLauncher`, keys Enter/⌘Enter/⌘C/⌘1–8/Esc.
3. **Day 3 — files**: `Exclusions`, `Crawler` with batched publishing, `IndexStore` flat arrays + arena + dirs table, `Snapshot`, `SearchEngine` actor with cancellation + `concurrentPerform` + incremental cache, 500k perf test.
4. **Day 4 — live**: `FSEventsWatcher` (+ event id persistence), `Frecency` (history.json, decay, query_pick), recents on empty query, path mode + Tab.
5. **Day 5 — product**: `Config` + hot reload, `LoginItem`, first-run flow, folder-denied handling, README, uninstall script, `Pinyin` with override table.
6. **Days 6–7 — dogfood**: tune `Ranking` against golden tests, measure all targets and record them in README, fix TCC re-prompt (self-signed cert) if it occurs.

Engineering rules: zero third-party packages; `Logger(subsystem: "com.linji.jbar")`; every failure → menu line; `JBarCore` ≥ 90% coverage; functions complexity < 10; public API documented.

---

## 12. v1 scope vs later

**v1 IN**: apps + files/folders fuzzy search (ASCII + pinyin + CJK substring), apps-first grouping, path-browsing mode, recents/frecency, open/reveal/copy path, menu bar (status, rebuild, login item, config, quit), JSON config with hot reload, install/uninstall scripts, ad-hoc local build, optional time-boxed Spotlight secondary source (off by default).

**v2 backlog (priority order)**: 1) `⌥Enter` Open With / per-kind default app (folders → VS Code/Cursor) — highest value for this user; 2) query prefixes `a:` `f:` `d:`; 3) window switching; 4) calculator/unit conversion; 5) clipboard history; 6) snippets (needs Accessibility — probably never); 7) web search/URLs/bookmarks; 8) System Settings panes & system commands; 9) iCloud/Google Drive FileProvider indexing; 10) settings window/themes; 11) Liquid Glass `NSGlassEffectView` + custom menu glyph; 12) signed + notarized release, Homebrew cask, auto-update, "Search Spotlight for…" fallback row; 13) SQLite-backed index/history if the binary snapshot proves limiting.

---

## 13. Open questions / UNVERIFIED items

1. ~~`SMAppService.mainApp.register()` behaviour for an ad-hoc-signed `LSUIElement` app on 26.x~~ — **RESOLVED 2026-08-19**: registers successfully from `/Applications`, listed as a Login Item; skipped with a menu note when run from elsewhere.
2. Whether TCC folder grants survive an ad-hoc re-sign on each `make install` — if not, create the self-signed "JBar Dev" certificate before the second rebuild.
3. `tccutil reset All com.linji.jbar` without sudo.
4. `NSGlassEffectView` availability/behaviour (doc only) — v1.1.
5. `import SQLite3`, `fts_open`, `DispatchSource.makeFileSystemObjectSource`, `String.folding` — standard system APIs but not part of the compile test; confirm when first used.
6. Option-only hotkey flakiness after screen unlock (reported on macOS 15.x): keep the fallback combo and surface the `OSStatus`.
7. Real-name benchmark: all matcher timings come from a 400k synthetic corpus; re-measure on the real home index before fixing thread counts, K, and caps.
8. Crawler choice (FileManager.enumerator vs fts) and `maxDepth` (12) / `depthPenalty` start (4) — confirm with the first real crawl (expect 5–30 s when mds is idle).
9. Grouping (apps first, cap 5) vs fully interleaved ranking — decided apps-first for predictability; revisit after a week of dogfooding.
