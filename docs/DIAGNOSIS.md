# Why Spotlight goes quiet: a forensic case study

This is the investigation that motivated JBar. On **2026-08-19**, on a MacBook Air (Apple Silicon, 16 GB, macOS 26.5.2, 460 GB volume at 95 % full), Spotlight had stopped finding ordinary files — `mdfind` returned **0 of 1,101** files sitting in `~/Downloads` — while `mds` burned 160–400 % CPU for over an hour.

Everything below is measured on that machine with read-only commands (no `sudo`, nothing deleted, no reindex triggered). Paths and project names are anonymized; the numbers, log lines and conclusions are verbatim.

> The short version: **Spotlight was not misconfigured.** Its index had been silently corrupt since 03:27, an unclean shutdown caused macOS to throw it away at the next boot, and it was three hours into rebuilding 1.77 M records — most of that effort spent on `node_modules`. This is a failure mode no amount of Spotlight tuning prevents, and it is why JBar owns its own index.

---

## TL;DR

1. **The index was discarded at boot and was mid-rebuild.** The log shows `Index shut down` → `Creating New Index` → `PRESCAN … fullScan:1 bootCacheUUIDMismatch:1`, then `SyncScanComplete … import records:1,767,279`. Three hours later only ~635 k of those records were in the store. That is why `mdfind` found everything on `~/Desktop` and nothing in `~/Downloads` — Desktop was imported first, Downloads was still queued. Confidence: **high**.
2. **Trigger: an unclean shutdown on top of an already-corrupt store.** 217 `Bad checksum on fetch attributes reply from store` errors between 03:27 and the 14:10 reboot, none in the previous two days, plus a `shutdown_stall` diagnostic 12 s before boot. Confidence: **medium** (the sequence is clear; *why* the store went bad is not proven).
3. **The rebuild is slow because the home directory is full of developer junk.** 34 % of everything indexed under `~` was `node_modules`; a conda install accounted for 336 k files; one project tree held 513 k files. `mds` was observed importing icon assets and conda envs while the user's PDFs waited. Confidence: **high**.
4. **The disk was 95 % full** (9.9 GB free at one point overnight). Near-full volumes are the most commonly cited cause of `mds` thrashing, and this machine's `mds_stores` had dirtied **34 GB in 31 minutes** three days earlier. Confidence: **medium** as a cause, high as a fact.
5. **Nothing was misconfigured.** No Search-Privacy exclusions, all categories enabled, indexing on for every volume, and **132 of 132 real `.app` bundles were in the index** (app lookups took 70–140 ms). The widely-reported "Spotlight can't find my apps" symptom did **not** apply — the problem was *file* coverage during a rebuild, plus ranking.

**Recovery:** at the observed ~23 k items/min it took roughly two hours. By 15:09 the store held 1.99 M items, all 1,192 Downloads files were indexed, and `mds` was back to ~2 % CPU. The prediction held.

---

## 1. Root causes, ranked

### #1 — The index was thrown away at boot and rebuilt from scratch (high / high)

Unified log, `process == "mds" OR "mds_stores"`:

```
14:11:06.659  File metadata index modified by OS older than macOS 16
14:11:07      CIMetaInfoOpenAndLock failed 68 -> Index shut down -> (dozens of) Unlink -> Creating New Index
14:11:10      *** PRESCAN SCAN STARTED fullScan:1 partialUUIDMatch:0 bootCacheUUIDMismatch:1 ***  objectCount:5,387,332
14:14:26      SyncScanComplete result:0 fullScan:1 (import records:1,767,279)
              Indexing resumed (unified)
```

`mdutil -vs /` confirmed `Scan base time` equal to that boot. The store filled live (`mdfind -count 'kMDItemContentTypeTree == "public.item"'`):

| time | total items | under `~` | `~/Downloads` | large project tree |
|---|---|---|---|---|
| 14:18 | 402,557 | 182,268 | 129 | 53,442 |
| 14:29 | 529,541 | 309,898 | 1,897 | 77,601 |
| 14:33 | 634,732 | 416,020 | 12,411 | 80,667 |
| 15:09 | **1,951,729** | 1,295,690 | **1,192 / 1,192** | 162,093 |

≈ 23 k items/min. Per-folder coverage at 14:22 (`find -type f` vs `mdfind -onlyin -count`; the mdfind count includes directories, so >100 % is possible):

| folder | files on disk | indexed |
|---|---|---|
| `~/Desktop` | 501 | 547 (done) |
| `~/Documents` | 51,576 | 110,539 (done) |
| `~/Downloads` | 20,784 | **141** (0 of 1,101 top-level files) |
| `~/projects` | 49,144 | 53,442 |
| media folders | 219 / 146 / 2 | **0** |

A 30-filename sample via `mdfind -name` scored 20/30 — and **all 10 misses were in `~/Downloads`** (PDFs, a PNG, a `.dmg`, Python files). `mdimport -t` on a missed PDF worked fine, so the importers were healthy; the files simply were not in the store yet.

Corroborating symptom: `mdls` on already-indexed home files returned stub attributes (`kMDItemFSName = (null)`, `kMDItemFSSize = 0`, `kMDItemFSContentChangeDate = 1970-01-01`) while `/Applications` and `/usr` files returned real values. **Anything sorting by Spotlight's modification date gets garbage during a rebuild.**

### #2 — Trigger: unclean shutdown over a store corrupt since 03:27 (high / medium)

- `shutdown_stall` diagnostic written 12 s before boot.
- Pre-reboot `mds`: `Bad checksum on fetch attributes reply from store` ×8 at 14:09, then `Event on stores connection: Connection invalid` → `Processing storeRemoved` → `Index shut down starting`.
- `log show --last 3d`: **217** `Bad checksum` lines between 03:27:32 and 14:10:20, in bursts; **none** in the preceding two days.
- No OS update had been installed for three weeks, so this was not update-driven. At reboot macOS invalidated the store (`bootCacheUUIDMismatch:1`; "modified by OS older than macOS 16" is the generic reason string it logs when it decides a store is unusable).
- The volume had been at **9.88 GB free** ~1.5 h before the first checksum error. Causation is unproven, but near-full APFS plus heavy `mds_stores` writes is the leading hypothesis.

### #3 — The rebuild is dominated by developer junk (high / high)

Of 416,020 items indexed under `~` at 14:33:

| pattern | indexed items | note |
|---|---|---|
| `node_modules` | **143,326 (34 %)** | six trees of 8 k–45 k files each |
| `vendor/` (ruby gems) | 63,835 | two static-site repos |
| conda install | 89,489 of **336,814** files | envs + pkgs, still importing |
| `site-packages` | 11,309 | virtualenvs |
| `dist/` | 21,854 | build output |
| iCloud Drive | 49,521 of ~94 k | |

One project directory alone held **512,849 files** excluding `.git` — a single temporary bundle inside it accounted for 218,976 of them, and three virtualenvs for another 114 k. `lsof` on `mdworker_shared` showed it walking per-seed `summary.json` files while user documents waited.

Good news: hidden dot-directories, `~/Library/Caches`, `~/Library/Developer` and `~/Library/Containers` were **not** indexed — Spotlight's built-in rules already skip those. The gap is that it has no notion of "this is a dependency tree, not my work."

### #4 — Disk nearly full (medium / high)

460 GB volume, 413 GB used, 26 GB free (95 %); 9.88 GB free overnight. `mds_stores` had dirtied **34.36 GB in 1,869 s (18.4 MB/s)** three days earlier per a disk-writes diagnostic — the index alone is capable of consuming the remaining headroom.

### #5 — Chronic strain, predating that day (medium / high)

`spotlightknowledged` CPU-resource diagnostics on **six of the previous seven days**; a `corespotlightd` disk-writes report (2.15 GB in 20 h); a Jetsam event overnight. No actual crashes. Spotlight had been working very hard on this volume for at least a week.

### #6 — Minor issues (low)

- 247,607 of 254,143 `mds` log lines in a 15-minute window were `CoreDuet: ClientContext objectForContextualKeyPath:` — noise, not a cause.
- 42 × `[ImportServer] Modified plugin path` plus securityd `Trust evaluate failure: [leaf TemporalValidity]` → a third-party `.mdimporter` with an expired signature, re-validated every boot. Find it with `mdimport -L`.
- `mds_stores`: `Merge slow` ×35, `Stalling qid` ×46, `IVFVectorIndex::unlink failed` ×7 — all expected during a bulk import.

### Ruled out (so you don't chase them)

| hypothesis | verdict | evidence |
|---|---|---|
| Search-Privacy exclusion / category off | **No** | prefs at defaults; `mdutil -s` enabled on every volume |
| Apps missing from the index | **No** | 132/132 real bundles found; app queries 70–140 ms |
| Memory pressure / swap | **No** | 67 % free, swap 0 MB |
| Time Machine | **No** | no destinations, no local snapshots |
| Cloud-sync daemons | **Not today** | Drive/Adobe/iCloud all at 0 % CPU |
| `mdfind` query path broken | **No** | counts rose monotonically throughout |

A note on `kMDItemDisplayName`: on this system it carries the `.app` suffix, so `kMDItemDisplayName == "Safari"` returns nothing while `"Safari.app"` works — and localized apps match only by `kMDItemFSName`. Worth knowing if you query Spotlight for apps.

---

## 2. How to tell when a rebuild has finished

```sh
# Total indexed items — watch it climb toward the "import records" number in the log
mdfind -count 'kMDItemContentTypeTree == "public.item"'

# Is a specific folder covered yet?
mdfind -onlyin ~/Downloads -count 'kMDItemContentTypeTree == "public.item"'

# Workers: done when mdworker_shared is 0–2 processes and mds_stores is < 5 % CPU
ps -axo %cpu,comm | grep -E 'mds|mdworker' | grep -v grep

# Did the store corruption come back?
log show --last 1d --predicate 'process == "mds" OR process == "mds_stores"' | grep -c "Bad checksum"

# Did mdls stop returning stubs? (FSName null / 1970 date == still rebuilding)
mdls -name kMDItemFSName -name kMDItemFSContentChangeDate ~/Downloads/somefile.pdf
```

`timeout` is not installed on stock macOS; bound long commands with `perl -e 'alarm 60; exec @ARGV' -- <cmd>`.

---

## 3. What to do about it

### (a) Safe, no `sudo`

1. **Wait.** A rebuild is a rebuild. Keep the Mac awake and plugged in; do **not** run `mdutil -E`, which restarts it from zero.
2. **Exclude dependency trees** in System Settings › Spotlight › Search Privacy (GUI, no password): `node_modules`, `.venv`, `vendor/bundle`, conda/`miniconda3`, `go/pkg`, build output, and any multi-hundred-thousand-file temp bundle. On the machine studied here this removed **more than 40 %** of the indexing workload. Alternative without the GUI: `touch <dir>/.metadata_never_index` inside the directory.
3. **Also exclude cloud mounts** (`~/Library/CloudStorage`, Creative Cloud) — FileProvider ↔ `mds` feedback loops are a reported Tahoe failure mode.
4. **Free disk space** to ≥ 10–15 % (see (c)).
5. **Audit the Spotlight pane** once: confirm the boot volume is *not* in Search Privacy, and turn off "Show Related Content" / "Help Apple Improve Search" if you want less latency and clutter.
6. **Find any expired third-party importer**: `mdimport -L`, `ls /Library/Spotlight ~/Library/Spotlight`.
7. **Delete dangling `.app` symlinks** — leftovers from uninstalled apps show up as ghost results in every launcher.
8. **Re-measure afterwards** with the commands in §2. If a folder is *still* missing files after the rebuild finishes, that points to a genuine exclusion or importer problem rather than a slow import.

### (b) Only if needed, with `sudo` — run these yourself

Do none of these until a rebuild has finished and you have re-measured. Each one throws the index away and starts a multi-hour scan at 200–400 % CPU.

| command | what it does | consequences |
|---|---|---|
| `sudo du -sh /System/Volumes/Data/.Spotlight-V100` | size of the index store (normal 1–10 GB) | read-only; tens of GB means the index is ballooning |
| `sudo fs_usage -w -f filesys mds_stores` | live view of what `mds_stores` touches | read-only |
| `sudo mdutil -E /System/Volumes/Data` | erase and rebuild the volume index | hours of heavy CPU; Spotlight mostly empty meanwhile |
| `sudo mdutil -i off … && sudo mdutil -i on …` | disable then re-enable indexing | same as above |

Apple's official no-Terminal reindex is: System Settings › Spotlight › Search Privacy › add the drive, wait a few seconds, remove it ([support.apple.com/en-us/102321](https://support.apple.com/en-us/102321)). Prefer that over `mdutil -E`.

### (c) Reclaiming disk space

On the machine studied, ~61 GB was recoverable from pure caches with no data loss. The usual suspects, in rough order of payoff:

```sh
uv cache clean;  npm cache clean --force;  pip cache purge
brew cleanup --prune=all
xcrun simctl delete unavailable                    # stale iOS simulators
rm -rf ~/Library/Developer/Xcode/DerivedData/*     # rebuilt on demand
rm -rf ~/.cache/*                                  # model/tool caches; re-downloaded on demand
```

Then check the big-ticket items by hand: `~/Library/Caches`, downloaded installer `.dmg`s, on-device AI model bundles inside browser profiles, local VM bundles, old AI-CLI session logs, and any media library with "Optimize Mac Storage" available. Measure first — `du -sh ~/* ~/Library/* 2>/dev/null | sort -h | tail -25`.

---

## 4. What was *not* verified

- The causal chain "near-full disk → checksum errors → shutdown stall → discarded index" is inferred from timestamps; only the last two links are directly logged.
- The Search-Privacy list itself lives in a root-only plist and was not read; its emptiness was inferred from behavior.
- Roughly 75 GB of disk usage could not be measured because TCC blocks `du` on protected containers.
- Third-party reports about Tahoe behavior (FileProvider loops, index ballooning) are cited as context, not observed here.

---

## 5. What this means for JBar

This investigation is the design brief:

- **Don't depend on Spotlight for a launcher.** Coverage can be incomplete for hours after any unclean shutdown or OS update, `mdfind` costs 70–140 ms per query (and seconds for common terms), and `kMDItemFSContentChangeDate` reads 1970 during a rebuild.
- **Own the index.** JBar crawls configured roots into an explicit local index and uses FSEvents to request refreshes instead of depending on Spotlight coverage. Current validated crawl/search evidence is recorded separately in [`COMPARISON.md`](COMPARISON.md); it remains local observational evidence, not a cross-machine SLA or a claim that every filesystem transition is gap-free.
- **Exclude the junk by default.** The same trees that dominated the observed Spotlight rebuild — `node_modules`, `.venv`, `vendor/`, conda, `go/pkg`, and build output — are on JBar's default exclude list. In this investigation that produced roughly 182 k JBar items versus roughly 2 M Spotlight records; the ratio is corpus-specific.
- **Rank for launching, not for exhaustive display.** A launcher keeps a bounded result pool, ranks it deterministically, and shows only the rows that fit the configured viewport. Current latency evidence and methodology are recorded separately rather than summarized as “instant.”

See [`COMPARISON.md`](COMPARISON.md) for the current benchmark methodology and non-equivalent Spotlight reference, and [`DESIGN.md`](DESIGN.md) for the architecture that follows from this.
