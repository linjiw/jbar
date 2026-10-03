# JBar 0.2.0 code and safety review

This review covers the performance changes, standalone CLI, index persistence and coverage,
AppKit readiness, prebuilt installation, npm wrapper, and release workflow. Reviewers worked
independently on core logic, CLI boundaries, and distribution, followed by regression checks.

## Resolved findings

| Priority | Finding | Resolution and evidence |
|---|---|---|
| P1 | Valid binary snapshots with matching configuration hashes could introduce paths outside CLI scope | Validate directory topology, selected-root presence and item depth before serving; forged snapshot regression tests reject out-of-scope paths and siblings |
| P1 | Cache-directory validation and path-based reopening permitted parent replacement between checks and I/O | Retain one opened directory descriptor through snapshot reads and atomic writes; deterministic rename-to-symlink tests cannot redirect either operation |
| P1 | Unavailable roots, unsafe omitted subtrees, or truncated app rescans could replace a complete snapshot | Mark the generation incomplete and preserve the last complete cache; tests cover startup, unchanged app rescans, file-budget loss, serial/parallel crawl and incremental replacement |
| P1 | Prebuilt activation and rollback could overwrite or nest into a concurrent installer winner | Use descriptor-pinned transaction directories, native exclusive rename/atomic swap and captured inode identities; race/fault tests preserve unrelated winners and recover the old app |
| P1 | Distribution wrappers executed an installer downloaded separately from the checked artifact | Bundle the reviewed installer in the npm package; GitHub bootstrap verifies a versioned installer asset/checksum before execution |
| P1 | Archive extraction happened before rejecting unsafe topology/types | Validate bounded ZIP member topology and allowed types before extraction in both distribution wrappers |
| P2 | Newly discovered default roots were crawled without refreshing watcher coverage | Restart the watcher when resolved roots change; a rebuild regression test observes a file added under a newly discovered root |
| P2 | Assistant/Organize readiness could accept unsafe or unavailable-root coverage | Gate assisted operations on those diagnostics; UI tests keep private paths out of menu/readiness messages |
| P2 | Invalid typed/unknown-field stdio requests lost a valid correlation ID | Recover the bounded string ID for error replies; protocol regressions preserve request/error correlation |
| P2 | Version bumps broke a hard-coded npm test; release workflow omitted standalone CLI assets/runtime coverage | Derive the npm test version from package metadata; align 0.2.0 versions and check them against the tag; test CLI archives on Intel/Apple Silicon in the mandatory CI matrix |

The scoring shortcut and caches were checked for score/highlight parity, custom bonus arrays,
full-query Unicode behavior, history mutations, time boundaries, store replacement, cancellation
and result-limit changes. Callback coalescing retains atomic publication and serial delivery.

## Distribution and update controls

The GUI snapshot completeness policy is now v3 and the CLI cache identity v2. Earlier caches cannot
prove coverage under the tightened rules, so the GUI recrawls and the CLI requires explicit reindexing.
Configuration and history are preserved.

Protected `main` requires the `Required CI gate`. Release candidates require successful main-push
evidence for the exact tagged commit and re-resolve the tag before publication. Six assets are
published: the app ZIP, standalone CLI archive, reviewed installer, and their three SHA-256 files.
No existing release tag is moved and no asset is overwritten. npm publication is opt-in through
`JBAR_PUBLISH_NPM=true`; it remains pending for this release by the user's choice.

The user authorized updating the installed app after release verification. Installation validates
the new bundle before stopping the exact existing executable, preserves configuration/cache/history,
and uses recoverable activation. It does not disable Gatekeeper or remove quarantine.

## Verification record

The final source passed 714 tests in Debug and 714 in Release, each with zero failures and three
opt-in skips, using `-Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete`.
All 24 npm wrapper/archive tests passed. The fresh 0.2.0 app passed the isolated installer fault/race
suite, including rollback, termination, interrupted recovery, concurrent activation and directory
substitution. The Universal 2 app ZIP passed pre-extraction validation, and the packed npm installer
is byte-identical to its reviewed source. Local logs are in `.build/release-review`; remote CI and
publication results are recorded with the release handoff. Builds and tests use repository scratch directories and deny IP network access;
local Unix sockets remain permitted for existing special-file tests. Remote GitHub push, publication
and the installed-app update are explicitly authorized by the user.

## Explicit limits

This is an ad-hoc developer preview for macOS 13+, with macOS retaining first-launch approval.
Checksums detect corruption and bind downloaded files to the reviewed release asset set; they are
not Developer ID signatures. Custom CLI cache locations must be trusted: scope hashes are not
authenticity signatures. Filename/path search does not index bodies, PDF text, OCR or embeddings.
The measured cold broad-query regressions remain performance work, rather than a claim of universal
speed improvement. Physical permission prompts, keyboard/IME combinations and macOS 13 runtime
coverage remain the documented manual support gates.
