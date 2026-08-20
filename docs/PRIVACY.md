# Privacy and local data

JBar is a local launcher. The application code has no telemetry or network client, and interactive search does not send a query to Spotlight or a JBar service. The optional `--benchmark` command can query the local macOS Spotlight service through a bounded Core Services `MDQuery`; that is an explicit diagnostic run, not the interactive search path.

“Local” does not mean “non-sensitive” or “encrypted.” Filenames, paths, application names, and past queries can reveal personal or work information. JBar's state files are plaintext/binary local files protected primarily by the current macOS account and filesystem permissions.

## What is stored

| State | Default location | Contents | Retention |
|---|---|---|---|
| configuration | `~/.config/jbar/config.json` | settings, configured roots, exclusions, hotkey, and limits | until edited or deleted; recreated with defaults on the next launch if missing |
| index snapshot | `~/Library/Caches/com.linji.jbar/index-v1.bin` | filename and directory components, item type/flags, extensions, modification times, app bundle IDs/display names/search aliases, and index bookkeeping | atomically replaced as the index is refreshed; rebuildable cache with no promised time-based deletion |
| frecency history | `~/Library/Application Support/JBar/history.json` | exact paths that were successfully opened, scores/timestamps, and up to 200 normalized query-to-path picks | at most 500 paths; low-scoring entries are evicted at the cap and missing targets are pruned at startup, but decay alone does not delete an entry |
| unified log entries | macOS Unified Logging, subsystem `com.linji.jbar` | operational state such as version, counts, timings, request IDs, window geometry, numeric error domain/code, and hotkey registration status | controlled by macOS logging policy, not by JBar |

The index is **metadata-only in the narrow sense that it does not read or store document bodies**. It still reconstructs exact paths from stored directory/name components and therefore can reveal filenames and folder structure. App aliases can include localized names from application bundles. The history is not metadata-only: it includes normalized strings the user typed for successful query picks.

Product-state writes use atomic replacement, refuse symbolic-link targets/parents, bound the bytes read at startup, and create JBar-owned state directories/files with owner-only modes (`0700` directories and `0600` files). These controls reduce accidental exposure and unsafe-file attacks; they do not encrypt the data, erase old filesystem blocks, remove backup copies, or protect an unlocked account from other software running as that user.

## What is not stored by JBar

- document contents;
- clipboard history;
- keystroke events outside JBar's own focused query field;
- Accessibility or Input Monitoring captures;
- telemetry identifiers or analytics events; or
- a server-side account/profile.

When the user chooses **Copy Path**, the exact path is placed on the macOS general pasteboard. Other applications may be able to read that pasteboard according to macOS policy. When an item is opened or revealed, LaunchServices/Finder and the destination application can maintain their own recent-item or diagnostic state independently of JBar.

## Logging policy

Normal application logs deliberately omit raw queries, result names, file paths, config paths, snapshot paths, bundle paths, and localized error descriptions. CLI modes invoked explicitly by the user can print paths/results to the terminal because that output is the requested command result. Shell history, terminal scrollback, CI logs, and redirected benchmark output are outside JBar's retention controls.

Do not attach a complete config, history file, snapshot, crash report, or benchmark log to a public issue without reviewing it. Prefer the minimal OS/build/architecture, numeric error, and redacted reproduction steps.

## Clear local data selectively

Quit JBar first so it cannot rewrite a file while it is being removed. These commands target individual known files; they do not recursively delete a home or Library directory.

```bash
osascript -e 'tell application "JBar" to quit' 2>/dev/null || true

# Clear search/open history only.
rm -f "$HOME/Library/Application Support/JBar/history.json"

# Clear the rebuildable index only; it is rebuilt on the next launch.
rm -f "$HOME/Library/Caches/com.linji.jbar/index-v1.bin"

# Reset the default configuration; defaults are recreated on the next launch.
rm -f "$HOME/.config/jbar/config.json"
```

If an absolute `XDG_CONFIG_HOME` was used, the config path is `$XDG_CONFIG_HOME/jbar/config.json` instead of `~/.config/jbar/config.json`. Inspect it before deleting:

```bash
case "${XDG_CONFIG_HOME:-}" in
  /*) printf '%s\n' "$XDG_CONFIG_HOME/jbar/config.json" ;;
  *)  printf '%s\n' "$HOME/.config/jbar/config.json" ;;
esac
```

Deleting JBar state does not remove copies that may exist in Time Machine, another backup product, filesystem snapshots, terminal logs, or crash reports. It also does not reset macOS Files and Folders consent or other applications' recent-item databases.

## User controls and retention gap

- Set `"showRecentsOnEmpty": false` to prevent history rows from appearing when the panel opens with an empty query. This changes display behavior; it does not delete history.
- Choose **JBar menu > Clear Search History…** and confirm **Clear History** to remove remembered opened paths and query choices without changing files, configuration, or the search index. JBar reports success only after the empty history store is written. If that write fails, it warns that the previous on-disk history may return after restart.
- **Rebuild Index** replaces the search index but does not clear history or configuration.
- `make uninstall PURGE=1` offers a source-tree uninstall-and-purge flow. For the narrowest action, prefer the exact-file commands above.

There is not yet a configurable retention duration. History otherwise persists subject to the 500-path/200-query-pick caps, missing-target pruning, and the explicit clearing or deletion controls described above.

## Permissions

The global hotkey uses Carbon and does not require Accessibility or Input Monitoring permission. JBar does not ask for Full Disk Access. macOS may request Files and Folders access when JBar reads configured protected locations. Denied/unreadable roots are skipped or reported as unavailable; granting broader access expands the metadata JBar can index.

Review the supported system/input-language claims separately in [SUPPORT.md](SUPPORT.md), and treat the exact notarized artifact—not a source build—as the unit of release privacy verification.
