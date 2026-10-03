# JBar CLI for local agents

`jbar-cli` is a standalone Swift executable for macOS 13 and later. It links only to `JBarCore`: it starts no AppKit application, Codex session, account flow, network client, or filesystem watcher. The product name avoids a collision with `JBar` on case-insensitive macOS volumes.

The CLI searches **filenames**, extensions and indexed directory children. It does not search file contents, extract PDF text, or index application display/localized aliases. `.app` bundles found in file roots are named leaf results. Indexing is explicit; search never starts a crawl. A persistent stdio session avoids paying process startup and snapshot decoding for each agent query.

## Build and first search

From an extracted `JBar-CLI-<version>-universal` archive, run the included binary:

```sh
./bin/jbar-cli --version
./bin/jbar-cli index --root "$HOME/Documents" --format json
./bin/jbar-cli search --root "$HOME/Documents" --format json -- "report pdf"
./bin/jbar-cli serve --root "$HOME/Documents"
```

To use `jbar-cli` from any directory, add the archive's absolute `bin` directory to your `PATH`.
The archive requires no Swift toolchain. To build from a source checkout:

```sh
swift build -c release --product jbar-cli
.build/release/jbar-cli --version
.build/release/jbar-cli index --root "$HOME/Documents" --format json
.build/release/jbar-cli search --root "$HOME/Documents" --format json -- "report pdf"
```

Use the same roots, config, depth, item cap and hidden-file options for indexing and searching. Changing one of them selects a separate cache identity. Reordering the same roots does not change the cache identity. Exact duplicate roots are removed after path normalization. Distinct ancestor/descendant roots are rejected because each root's depth boundary is relative to itself; silently discarding a nested scope would omit files. Index those scopes separately, or choose one parent root with sufficient `--max-depth`.

The hardened CLI uses a new cache-policy identity. An index created by the earlier development CLI must be explicitly rebuilt once: it does not retain the diagnostics needed to prove the stricter unsafe/unavailable-root coverage policy. The old file is preserved; search reports a missing current index until `index` succeeds with the same scope options.

```sh
jbar-cli index --root ./Sources --root ./Tests --cache-dir ./.jbar-cache --json
jbar-cli search --root ./Sources --root ./Tests --cache-dir ./.jbar-cache --json -- "search engine"
jbar-cli status --root ./Sources --root ./Tests --cache-dir ./.jbar-cache --json
```

With no `--root`, the CLI reads `fileRoots` from the existing JBar JSON config; a missing default config uses defaults without creating a config file. `--config FILE` chooses another config and errors if that explicit file is missing or invalid. Application directories and launcher preferences are ignored. The `~` root token uses JBar's curated visible top-level home directories, excluding Library, Applications, Public and default exclusions. Incomplete home discovery, including a listing/root allowance overflow or inaccessible home, fails with exit code 4 before loading or building an index; choose explicit roots to avoid silently losing scope. To intentionally index the home directory itself, pass its absolute path instead. Relative CLI paths are resolved against the working directory; config paths normally use the existing absolute/tilde config convention.

Run `jbar-cli help` for options and bounds. `--limit` accepts 1 through 500. `--max-depth` accepts 0 through 64. `--max-items` accepts 1 through 2,000,000. The default config depth is 12 and item limit is 1,000,000.

## Queries and output

| Query | Meaning |
| --- | --- |
| `report pdf` | All filename terms must match; an extension term may satisfy its file extension. |
| `searche` | Fuzzy filename subsequence using JBar's native scorer. |
| `.swift` | Extension-only query. |
| `/Users/name/Documents/rep` | Direct children of that indexed directory, with prefix matches before fuzzy matches. |
| `~/Documents/` | Snapshot listing of direct children; folders precede files on tied scores. |
| `report ` | A trailing space requires the final term to be a contiguous substring. |

Filename queries accept at most six terms. Oversized queries and extra terms are rejected so an agent never silently loses constraints. Directory browsing uses the saved snapshot and stays within indexed, descended directories. Excluded directories, package internals, depth-limited directories and out-of-scope bases cannot be browsed. Replacing a directory with a symlink after indexing does not expose another tree. Paths may no longer exist: search intentionally avoids per-result filesystem checks. Reindex to refresh them.

Use `--format json` for one complete search envelope:

```json
{
  "type": "search",
  "query": "report pdf",
  "source": "snapshot",
  "mode": "filename",
  "elapsedSeconds": 0.0004,
  "startupSeconds": 0.012,
  "totalMatches": 14,
  "totalMatchesIsComplete": true,
  "hasMoreResults": true,
  "returnedCount": 1,
  "index": {
    "schemaVersion": 1,
    "itemCount": 12345,
    "complete": true,
    "freshness": "snapshot",
    "watching": false,
    "stale": false,
    "contentIndexed": false,
    "applicationAliasesIndexed": false
  },
  "results": [
    { "name": "report.pdf", "path": "/Users/name/Documents/report.pdf", "kind": "document", "score": 100, "tier": 2 }
  ]
}
```

This is a shortened illustrative envelope; measured timings and scores vary. Full result records also include modification time in Unix seconds when known and raw JBar item flags. `mode` is `filename`, `extension`, or `directory`. `totalMatches` refers to the selected snapshot; it is exact only when `totalMatchesIsComplete` is true. `hasMoreResults` is omitted when the count is unknown. Returning no matches is successful.

`--format jsonl` emits a `search-metadata` record followed by separate `result` records. `--format paths` emits one raw path per line and errors if any path contains a newline. `--format null` emits NUL-separated paths for safe shell tooling. JSON correctly escapes embedded tabs/newlines and unusual filenames. Text output quotes paths to preserve readable boundaries. Successful machine output uses stdout; one-shot errors are JSON on stderr.

## Persistent agent protocol

Start one process with the same index options:

```sh
jbar-cli serve --root "$HOME/Documents"
```

It emits one `ready` JSON record with index metadata and startup timing. Write one request per line and read one response per request:

```jsonl
{"id":"find-1","query":"report","limit":20}
{"id":"find-2","command":"search","query":"report pdf","limit":40}
{"id":"coverage","command":"status"}
{"command":"quit"}
```

The optional `id` is a string and is echoed in search/status/error responses. A valid JSON object's string ID is retained even when another field is unknown or incorrectly typed; malformed JSON or an invalid ID has no correlation ID. The only request fields are `id`, `command`, `query`, and `limit`; unknown fields and unsupported commands are errors, including unsupported content-search filters. `search` is the default command and requires a query. `status` and `quit` accept only `id` and `command`. The default row limit comes from `--limit`. `quit` responds with `{"type":"bye"}`; EOF also exits normally.

Serve always emits JSONL regardless of the one-shot format option. Requests run sequentially and share a single immutable index generation and native `SearchEngine`, including its candidate and repeated-query caches. A line is bounded to 64 KiB; an oversized or malformed line emits an error and the next line can proceed. CLI queries remain bounded to 4,096 characters and 16,384 UTF-8 bytes. There is no background refresh. After reindexing, restart the process to load the new generation.

## Coverage, freshness and exit codes

`complete` means the crawl completed **within the stated roots, exclusions, hidden-file setting, depth and package policy**. It does not mean every file on the Mac was indexed. Metadata includes these settings, selected roots, snapshot path, build time, generation, directory/item counts, denied paths, unavailable roots, capped directories, unsafe skips and the global cap signal. Excluded directory names are indexed as leaf entries where the core permits, while their children remain excluded. Symlinks are never descended.

An incomplete crawl returns diagnostics and exit code 4. Unexpected directory identity/boundary failures, permission denials and unavailable selected roots all make coverage incomplete. It does not write a new snapshot or replace a previous complete snapshot. If a prior cache exists, it still represents its earlier generation. The core snapshot format is validated and bounded. Loads also validate containment, requested-root presence and depth against the selected scope, including the crawler's synthetic root-parent entries. The cache identity is a configuration fingerprint, not an authenticity signature; use a trusted cache location.

Files are atomically written with mode 0600. Reads and writes use the same opened, validated cache-directory descriptor throughout I/O, so replacing the cache pathname after validation cannot redirect either operation. The final snapshot file and cache directory are opened without following symlinks. The CLI-owned default cache directory is mode 0700 and must belong to the current user. Custom cache directories are not chmodded; a newly created directory is private.

`watching` is always false. Snapshot age remains visible even when `stale` is false; freshness is never a guarantee that current filesystem changes have been captured. By default, searches reject snapshots older than seven days (`--max-age 604800`). `--allow-stale` explicitly permits them. `status` can inspect stale snapshots. Serve rechecks age before each search; a long-lived process can expire. It continues serving status/error records so the agent can reindex and restart it.

| Code | Meaning |
| --- | --- |
| 0 | Successful command, including an empty search. |
| 1 | I/O/runtime failure, invalid config, or unsafe cache directory. |
| 2 | Invalid arguments, query, or stdio request. |
| 3 | Missing, invalid, mismatched, future-dated or stale snapshot. |
| 4 | Incomplete crawl or search. Valid diagnostics may still be returned. |

Invalid serve requests report their code in a `type: "error"` response and do not terminate the process. Runtime I/O failures terminate with code 1. Request errors have no per-request OS exit code because one process serves multiple requests.

## Benchmarking and packaging

Use a Release binary for performance comparisons. Measure the full one-shot wall time separately from `elapsedSeconds` (engine work) and `startupSeconds` (snapshot load/validation or index build/persistence). Serve amortizes the load once; measure request round trips as well as engine latency. Initial indexing throughput depends on filesystem metadata, root distribution, exclusions, directory widths and permission access. Directory queries resolve only their requested directory IDs from arena components and scan the existing item-directory column, retaining at most the last bounded directory lookup and the requested result heap. They never expand every indexed directory to a full path or build another whole-index item map. Ordinary filename searches do not pay directory lookup work.

Benchmarks should use real generated files and report corpus size, filesystem, machine, build flags, snapshot bytes, p50/p95/p99, exact result counts and parity. A filename fuzzy search is not equivalent to a full-content Spotlight query, `find`, or a recursive grep; do not infer a speed ratio from different work. The repository's CLI benchmark and packaging scripts provide repeatable local checks. Build distributable archives in a temporary output directory. The build script checks both universal architectures, applies an ad hoc signature and writes a checksum; distribution signing, notarization and uploading are separate release steps described in [RELEASING.md](RELEASING.md).
