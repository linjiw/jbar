# Privacy and local data

JBar is a local launcher with development-only Assistant, Organize, and Developer Agent surfaces. It has no
telemetry or JBar cloud service, and ordinary interactive search never sends a query to Spotlight,
OpenAI, or a JBar service. Only after the user types a populated `?` question and presses Return does
JBar start the local Codex client and submit that question, locale, time zone, and the fixed `Indexed
files` scope name to OpenAI. Candidate metadata, result paths, and the local index are not sent in the
current Assistant slice. A populated `!` or `！` request plus Return first sends only the instruction
and fixed scope metadata for a typed search plan. JBar searches all configured roots locally and
stops on an incomplete scan or more than 40 matches. After the user chooses a copy destination, Codex
receives opaque IDs, names, sizes, and modification dates for the matched files, but no source or
destination paths and no file contents. A populated `>`
request plus Return separately starts Developer Agent for
`~/jbar`; its explicitly submitted follow-ups are sent to Codex. The optional `--benchmark` command
can query local Spotlight through a bounded Core Services `MDQuery`; that is an explicit diagnostic
run, not the interactive search path.

“Local” does not mean “non-sensitive” or “encrypted.” Filenames, paths, application names, and past queries can reveal personal or work information. JBar's state files are plaintext/binary local files protected primarily by the current macOS account and filesystem permissions.

## What is stored

| State | Default location | Contents | Retention |
|---|---|---|---|
| configuration | `~/.config/jbar/config.json` | settings, configured roots, exclusions, hotkey, and limits | until edited or deleted; recreated with defaults on the next launch if missing |
| index snapshot | `~/Library/Caches/com.linji.jbar/index-v1.bin` | filename and directory components, item type/flags, extensions, modification times, app bundle IDs/display names/search aliases, and index bookkeeping | atomically replaced as the index is refreshed; rebuildable cache with no promised time-based deletion |
| frecency history | `~/Library/Application Support/JBar/history.json` | exact paths that were successfully opened, scores/timestamps, and up to 200 normalized query-to-path picks | at most 500 paths; low-scoring entries are evicted at the cap and missing targets are pruned at startup, but decay alone does not delete an entry |
| isolated Codex state | `~/Library/Application Support/JBar/CodexHome/` | ChatGPT authentication maintained by Codex plus Codex's local account/state files; JBar code does not parse or copy the token | until the user logs out of this isolated Codex home or removes it |
| agent scratch | `~/Library/Application Support/JBar/AgentScratch/` | owner-only scratch used by Assistant's tool-free planning turn; Developer Agent turns use `~/jbar` | retained as an owner-only empty directory between runs |
| Developer Agent workspace | `~/jbar/` | the user's source repository; Developer Agent may read it, run commands from it, and modify it when asked | controlled by the user and normal repository tools; JBar does not automatically undo agent changes |
| unified log entries | macOS Unified Logging, subsystem `com.linji.jbar` | operational state such as version, counts, timings, request IDs, window geometry, numeric error domain/code, and hotkey registration status | controlled by macOS logging policy, not by JBar |

The index is **metadata-only in the narrow sense that it does not read or store document bodies**. It still reconstructs exact paths from stored directory/name components and therefore can reveal filenames and folder structure. App aliases can include localized names from application bundles. The history is not metadata-only: it includes normalized strings the user typed for successful query picks.

Product-state writes use atomic replacement, refuse symbolic-link targets/parents, bound the bytes read at startup, and create JBar-owned state directories/files with owner-only modes (`0700` directories and `0600` files). These controls reduce accidental exposure and unsafe-file attacks; they do not encrypt the data, erase old filesystem blocks, remove backup copies, or protect an unlocked account from other software running as that user.

## What is not stored by JBar

- document contents;
- submitted Assistant/Organize/Developer Agent messages, plans, answers, command output, or file-change summaries in JBar's index, history, or logs;
- clipboard history;
- keystroke events outside JBar's own focused query field;
- Accessibility or Input Monitoring captures;
- telemetry identifiers or analytics events; or
- a server-side account/profile.

Codex uses an ephemeral thread, but the submitted question and generated answer still pass through
OpenAI's Codex service and are governed by the user's ChatGPT/Codex account and OpenAI's applicable
data controls. “Not stored by JBar” is not a claim that an external service, browser, network, backup,
or operating system retains nothing.

Assistant results, an active Organize preview, and the Developer Agent transcript exist only in memory while their
windows are open. Closing a window discards that JBar UI state and stops its active child/thread; this
does not erase Codex/OpenAI, browser, operating-system, network, or backup records under their own
policies.

## Assistant boundary

Assistant launches the user-installed official `codex` executable directly, without a shell, using
JBar's isolated `CODEX_HOME` and an owner-only scratch working directory. Before the question is sent,
JBar applies the account, provider, model, endpoint, ephemeral-thread, read-only sandbox, network-off,
and no-tool checks listed below. `turn/start.outputSchema` limits the model response to a versioned
`SearchPlan`; JBar additionally rejects unknown fields, a changed scope ID, excessive strings/arrays,
invalid kinds/extensions, inverted date or size ranges, and a result limit above 40.

The model has no file, shell, browser, app, plugin, MCP, web, image, or multi-agent tool. JBar executes
the validated plan over its local immutable index. Name, type, extension, and modification-time
filters do not read file bodies. Because size is not stored in the compact index yet, a size-filtered
plan inspects at most 10,000 locally matched entries and marks the result incomplete if that bound is
reached. Candidate reranking is not sent to Codex in this slice; local ordering is used instead.

## Organize boundary

Organize has two planning turns and a separate native confirmation. Return requests a typed search
plan; JBar searches a complete immutable generation across configured local roots. After at most 40
complete regular-file matches, the user chooses one destination, then Codex receives opaque IDs,
filenames, sizes, and modification dates for only those matches. Filenames therefore leave the Mac
and may be sensitive; source/destination paths, file contents, and unrelated index entries are not
included. Closing or cancelling before Copy changes nothing.

JBar maps returned IDs back to its local snapshot, refuses unsafe path components, and shows every
copy/skip/collision before confirmation. At commit, it reopens the destination without following
symlinks, rechecks identities, opens sources read-only, and creates destinations with `O_EXCL`.
Existing destinations are never overwritten. Originals are never moved, renamed, edited, or deleted.
JBar stores no Undo manifest for this workflow because there is no original mutation to reverse.

## Developer Agent boundary

Developer Agent launches the user-installed official `codex` executable directly, without a shell, using a
JBar-only `CODEX_HOME`. The child environment removes API-project credentials and endpoint variables.
The executable can come from a standard CLI install or the official Codex bundled with an installed
ChatGPT desktop app; JBar itself does not install or bundle Codex. Browser login progress never logs
or renders the authorization URL, account identifier, callback state, prompt, or token.
Before any assisted request is sent, JBar requires:

- ChatGPT account authentication; API-key and Amazon Bedrock accounts are rejected;
- the built-in `openai` provider with no configured OpenAI or ChatGPT endpoint override;
- GPT-5.6 Luna in the live model catalog, with no model fallback;
- approval policy `never`, network-disabled agent tools, and no supplied dynamic tools or selected
  capability roots; and
- browser, web, plugin, app, computer-use, image, hook, skill-discovery, and multi-agent features
  disabled.

Assistant additionally requires an ephemeral read-only thread in JBar's scratch directory, empty
runtime workspace roots, and no instruction sources. Developer Agent additionally requires:

- an ephemeral thread rooted exactly in the existing, user-owned, non-group/world-writable,
  non-symlink `~/jbar` directory, whose device/inode identity is rechecked before each turn;
- the repository's `AGENTS.md` as project context, with every reported instruction source inside it;
- approval policy `never` and a workspace-write sandbox with network access disabled;
- no additional writable root reported outside `~/jbar`; and
- commands and completed file changes shown inline.

Approval policy `never` means shell commands and patches do not pause for a confirmation dialog. A
request to change code can therefore modify the repository. JBar bounds the command output it keeps in
memory, validates reported command working directories and file-change paths, and stops on unexpected
tool families. Closing the window does not undo file changes already made.

The installed Codex 0.149 `workspaceWrite` schema does not provide a complete read restriction. It
constrains declared writable roots (while retaining standard sandbox temporary directories), but the
child can read files that the current macOS account and sandbox otherwise permit. Path validation of
reported events cannot prove what every shell command read. Do not place secrets in this development
workspace, and do not ship this feature until restricted-read behavior is available and verified.

Codex itself needs network access to authenticate and produce the model answer. “Network disabled”
describes the agent's tool/sandbox surface, not the model service connection. The request consumes the
user's own ChatGPT Codex allowance or credits. JBar contains no developer API key or AI proxy, but it
cannot prevent account-level credit use or auto top-up when the user's ChatGPT settings permit them.

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

To disconnect the Codex account used by Assistant and Developer Agent without touching search history or the index, use the official Codex CLI with
`CODEX_HOME` set to the JBar Codex Home and run `codex logout`, or quit JBar and move the
`~/Library/Application Support/JBar/CodexHome` folder to Trash in Finder. Inspect the exact folder
before removing it; this also removes the isolated ChatGPT sign-in and Codex state.

## User controls and retention gap

- Set `"showRecentsOnEmpty": false` to prevent history rows from appearing when the panel opens with an empty query. This changes display behavior; it does not delete history.
- Choose **JBar menu > Clear Search History…** and confirm **Clear History** to remove remembered opened paths and query choices without changing files, configuration, or the search index. JBar reports success only after the empty history store is written. If that write fails, it warns that the previous on-disk history may return after restart.
- **Rebuild Index** replaces the search index but does not clear history or configuration.
- `make uninstall PURGE=1` offers a source-tree uninstall-and-purge flow. For the narrowest action, prefer the exact-file commands above.

There is not yet a configurable retention duration. History otherwise persists subject to the 500-path/200-query-pick caps, missing-target pruning, and the explicit clearing or deletion controls described above.

## Permissions

The global hotkey uses Carbon and does not require Accessibility or Input Monitoring permission. JBar does not ask for Full Disk Access. macOS may request Files and Folders access when JBar reads configured protected locations. Denied/unreadable roots are skipped or reported as unavailable; granting broader access expands the metadata JBar can index.

Review the supported system/input-language claims separately in [SUPPORT.md](SUPPORT.md), and treat the exact notarized artifact—not a source build—as the unit of release privacy verification.
