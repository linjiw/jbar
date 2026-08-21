# JBar executable UX and compatibility matrix

This checklist is the release evidence plan, not a static claim that every row passed. A code-level fixture is marked **Automated** only when a test exists and is rerun on the candidate commit. A real keyboard/input source/display check is **Physical**. Signature, notarization, Gatekeeper, install, and upgrade checks are **Release**. One level never substitutes for another.

The highest-priority regression is the reported crash/dismissal behavior on macOS Sequoia 15.x (reported as 15.2) with a Simplified Chinese system/input method: pressing Control or Delete must not terminate JBar or unexpectedly close the panel.

## 1. Record the test environment

Run and attach this header to every physical/release session:

```bash
git rev-parse HEAD
sw_vers
uname -m
sysctl -n hw.model
defaults read -g AppleLanguages
defaults read com.apple.HIToolbox AppleSelectedInputSources

# For an assembled candidate:
lipo -archs JBar.app/Contents/MacOS/JBar
xcrun vtool -show-build JBar.app/Contents/MacOS/JBar
codesign --verify --deep --strict --verbose=2 JBar.app
shasum -a 256 JBar.zip 2>/dev/null || true
```

Also record physical keyboard model/layout, active input source, display resolution/scaling, Reduce Motion/Transparency/Increase Contrast settings, whether the app is a source/ad-hoc or exact downloaded candidate, and any other foreground launcher/input utility.

Before starting, note the newest `JBar-*.ips` timestamp under `~/Library/Logs/DiagnosticReports`. After each high-risk batch, confirm the JBar menu-bar item still responds and no newer report appeared. “The panel closed” and “the process crashed” are different failures and must be recorded separately.

## 2. Automated regression map

Run the complete debug and release suites first:

```bash
swift test
swift test -c release
```

Test counts are deliberately omitted because they change with the implementation. The focused commands below explain what evidence to inspect when a failure occurs.

| ID | Behavior under test | Focused command / evidence | Status needed for release |
|---|---|---|---|
| AUTO-VIEW-01 | `visibleRows` 1/8/12/20 drives height, viewport, page stride, overflow peek, and short-screen capacity from one calculation | `swift test --filter PanelGeometryTests` | Automated + Physical |
| AUTO-VIEW-02 | empty models can be installed repeatedly without scrolling nonexistent row zero | `swift test --filter PanelGeometryTests/testEmptyResultsCanBeInstalledRepeatedly` | Automated + Physical on oldest OS |
| AUTO-RECENT-01 | `showRecentsOnEmpty:false` shows only the hint and rejects a stale in-flight response | `swift test --filter PanelGeometryTests/testDisablingRecentsCancelsAndRejectsAnOlderSearchResponse` | Automated + Physical |
| AUTO-IME-01 | Chinese/Korean marked text survives command routing, Escape policy, resign timing, and programmatic clear | `swift test --filter PanelGeometryTests` | Automated + Physical for every required IME |
| AUTO-KEY-01 | `⌘1...⌘8` uses physical ANSI digit key codes; Delete never maps to close | `swift test --filter PanelGeometryTests/testCommandResultOrdinalsUsePhysicalANSIDigitKeys` | Automated + Physical layouts |
| AUTO-PATH-01 | readable empty vs missing/unreadable path, exact totals, truncation, hidden filtering, ordering, bounded top-K, 1k/20k directories, and supersession | `swift test --filter PathModeStreamingTests` | Automated + Physical filesystem smoke |
| AUTO-APP-01 | Finder display name, localized aliases, bundle metadata, symlink deduplication, deterministic parallel reads, and shared item cap | `swift test --filter AppScannerTests` | Automated + Physical system-language check |
| AUTO-OPEN-01 | async app failure never records history; success records only after LaunchServices confirmation; dead history is pruned/persisted at startup | `swift test --filter AppLauncherTests` | Automated + Physical real app/failure |
| AUTO-CONFIG-01 | range/size validation, legacy row migration, no-symlink bounded reads, atomic writes, and hot-reload last-good behavior | `swift test --filter ConfigTests` | Automated + Runtime |
| AUTO-STATE-01 | owner-only atomic state, symlink/special-file refusal, and oversized history rejection | `swift test --filter SecureFileIOTests` | Automated + Runtime permission inspection |
| AUTO-BENCH-01 | schema-1/workload-2 matrix, deterministic in-memory history, complete/non-cancelled responses, exact ordered-row + total parity, sample bounds, isolated state, safe report output, and no cross-tool speedup wording | `swift test --filter BenchmarkTests`; `scripts/tests/benchmark-report-gate.rb --self-test`; `scripts/tests/benchmark-release-tests.sh` | Automated + repeated benchmark evidence |
| AUTO-APPKIT-01 | packaged-clone `NSApplication` lifecycle; dispatched Control `flagsChanged`, text, Delete, Down, Return; panel remains visible until the exact second fixture is recorded; clean termination and bounded crash-report diff | `scripts/tests/appkit-smoke.sh /absolute/path/JBar.app /absolute/new-evidence-directory` | Automated packaged smoke + Physical IME/keyboard + Release artifact |

Automated marked-text tests instantiate AppKit text components and real marked-string state, but they do not launch the macOS candidate window or exercise a specific OS/input-method implementation. Never label a physical IME cell “pass” from these tests alone.

`AUTO-APPKIT-01` launches a private, ad-hoc re-signed clone with a derived bundle identifier and an
in-memory fixture. It deliberately bypasses the real hotkey, index, history, login item, and
`NSWorkspace`. Its queued AppKit events catch panel/event-routing/lifecycle regressions, but they do
not prove a physical Control/Delete path, a particular IME, LaunchServices, Gatekeeper, or
notarization. CI retains the bounded JSON, PNG, marker, logs, and crash-report diff for each matrix
runner.

## 3. Sequoia 15.x Simplified Chinese crash regression

Run this first on the reporting Mac with the Chinese system language and the exact candidate artifact.

### CHN-CTRL — Control and input-source switching

1. Launch JBar and confirm the menu-bar item is present.
2. Open the panel and leave the query empty.
3. Press and release the left Control key 20 times, then the right Control key if present.
4. Hold Control for five seconds, release it, and type a normal ASCII query.
5. With Control-Space configured as macOS input-source switching, switch English → Simplified Chinese Pinyin → English ten times while the panel is open.
6. Repeat while a Pinyin composition/candidate window is active.

Expected: Control alone neither closes the panel nor launches an item; input-source switching follows macOS; the field remains editable; the process/menu item remains alive; no crash report appears.

### CHN-DEL — backward/forward Delete

1. Open the panel with an empty query and press Delete 20 times.
2. Type `abcdef`, press Delete once, then hold Delete until empty.
3. Type several Chinese syllables without committing. Press Delete repeatedly inside the marked text and candidate window.
4. Commit Chinese text, then press Delete and hold Delete.
5. Repeat with Fn-Delete/forward Delete on hardware that supports it.

Expected: editing is owned by AppKit/IME; no Delete variant closes or crashes JBar; search results follow committed/current field text; empty-result transitions do not throw an AppKit range exception.

### CHN-ESC — composition before panel dismissal

1. Start a multi-syllable Pinyin composition and show the candidate window.
2. Press Escape once.
3. If marked text remains, press Escape again as needed until the IME finishes/cancels it.
4. With no marked text left, press physical Escape.

Expected: Escape is first available to the IME. JBar closes only on a physical unmodified Escape when no marked text exists. A candidate-window focus/resign transition must not dismiss or terminate the process.

### CHN-CMD — shortcuts during composition

1. Start marked Pinyin text.
2. Exercise the input method's candidate navigation/selection commands, including any Command-modified binding it uses.
3. After committing, verify Return, ⌘Return, ⌘C, and physical ⌘1...⌘8 perform their documented JBar actions.

Expected: while text is marked, commands are returned to AppKit/IME and JBar does not open the wrong row. After commit, launcher shortcuts work normally.

For every failure, record whether it occurs on key-down or key-up, whether text is marked, the active input source ID, and whether the process exited, hung, or merely hid the panel.

## 4. Input-source and keyboard-layout matrix

Repeat the Control/Delete/Escape/commit/navigation core for each required input source:

| ID | System/input source | Required additions | Current release evidence |
|---|---|---|---|
| IME-ZH-01 | Simplified Chinese Pinyin | full CHN suite; candidate-number selection; NFC/NFD filename search | Physical pending |
| IME-ZH-02 | Shuangpin | marked text, Delete, Escape, candidate selection | Physical pending |
| IME-ZH-03 | Wubi | marked text, Delete, Escape, commit | Physical pending |
| IME-KO-01 | Korean 2-Set | compose/decompose syllables, held Delete, focus change | Physical pending |
| IME-JA-01 | Japanese Romaji | conversion candidates, Escape stages, Return commit vs open | Physical pending |
| IME-JA-02 | Japanese Kana | direct Kana entry, Delete, candidate commands | Physical pending |
| KEY-US-01 | US | all documented shortcuts | Physical pending |
| KEY-FR-01 | French AZERTY | physical ⌘1...⌘8 and configured physical-letter hotkey | Physical pending |
| KEY-DE-01 | German QWERTZ | Y/Z position expectations and physical digits | Physical pending |
| KEY-DV-01 | Dvorak | physical hotkey position and physical digits | Physical pending |

For each non-US layout, explicitly state that hotkey letter/digit tokens mean US-ANSI **physical positions**, not the glyph currently printed by the input source. Verify that switching sources does not move the registered shortcut.

Run at least one English system-language session, one Simplified Chinese system-language session, and one RTL system-language smoke. JBar's own UI is expected to remain English in v1; the purpose is layout/input safety, not a translation claim.

## 5. Viewport, scrolling, and visual review

### VIEW-POOL — pool versus viewport

1. Set `maxResults: 40`, `visibleRows: 8`, then search for a term with more than 40 matches.
2. Confirm exactly eight full rows are visible plus a next-row peek when overflow exists.
3. Use arrows/trackpad to reach results beyond row eight.
4. Use Page Down/Up and confirm movement is eight rows.
5. Scroll away from the top and press ⌘1; confirm it targets result 1 overall, not the first currently visible row.

Expected: the 40-row result pool remains navigable while the window height remains an eight-row viewport. The shortcut's pool-relative behavior is explicit and must not be mistaken for a visible-row shortcut.

### VIEW-CONFIG — supported heights and hot reload

Repeat with `visibleRows` 1, 3, 8, 12, and 20. Change the value while the panel is open and a query is active.

Expected: panel, table, peek, and page stride reflow together; selection stays valid; query text is unchanged. Invalid 0/21 values are rejected and the last valid configuration remains active.

### VIEW-SHORT — small/multiple displays

1. Use the smallest required built-in/scaled resolution and set `visibleRows: 20`.
2. Open on `screen: mouse`, then test `main` and `active`.
3. Move between Retina/non-Retina displays and change resolution while the panel is open.

Expected: the screen-limited effective row count controls height and Page Down together; the window stays inside the visible frame; widths never become negative; overflow remains discoverable.

### VIEW-A11Y — appearance and assistive technology

Capture evidence in light/dark appearance, Reduce Transparency, Increase Contrast, and Reduce Motion. Check long Latin/CJK/RTL filenames, long parent paths, PATH count badges, focus/selection contrast, and 200% zoomed screenshots. Perform a VoiceOver keyboard smoke for the query field, result name/kind/path, and PATH completeness label.

Any visual issue gets a screenshot plus OS/display settings. UI review is iterative: fix, rerun the same cell, then run adjacent appearance/display cells before accepting it.

## 6. Recents, localization, and action correctness

### RECENT-OFF

1. Successfully open several files through JBar.
2. Set `showRecentsOnEmpty: false` and hot reload.
3. Start a slow non-empty query, immediately clear the field, and wait for the old query to finish.

Expected: only the hint/indexing row appears; no prior or stale result paints later. Confirm `history.json` still exists—this setting hides, not deletes, history.

### RECENT-PRUNE

1. Successfully open one persistent fixture and one temporary fixture.
2. Quit JBar, delete only the temporary fixture, then relaunch.
3. Open with an empty query and inspect a redacted copy of history locally.

Expected: startup pruning runs off the UI path, removes the missing target and any query pick pointing to it, persists the result, and keeps the existing target.

### APP-LOCALIZED

1. Under English and Simplified Chinese system languages, choose several apps whose Finder names differ by locale.
2. Compare Finder's displayed app name with the JBar row.
3. Search by the displayed localized name, bundle filename, plist name, another bundled localized name, pinyin full form, and initials where applicable.

Expected: the row follows Finder's current display name; aliases find the same bundle path; highlights align with the displayed string. JBar's own badges/messages remain English.

### OPEN-CONFIRM

1. Open a known working application and verify it activates.
2. Trigger a controlled invalid/nonlaunchable `.app` fixture.
3. Test a document, folder, missing stale item, Reveal, and Copy Path.

Expected: app history/panel dismissal happens only after LaunchServices confirms success. Failed or missing opens stay unrecorded and keep the panel available (current feedback may be only a beep). File/folder success records normally. Copy Path places the exact unquoted POSIX path on the general pasteboard, including spaces and non-ASCII.

## 7. Path-mode product checks

### PATH-COMPLETE

Test a readable empty directory, one-entry directory, missing directory, regular file with a trailing slash, and a genuinely unreadable/protected directory.

Expected: readable empty is an exact zero; unreadable, missing, not-a-directory, or budget-limited scans show “Folder scan incomplete” with `PATH · ?`, not “No matches.”

### PATH-BOUNDED

1. Browse a directory with more entries than `maxResults × 4`.
2. Test unfiltered, common prefix, selective, fuzzy, and `.` hidden-entry filters.
3. Type and delete quickly while enumeration is running.

Expected: prefix group precedes fuzzy; fuzzy score precedes folder preference except at equal score; ties are deterministic; only the bounded best rows are retained; `PATH · shown/total` exposes truncation; newer queries cancel old scans and partial rows never flash.

Use the explicit isolated distribution when recording latency:

```bash
JBAR_RUN_PATH_BENCHMARK=1 swift test -c release \
  --filter PathModeStreamingTests/testPathModeTwentyThousandIsolatedReleaseBenchmark
```

The semantic and catastrophic-regression gates remain automated, but the older local timing distribution is not current-candidate evidence. Re-run this command on the candidate and retain every sample; do not copy values from another machine or source state.

## 8. Performance and soak

Run the reproducible harness without selecting a best run:

```bash
scripts/benchmark-release.sh 100
JBAR_BENCHMARK_INCLUDE_REAL=1 scripts/benchmark-release.sh 100
```

The current local release-mode record uses report schema 1, workload 2, and fixture generator 2. It was generated at 2026-08-21T00:20:08Z from clean candidate commit `183fc3c2e526e21dccc7976203e5f00ba371426c` and ran 300k, 500k, and 1M fixtures in three sequential independent processes per size with 100 observations per full-scan/sequence/supersession cell. The opt-in real crawl was disabled for this formal campaign. Every response expected to complete had to be complete and non-cancelled; deliberately superseded older requests had to cancel. Repeated queries across cold/warm/typing/deletion/supersession had to preserve the complete ordered rows and exact total. The harness also required cross-process corpus/history/config/workload identity plus source/tool/binary/checksum manifests.

On the recorded Apple M4 Mac16,12 / 16 GiB / macOS 26.5.2 machine, the synthetic ranges were:

| items | cold `x` p50 range | serial typing `r` p50 range | newest supersession p50 range | cancellation correctness |
|---:|---:|---:|---:|---:|
| 300k | 43.689–55.232 ms | 71.341–84.240 ms | 13.419–14.085 ms | older 300/300 cancelled; newest 0 unexpected |
| 500k | 90.123–90.996 ms | 132.956–143.578 ms | 22.625–24.058 ms | older 300/300 cancelled; newest 0 unexpected |
| 1M | 171.521–181.592 ms | 251.063–269.888 ms | 40.284–45.404 ms | older 300/300 cancelled; newest 0 unexpected |

The complete p95/p99/max distributions and retained high-tail samples live in the evidence reports; do not reduce the table to a best process. Older real-corpus figures are not current evidence because they used a different binary. These are local development observations of engine timing, not key-to-paint UI latency, a cross-machine SLA, or evidence for a notarized release artifact. The current evidence manifest is `7a64cb87…0de6ab`, and its immutable benchmark binary is `ec449660…356654f`.

For a two-hour soak, repeatedly open/hide, type/delete, switch input sources, rebuild, edit config atomically/in place, sleep/wake, attach/detach displays, and open items. Record peak/steady RSS, CPU/energy while idle and indexing, index generation/count, responsiveness, crash/hang reports, and state-file validity after force quit/relaunch. Define acceptance numbers before interpreting the output.

## 9. OS, CPU, and release matrix

The exact required combinations are in [SUPPORT.md](SUPPORT.md). At minimum the release record must contain runtime evidence for macOS 13 Ventura, 14 Sonoma, 15 Sequoia, and the current shipping macOS, across both `arm64` and `x86_64`. Cross-compiling or seeing both `lipo` slices is not Intel runtime evidence.

For the exact downloaded ZIP on a clean Mac:

```bash
codesign --verify --deep --strict --verbose=2 JBar.app
spctl --assess --type execute --verbose=4 JBar.app
xcrun stapler validate JBar.app
lipo -archs JBar.app/Contents/MacOS/JBar
```

Then test first launch, Gatekeeper with quarantine intact, protected-folder consent, hotkey conflict/fallback, login-item approval/relaunch, upgrade replacement, rollback after an injected install failure, and uninstall/purge. Do not use `xattr -d`/`xattr -dr` as an acceptance step.

## 10. Evidence record template

```text
ID:
Result: PASS | FAIL | BLOCKED
Commit:
Artifact SHA-256:
Build/signing: debug | release-ad-hoc | Developer-ID-notarized
macOS version/build:
Mac model / CPU architecture:
System language:
Input source + physical layout:
Display(s) + scaling:
Accessibility appearance settings:
Exact steps:
Observed result:
Process alive after test: yes/no
New JBar crash/hang report: yes/no + path
Screenshot/video/log (redacted) location:
Issue/commit that resolves a failure:
Reviewer/date:
```

A row can be called complete only when its required evidence levels are attached to the candidate commit/artifact. The current repository has meaningful automated coverage, a validated local v2 benchmark campaign, a local Universal 2 package gate, and a packaged synthetic AppKit lifecycle/event smoke. Those do not complete the physical Sequoia Chinese, remaining language/layout, native Intel/OS runtime, Developer ID, notarization, stapling, or Gatekeeper cells; they must remain visibly pending until actually performed on the exact candidate artifact.
