<div align="center">

# JBar

**Launch locally. Find with intent. Organize by copying.**

A native, keyboard-first macOS launcher built with Swift and AppKit.

[![CI](https://github.com/linjiw/jbar/actions/workflows/ci.yml/badge.svg)](https://github.com/linjiw/jbar/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/macOS-13%2B-lightgrey.svg)](#requirements)
[![Universal 2](https://img.shields.io/badge/Universal%202-arm64%20%2B%20x86__64-6b7cff.svg)](#install)

[Website](https://linjiw.github.io/jbar/) · [Install](#install) · [Features](#three-workflows-one-bar) · [Settings](#settings) · [Privacy](docs/PRIVACY.md) · [Design](docs/ASSISTED-WORKFLOWS-DESIGN.md)

<img src="docs/images/jbar-panel.png" alt="JBar showing applications and files in its native macOS launcher" width="820">

</div>

Press **⌥Space**, type, and press **Return**. Ordinary typing searches applications and filenames on
your Mac without starting AI. Three explicit prefixes unlock assisted workflows only when you submit
them:

| Input | Workflow | What happens |
|---|---|---|
| `safari`, `report pdf` | Local Launcher | JBar searches its local app/file index and opens the selected result. |
| `?` or `？` | Assistant | Codex converts natural language into a restricted `SearchPlan`; JBar searches locally and shows file results. |
| `!` or `！` | Copy Organize | JBar finds files across every configured indexed root, asks for a destination, and previews copy/skip actions before Copy is enabled. |
| `>` or `＞` | Developer Agent | Opens a separate Codex development session rooted in `~/jbar`. |

Typing alone never starts Codex. `?`, `!`, and `>` require an explicit **Return**.

> **Developer preview:** JBar is currently ad-hoc signed and not notarized. The current source tree is
> the canonical build for the newest assisted workflows; published GitHub/npm builds may trail it.
> Do not disable Gatekeeper or remove quarantine. See the [support matrix](docs/SUPPORT.md).

## Install

### Build the current source

This is the recommended path for the newest `?`, `!`, and `>` workflows. It requires macOS 13 or
later and Xcode Command Line Tools.

```bash
xcode-select --install             # skip if already installed
git clone https://github.com/linjiw/jbar.git
cd jbar
make install
```

`make install` builds a Universal 2 app, ad-hoc signs and validates it, installs it into
`/Applications` (or `~/Applications` when appropriate), and launches JBar. It never uses `sudo`.

### GitHub Release

The release installer needs neither Xcode nor Swift:

```bash
curl -fsSL https://raw.githubusercontent.com/linjiw/jbar/main/scripts/install-from-github.sh | bash
```

It downloads the latest versioned Universal 2 archive, verifies its SHA-256, signature, bundle
identity, minimum macOS version, and both architectures before installing. Quarantine metadata is
preserved so macOS remains in control of first-launch approval.

### npm

The npm package is a small Node 18+ installer for the same native GitHub Release—not an Electron app
or a second JBar implementation.

```bash
npm install --global @linjiw/jbar
jbar

# Or run the installer once:
npx --yes @linjiw/jbar
```

### First launch

1. Open JBar and approve the ordinary macOS Files and Folders prompts for roots you want indexed.
2. Wait for the menu-bar status to change from **Indexing…** to **Index: _n_ items**.
3. Press **⌥Space**, type an app or filename, and press **Return**.
4. The first submitted `?`, `!`, or `>` request may open an official ChatGPT sign-in page for JBar's
   isolated Codex account state.

JBar does not request Accessibility, Input Monitoring, or Full Disk Access. A protected folder that
you do not approve remains unavailable and makes whole-index assisted operations stop rather than
silently claim a complete result.

## Three workflows, one bar

### 1. Local Launcher

Ordinary input is always local. JBar searches names and metadata in a bounded launcher-owned index;
it does not send the query anywhere and does not depend on Spotlight for interactive results.

Examples:

| Type | Finds |
|---|---|
| `vsc`, `code` | Visual Studio Code through acronym/fuzzy matching |
| `微信`, `weixin`, `wx` | localized application names and pinyin aliases |
| `report pdf` | multi-term filename/extension matches |
| `.md` | Markdown files by extension |
| `~/Dow` then `Tab` | live, bounded path browsing |

Apps can be grouped above files, recent successful choices receive a bounded frecency boost, and
dependency/cache trees such as `node_modules`, `.git`, `.venv`, and `DerivedData` are excluded by
default.

### 2. Assistant — `?` / `？`

Use Assistant when a natural-language description is easier than guessing a filename:

```text
？ 找到上周修改的所有 PDF 报告
? find the presentation I edited this month
```

After Return, Codex receives the submitted question, locale, time zone, and a fixed scope label. It
may return only a validated `SearchPlan` containing name terms, extensions, file kinds, date/size
filters, sort order, and a bounded limit. It receives no index, paths, candidate metadata, or file
tools. JBar executes the plan over one immutable local index generation.

Assistant result interaction:

- single-click selects a file;
- double-click or Return opens it;
- right-click offers **Open**, **Reveal in Finder**, and **Copy Path**;
- the bottom actions reveal/open the exact selected row;
- closing or stopping cancels the bounded search and its one-shot Codex child.

### 3. Copy Organize — `!` / `！`

Copy Organize searches across all configured `fileRoots`, not merely one selected folder:

```text
！ 把所有文件名包含 receipt 的 PDF 复制到按月份整理的文件夹
! copy this month's invoice PDFs into month folders
```

The safety sequence is fixed:

1. Codex creates a restricted metadata search plan.
2. JBar scans the complete local index generation and rejects incomplete results.
3. If more than 40 files match, JBar asks you to narrow the request so every file can be reviewed.
4. You explicitly choose one destination folder.
5. Codex sees only opaque IDs, names, sizes, and dates—not source or destination paths.
6. JBar shows every proposed copy, collision, skip, and planner omission.
7. Only the separate **Copy** button performs native file operations.

Originals are never moved, renamed, edited, or deleted. Existing destinations are never overwritten.
Sources must be user-owned regular files with a single hard link; symlinks, hard links, changed files,
unsafe names, destination races, and incomplete indexes fail closed.

### Developer Agent — `>` / `＞`

Developer Agent is intentionally separate from search and organization. It keeps an ephemeral,
terminal-style Codex conversation rooted in the existing owner-controlled `~/jbar` repository.
Return sends, Shift-Return inserts a newline, Stop interrupts the current turn, and closing the window
stops the app-server child and discards JBar's in-memory transcript.

The agent may edit `~/jbar` when asked. Its window shows commands, bounded output, exit codes, and
reported file changes. It is an advanced development surface, not a general file-management mode.

## Keyboard controls

| Key | Action |
|---|---|
| `↑ ↓` / `⌃N ⌃P` | move through results |
| `Page Up` / `Page Down` | move by the number of visible rows |
| `Return` | open a local result, or explicitly submit `?`, `!`, `>` |
| `⌘Return` | reveal the selected local result in Finder |
| `⌘C` | copy the selected path unless query text is selected |
| `⌘1`–`⌘8` | open result 1–8 using the physical top-row number keys |
| `Tab` | autocomplete a folder in path mode |
| `Esc` | clear; press again on an empty launcher to close |
| `⌘,` | open the JSON config file |

JBar preserves marked-text behavior for Chinese, Japanese, Korean, and other input methods. Hotkey
letters/digits refer to physical US-ANSI key positions, so switching input sources does not move a
configured shortcut.

## Settings

The menu-bar item provides **Open JBar**, **Rebuild Index**, **Clear Search History…**,
**Launch at Login**, **Open Config File…**, build identity, About, and Quit. It also reports index
progress, permission gaps, scan caps, unsafe entries, hotkey conflicts, and config errors.

Advanced settings live in `~/.config/jbar/config.json`, or
`$XDG_CONFIG_HOME/jbar/config.json` when `XDG_CONFIG_HOME` is an absolute path. JBar creates the file
on first launch and hot-reloads valid edits. Invalid values keep the last-known-good configuration
and show a menu warning.

```json
{
  "hotkey": "option+space",
  "launchAtLogin": true,
  "maxResults": 40,
  "visibleRows": 8,
  "appsFirstCap": 5,
  "screen": "mouse",
  "restoreQueryOnReopen": false,
  "showRecentsOnEmpty": true,
  "fileRoots": ["~"],
  "includeHidden": false,
  "maxDepth": 12,
  "maxIndexedItems": 1000000
}
```

Missing keys use defaults; unknown keys are ignored. The generated file also includes the complete
default application roots, exclusions, and downranking lists.

| Setting | Default | Purpose |
|---|---:|---|
| `hotkey` | `"option+space"` | global launcher shortcut; supports `cmd`, `option`, `ctrl`, `shift` plus one physical key |
| `launchAtLogin` | `true` | register with `SMAppService` when JBar is installed in an Applications folder |
| `maxResults` | `40` | scrollable result pool (`1...500`) |
| `visibleRows` | `8` | requested visible rows (`1...20`); short screens reduce it safely |
| `appsFirstCap` | `5` | maximum app rows before file rows (`0...maxResults`) |
| `screen` | `"mouse"` | show on `mouse`, `main`, or `active` screen |
| `restoreQueryOnReopen` | `false` | restore the previous draft when reopened |
| `showRecentsOnEmpty` | `true` | show local recent choices when the query is empty |
| `appDirectories` | system defaults | application roots such as `/Applications` and `~/Applications` |
| `fileRoots` | `["~"]` | file trees included in local search and whole-index `!` search (maximum 128) |
| `excludePaths` | curated defaults | absolute/`~/` paths never descended; final-component `*` globs are supported |
| `excludeNames` | curated defaults | directory names never descended at any depth |
| `downrankNames` | curated defaults | searchable directory trees that receive a junk penalty |
| `includeHidden` | `false` | include dotfiles in the persistent index |
| `maxDepth` | `12` | maximum file-tree crawl depth (`0...64`) |
| `maxIndexedItems` | `1000000` | shared apps+files hard cap (`1...2000000`) |

Changing roots, exclusions, depth, hidden-file policy, or the item cap invalidates the old snapshot
and rebuilds the index. A completed crawl with denied paths or scan caps is not persisted as complete.

To reuse **⌘Space**, first disable “Show Spotlight search” in System Settings → Keyboard → Keyboard
Shortcuts → Spotlight, then set `"hotkey": "cmd+space"`.

## Codex connection

Codex-backed workflows require the official Codex CLI 0.149.0 or newer. JBar looks in supported CLI
locations and inside an installed ChatGPT desktop app; it does not bundle or silently install Codex.

JBar uses a separate `~/Library/Application Support/JBar/CodexHome` and official ChatGPT OAuth. It
does not read the token, accept an API key/provider fallback, or proxy requests through a JBar server.
Each submitted request uses the signed-in user's Codex allowance or credits. Connections fail closed
unless the expected ChatGPT account, OpenAI provider, Luna model, approval policy, tool restrictions,
and workspace boundary are present.

See [PRIVACY.md](docs/PRIVACY.md) for the exact data flow and [ASSISTED-WORKFLOWS-DESIGN.md](docs/ASSISTED-WORKFLOWS-DESIGN.md)
for the complete capability model.

## Privacy and safety

- Local launcher typing, indexing, ranking, recents, and path browsing stay on the Mac.
- The index stores filename/path metadata, not document contents.
- Only a non-empty `?`, `!`, or `>` request explicitly submitted with Return can start Codex.
- Assistant sends the question but never the local index, result paths, history, or files.
- Copy Organize is preview-first, copy-only, no-overwrite, and bounded to 40 reviewed files.
- Owner-only state files use bounded reads and atomic replacement; logs omit raw queries and paths.
- JBar never asks for Accessibility, Input Monitoring, or Full Disk Access.

## Troubleshooting

- **Hotkey does nothing:** another app may own it. JBar reports the conflict and tries
  `ctrl+option+space` as a fallback.
- **A protected folder is absent:** open System Settings → Privacy & Security → Files and Folders.
- **`?` or `!` says indexing is incomplete:** let the crawl finish, fix reported permissions, or use
  **Rebuild Index**. A broad `!` request with more than 40 matches must be narrowed.
- **Codex cannot connect:** install/update the official Codex CLI, then submit a workflow again to
  start a fresh ChatGPT sign-in.
- **Config warning:** use **Open Config File…** and correct the invalid key/value; JBar continues with
  the previous valid settings.
- **Diagnostics:** `log show --last 10m --predicate 'subsystem == "com.linji.jbar"' --style compact`.

## Uninstall

From a source checkout:

```bash
make uninstall
make uninstall PURGE=1   # asks before removing config, index, history, and isolated Codex state
```

See [PRIVACY.md](docs/PRIVACY.md) for selective clearing and retention details.

## Development

```bash
swift test -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete
swift test -c release -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete

scripts/build-app.sh /absolute/temporary/output
scripts/tests/appkit-smoke.sh /absolute/temporary/output/JBar.app
```

Architecture and validation references:

- [Design](docs/DESIGN.md)
- [Assisted workflow design](docs/ASSISTED-WORKFLOWS-DESIGN.md)
- [UX and real-use test matrix](docs/UX-TESTS.md)
- [Privacy](docs/PRIVACY.md)
- [Performance](docs/PERFORMANCE.md)
- [Support matrix](docs/SUPPORT.md)
- [Release process](docs/RELEASING.md)

## Requirements

- macOS 13 Ventura or later
- Apple Silicon or Intel (Universal 2 build)
- Xcode Command Line Tools only when building from source
- official Codex CLI 0.149.0+ only for `?`, `!`, and `>` workflows

## License

[MIT](LICENSE) © Linji Wang
