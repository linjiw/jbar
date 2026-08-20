<div align="center">

# JBar

**A keyboard-first launcher for macOS that finds your apps and files in ~1.5 ms — about 360× faster than Spotlight.**

[![CI](https://github.com/linjiw/jbar/actions/workflows/ci.yml/badge.svg)](https://github.com/linjiw/jbar/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey.svg)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org)
[![No dependencies](https://img.shields.io/badge/dependencies-none-brightgreen.svg)](#design)

[Benchmark](https://linjiw.github.io/jbar/) · [Design](docs/DESIGN.md) · [Why not Spotlight?](docs/DIAGNOSIS.md) · [Comparison](docs/COMPARISON.md)

<img src="docs/images/jbar-panel.png" alt="JBar's search panel showing apps grouped above files, with matched characters highlighted" width="820">

</div>

---

Press **⌥Space**, type, hit **Return**. JBar builds and searches its **own index**, so it stays fast and complete even when Spotlight's index is mid-rebuild — which, on the machine this was written for, meant Spotlight could not find *any* of the 1,101 files in `~/Downloads` for over an hour.

No Accessibility permission, no Full Disk Access, no third-party dependencies. Just the standard "Files and Folders" prompt the first time it reads Desktop / Documents / Downloads.

## Why

Spotlight isn't slow because it's badly written — it's a whole-Mac *content* index, and that job makes it fragile in ways a launcher can't tolerate. On 2026-08-19 an unclean shutdown caused macOS to throw away a Spotlight index that had been silently corrupt since 03:27, and spend the next two hours rebuilding 1.77 M records — 34 % of that effort on `node_modules`. Meanwhile `mdfind` returned nothing for ordinary Downloads files.

[`docs/DIAGNOSIS.md`](docs/DIAGNOSIS.md) is the full forensic write-up, with log evidence and the recovery timeline. The conclusion drove the design: **own the index, exclude the junk, rank for launching.**

## Benchmark

Measured on an Apple Silicon MacBook Air (10 cores, 16 GB, macOS 26.5.2), *after* Spotlight had fully rebuilt — so this is Spotlight at its best. Reproduce with `build/JBar.app/Contents/MacOS/JBar --benchmark`.

| | JBar | Spotlight |
|---|---:|---:|
| **Warm search (median)** | **1.5 ms** | 556 ms |
| Worst query (single char `x`) | 2.0 ms | 3,004 ms |
| Cold index build (182 k files) | **2.3 s** | minutes–hours |
| Warm start | 0.1–0.4 s | — |
| Resident memory | **82 MB** | — (system service) |
| Idle CPU | ~0 | 200–400 % while reindexing |
| Permissions | none | system service |

Every keystroke lands inside a single 60 fps frame. Full methodology, per-query numbers, and an honest account of where Spotlight is *better* (it searches file **contents**; JBar searches names) are in [`docs/COMPARISON.md`](docs/COMPARISON.md) and on the [benchmark page](https://linjiw.github.io/jbar/).

## Install

Requires macOS 13+ and Xcode command-line tools.

```bash
git clone https://github.com/linjiw/jbar.git
cd jbar
make install
```

That builds a release `JBar.app`, ad-hoc code-signs it, copies it to `/Applications` (no `sudo`; falls back to `~/Applications`), registers a login item, and launches it. A 🔍 icon appears in the menu bar.

On first search macOS asks to let JBar read Desktop, Documents and Downloads — allow them. That is the only permission it ever needs.

## Usage

Press **⌥Space** and start typing:

| You type | You get |
|---|---|
| `vsc`, `code` | Visual Studio Code (acronym + fuzzy) |
| `xc` | Xcode |
| `微信`, `weixin`, `wx` | WeChat — Chinese names, pinyin, and pinyin initials |
| `报告` | Chinese-named documents |
| `report pdf` | PDFs named "report" (multi-term + type filter) |
| `~/Dow` then `Tab` | browse `~/Downloads/` live |
| `.md` | filter by extension |

### Keys

| Key | Action |
|---|---|
| `↑ ↓` / `⌃N ⌃P` | move selection (scrolls past the visible rows) |
| `Return` | open |
| `⌘Return` | reveal in Finder |
| `⌘C` | copy path |
| `⌘1`–`⌘8` | open row N |
| `Tab` | autocomplete a folder → path-browsing mode |
| `Esc` | close |
| `⌘,` | open the config file |

Apps are grouped first, then files and folders. Ranking combines match quality (an fzf-style scorer), item type, how often and how recently you open things (frecency), and file recency — while de-ranking developer junk (`node_modules`, `.venv`, `vendor/`, build output).

## Configuration

Hand-edit `~/.config/jbar/config.json` — created on first launch, hot-reloaded on save:

| key | default | meaning |
|---|---|---|
| `hotkey` | `"option+space"` | e.g. `"cmd+shift+space"`, `"ctrl+option+space"` |
| `launchAtLogin` | `true` | registers via `SMAppService` |
| `maxResults` | `40` | how many results a query returns — scroll to reach them |
| `visibleRows` | `8` | rows visible without scrolling (panel height) |
| `appsFirstCap` | `5` | max apps before files get their slots |
| `fileRoots` | `["~"]` | what to index |
| `excludeNames` / `excludePaths` | see [DESIGN.md](docs/DESIGN.md#43-exclude-list) | never descended |
| `downrankNames` | build/dist/vendor/… | indexed but de-ranked |
| `includeHidden` | `false` | index dot-files |
| `maxDepth` | `12` | crawl depth |
| `maxIndexedItems` | `1000000` | hard cap |

To reuse **⌘Space**: System Settings → Keyboard → Keyboard Shortcuts → Spotlight → uncheck "Show Spotlight search", then set `"hotkey": "cmd+space"`.

## Menu bar

The 🔍 menu shows index status and offers **Open JBar**, **Rebuild Index**, **Launch at Login**, **Open Config File…**, **About**, **Quit**. Warnings (folder access denied, invalid config, hotkey unavailable) surface here.

## Design

```
Hotkey (Carbon)  →  NSPanel + NSTableView  →  SearchEngine (actor)
                                                    ↓ reads
                          IndexStore  ←  Indexer: AppScanner · Crawler · FSEvents · Snapshot
```

- **`JBarCore`** — pure logic, no AppKit: the index (flat parallel arrays + a lowercase UTF-8 name arena), an fzf-V2-style Smith-Waterman scorer with a 64-bit character-mask prefilter, ranking, pinyin, frecency, config. 90 %+ line coverage.
- **`JBar`** — the AppKit shell: non-activating panel, Carbon hotkey (no Accessibility permission), menu-bar item, launching.
- Index refreshes incrementally via **FSEvents** and persists to a binary snapshot, so a warm start is ~0.1 s.

Full architecture, the verified-API table, and the ranking spec: [`docs/DESIGN.md`](docs/DESIGN.md).

## Development

```bash
make test                       # 306 unit tests (~45 s)
make test-release               # with optimization — enforces perf budgets
make cli Q="visual studio"      # headless search with timings
make bench                      # index size / build time / RSS
build/JBar.app/Contents/MacOS/JBar --benchmark    # head-to-head vs Spotlight
```

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Performance claims need measurements — one proposed optimization in this repo was rejected because it benchmarked *slower* than the code it replaced.

## Uninstall

```bash
make uninstall            # remove the app + login item
make uninstall PURGE=1    # also delete config, cache and history
```

## Troubleshooting

- **Gatekeeper warning** — only for a *downloaded* copy: `xattr -dr com.apple.quarantine /Applications/JBar.app`, or right-click → Open. A locally built bundle is fine.
- **Hotkey does nothing** — another app owns ⌥Space, or the menu shows "⚠ Hotkey unavailable". Change `hotkey` in the config; JBar falls back to `ctrl+option+space`.
- **A folder's files don't appear** — it was denied at the Files-and-Folders prompt → System Settings → Privacy & Security → Files and Folders → enable JBar.
- **Rebuild the index** — menu → Rebuild Index.
- **Diagnostics** — `log show --last 10m --predicate 'subsystem == "com.linji.jbar"' --style compact`

## Requirements

macOS 13 Ventura or later (developed and measured on macOS 26.5). Apple Silicon or Intel. Xcode command-line tools to build.

## License

[MIT](LICENSE) © Linji Wang
