# JBar assisted workflows: product and interaction design

Status: proposed target design for local iteration. This document does not declare any feature
shipped, signed, notarized, or installed in `/Applications`.

JBar's product promise is:

> Open one lightweight bar, find an app or file immediately, and use a small Codex-assisted workflow
> only when the request is too awkward for ordinary search.

The launcher must remain useful without an OpenAI account, without network access, and without a
microphone. AI is an optional understanding and planning layer; it is not the filesystem, the search
index, or the file-operation engine.

## 1. Product decision

JBar has three progressively more capable surfaces:

1. **Local Launcher** — ordinary typing searches local app/file metadata and opens or reveals a result.
2. **Assistant** — a leading `?`, explicitly submitted with Return, asks Codex to translate natural
   language into a typed plan that JBar validates and executes locally.
3. **Developer Agent** — an explicitly enabled advanced surface for repository work. It may show a
   terminal-style Codex session and is kept separate from general file search and organization.

Voice is an input method for the first two surfaces, not a fourth execution mode. It produces an
editable draft; it never bypasses Return, review, or confirmation.

This separation is the central design choice. A model is good at understanding “the PDFs from Alice
that I edited around tax time.” Native code is better at enumerating files, enforcing scope, revealing
Finder locations, resolving collisions, and performing exclusive native copies. Each layer should do
the job it can make deterministic.

## 2. Final feature list

### 2.1 Local Launcher — core, no account required

- Global hotkey opens a native AppKit palette without a Dock icon.
- Search applications, files, and folders by name and local metadata.
- Fuzzy, acronym, multi-term, extension, CJK, pinyin, and path search.
- Open, reveal in Finder, copy path, and keyboard navigation.
- Local index, bounded work, frecency, exclusions, and hot-reloaded configuration.
- Clear status when indexing, a root is unreadable, a result set is incomplete, or nothing matched.
- No network process and no Codex process during ordinary typing.

### 2.2 Assisted Find — first AI MVP

- `? question` enters Ask mode locally; only Return sends the prompt.
- Sign in with the user's own ChatGPT/Codex account through the official Codex client.
- Use one pinned small-model profile for a release, initially GPT-5.6 Luna at low effort; never silently
  reroute to another model or provider.
- Translate the request into a versioned `SearchPlan` rather than giving the model a raw shell.
- Search the existing local index by root, kind, name, extension, date, size, and bounded metadata.
- Present an answer plus evidence-backed file cards.
- A single click selects a card, a double-click opens it, and its context menu supports Open, Reveal
  in Finder, and Copy Path. Multi-selection remains a later enhancement.
- Show active scope, model/account state, what metadata was shared, and whether results are complete.
- Keep one ephemeral follow-up conversation while the result window remains open.
- Work offline for local search and explain that assisted interpretation is unavailable, rather than
  degrading ordinary launcher behavior.

### 2.3 Assisted content understanding — after metadata search

- Read document content only on demand and only from a bounded candidate set.
- Support plain text first; add PDF and selected office formats through isolated format adapters.
- Show the exact selected files before content leaves the device.
- Bound file count, bytes, extracted characters, and model context.
- Cite every answer to a visible file card and page/section when the adapter can provide one.
- Never build or upload a hidden full-content corpus as part of launcher indexing.

### 2.4 Assisted Organize — whole-index, copy-only milestone

- `! instruction` (or full-width `！`) is the direct Organize shortcut. Nothing starts until Return.
- Search every configured indexed file root locally; do not enumerate the computer again per request.
- Require one explicit destination folder after a complete bounded search, never an implicit write root.
- Produce a complete preview grouped by copy, destination-folder creation, skip, and collision.
- Use stable JBar `FileRef` identifiers in the plan; never trust model-produced absolute paths.
- Execute with native file APIs after a separate confirmation.
- Recheck file identity, source scope, destination scope, ownership, symlinks, and collisions at commit.
- Open sources read-only and create destinations exclusively. Originals are never moved, renamed,
  edited, or deleted; a failed partial destination is removed before it becomes a reported copy.
- Skip or stop safely on partial failure and present per-file outcomes.
- Reject an incomplete index/search or more than 40 matches and ask the user to narrow the request,
  so a displayed preview is never a silent first page of a larger operation.
- No delete, move, arbitrary shell, overwrite, or destructive action in this workflow.

### 2.5 Voice input — local-first and push-to-talk

- A visible microphone button and a configurable press-and-hold shortcut.
- Microphone and speech-recognition permission requested only when the user invokes voice.
- Visible recording state, elapsed time, input level, Cancel, and Stop controls.
- Prefer on-device recognition and require an affirmative runtime capability check for the active
  locale. If unavailable, voice is unavailable in the local-first release; audio is not silently sent
  to a remote recognizer.
- Partial transcription appears in the normal input field and remains editable.
- Releasing Stop ends transcription but does not submit. Return remains the action boundary.
- Contextual vocabulary may include application names and the final path components of locally indexed
  folders, with strict caps; raw index contents are not used as a cloud vocabulary.
- Never always listen, wake on an ambient phrase, retain audio, or start Codex merely because speech
  was detected.

### 2.6 Developer Agent — advanced and visibly separate

- Opt-in development setting or explicit command; not the default meaning of a consumer file query.
- Terminal-style streamed transcript, commands, bounded output, exit status, and file-change events.
- One Codex thread per window with follow-up turns and Stop.
- For JBar development, the deterministic workspace is the real `~/jbar` repository and its
  `AGENTS.md`; other repositories require an explicit folder selection and their own instructions.
- Restricted read roots, restricted writable roots, no agent tool network, no provider fallback, and
  fail-closed validation against the live App Server response.
- Closing the window stops the child process. Repository modifications are not represented as Undoable
  Finder operations and remain normal source-control work.

## 3. Command language and mode routing

| Input | Draft behavior | Return behavior |
|---|---|---|
| `safari` | local results update on each edit | open selected result |
| `~/Downloads/inv` | local path browser | open selected result |
| `?` / `？ 找到我上周修改的三个预算 PDF` | show ASK draft and privacy/scope hint | start Assistant and run a typed read-only plan |
| `!` / `！ 把这些收据按月份整理` | show ORGANIZE draft and local-index/copy-only hint | search globally, choose destination, build preview; never copy yet |
| microphone | transcribe into the same field | do nothing until the user presses Return |

Rules:

- ASCII and full-width Chinese sigils (`?`/`？`, `!`/`！`, `>`/`＞`) are recognized only as the first
  user-perceived character.
- A bare `?` or `!` is a mode hint, not a submission.
- IME marked text is never routed or submitted prematurely.
- Escape clears the current draft first, then closes the palette.
- Ordinary search never becomes AI search automatically because results are weak or empty.
- A model can recommend a different scope, but only the user can grant or select it.

The current development build routes `?` to Assistant and keeps terminal-style Developer Agent behind
the separate `>` route. This separation is explicit in UI copy and tests.

## 4. Scope and session design

“Where does Codex start?” has two different answers:

- **Assistant:** it does not start inside the user's Home directory. Its process working directory is
  an owner-only JBar scratch directory with no useful broad filesystem access. JBar passes a typed plan
  and bounded candidate metadata through the protocol.
- **Developer Agent:** it starts in the explicitly selected repository. The built-in JBar development
  profile uses `~/jbar`.

Assistant scope is represented by chips:

- **Indexed files** — all configured `fileRoots`, read-only search only;
- **Finder folder** — the front Finder window's current folder, after validation;
- **Selected folder…** — a security-scoped or otherwise explicitly authorized folder;
- **Selected results** — only the currently checked file cards.

Organize deliberately searches **all configured indexed file roots**. This is whole-computer in the
JBar sense: the same bounded, exclusion-aware local index configured by `fileRoots`, not an ad-hoc
recursive walk of `/`, system directories, or unreadable volumes. A partial/capped generation is not
eligible. After at most 40 complete matches, the user chooses a destination. Source and destination
identities are captured as stable IDs plus device/inode facts and revalidated before every copy.

Assistant sessions are ephemeral in JBar:

- the App Server starts lazily after the first populated Return;
- one thread is reused while the Assistant window is open;
- every follow-up repeats model, provider, sandbox, scope, and tool-family validation;
- closing the window interrupts the active turn, stops the child, and drops the in-memory transcript;
- no chat-history UI or background agent remains in the first release.

## 5. Recommended UI

### 5.1 Palette

```text
┌──────────────────────────────────────────────────────────────┐
│  ?  找到上周修改的预算 PDF                         ASK  🎙  │
├──────────────────────────────────────────────────────────────┤
│  Search: Indexed files · AI starts only after Return         │
│  ↩ Ask with Codex · Esc clear                                │
└──────────────────────────────────────────────────────────────┘
```

The palette preserves today's compact launcher geometry. The mode badge is text plus color, never
color alone: `LOCAL`, `PATH`, `ASK`, `ORGANIZE`, or `LISTENING`. Draft rows explain the next Return
action and the current scope. They do not show a fake result or indefinite spinner.

### 5.2 Assistant result window

```text
┌────────────────────────────────────────────────────────────────────┐
│  找到 6 个结果                         Indexed files · Luna · Stop │
│  上周修改、名称与预算相关的 PDF。结果按修改时间排列。              │
├────────────────────────────────────────────────────────────────────┤
│  □ FY26 Budget Draft.pdf                    ~/Documents/Finance    │
│    Modified Fri · PDF                 Open  Reveal  Copy Path      │
│  □ 预算讨论.pdf                              ~/Downloads            │
│    Modified Thu · PDF                 Open  Reveal  Copy Path      │
├────────────────────────────────────────────────────────────────────┤
│  AI used your question + metadata for 18 candidates · Details ▸   │
│  Ask a follow-up…                                      Send       │
└────────────────────────────────────────────────────────────────────┘
```

Presentation order is fixed:

1. concise answer/status;
2. evidence/result cards;
3. primary safe actions;
4. privacy/completeness disclosure;
5. follow-up composer;
6. collapsed Agent Details.

Paths are middle-truncated visually but expose the exact path to accessibility and Copy Path. Every
file claim must point to a result card. A file may be opened or revealed without asking the model
again.

### 5.3 Organize review

```text
┌────────────────────────────────────────────────────────────────────┐
│  Copy Organize Review                   23 files → Chosen Folder  │
├────────────────────────────────────────────────────────────────────┤
│  Create  2026-08 Receipts/                                         │
│  Copy    Desktop/receipt-0821.pdf → 2026-08 Receipts/              │
│  Skip    receipt.pdf       —  destination already exists          │
├────────────────────────────────────────────────────────────────────┤
│  1 collision · 0 overwrites · originals remain unchanged          │
│                                      Cancel       Copy 22 files    │
└────────────────────────────────────────────────────────────────────┘
```

The confirmation button states the exact count. Collisions are skipped or the user cancels the batch;
“Replace” is never offered. The preview also shows every model-omitted match as a skip. Closing the
window before confirmation performs no file operation.

### 5.4 Errors and recovery

Errors belong in the relevant window, not only in a beep or log:

- **Old build / unsupported build:** show version, build channel, and “This build does not include
  Assistant.”
- **Not signed in:** open the Codex-provided HTTPS login and keep the callback/process alive.
- **Model unavailable:** name the required profile and do not silently substitute.
- **Offline:** keep local results and offer Retry for assisted interpretation.
- **Permission denied:** identify the affected root and offer Select Folder or macOS Settings guidance.
- **No result:** show applied filters and removable filter chips.
- **Partial result:** say which roots were skipped and avoid claiming completeness.
- **File changed since preview:** remove it from the executable batch and explain why.

## 6. Architecture

```text
hotkey / typing / push-to-talk
             │
             ▼
     IntentRouter (pure, local)
        │                  │
        │ local text       │ explicit ? or ! + Return
        ▼                  ▼
 SearchEngine actor   AssistantCoordinator (MainActor UI owner)
        │                  │
 immutable index           ├── CodexPlannerClient (isolated CODEX_HOME)
        │                  │       └── App Server + fixed small model
        │                  │
        └──────────────► SearchBroker actor
                           │ typed plans / bounded results
                           ├── PresentationBuilder
                           └── FileOperationExecutor
                                   └── preview + commit + undo manifest
```

The App Server is appropriate for account authentication, model discovery, ephemeral threads,
structured turn output, and streamed agent events. The default Assistant must not depend on
experimental dynamic tools. Its first implementation uses `turn/start.outputSchema` to obtain a
strict plan, validates that plan, executes it locally, and fails if the turn emits an unexpected
command, patch, browser, app, MCP, or filesystem tool item.

Later, a narrow tool loop may be evaluated only after the App Server tool interface is stable for the
minimum supported Codex version. The typed broker boundary remains the same either way.

### 6.1 Core types

```swift
struct SearchPlan: Codable, Sendable {
    let schemaVersion: Int
    let scopeID: ScopeID
    let nameTerms: [String]
    let extensions: [String]
    let kinds: [ItemKind]
    let modifiedRange: ClosedRange<Date>?
    let sizeRange: ClosedRange<Int64>?
    let sort: SearchSort
    let limit: Int
    let needsCandidateRerank: Bool
}

struct FileRef: Hashable, Sendable {
    let id: UUID
    let scopeID: ScopeID
    let canonicalPath: String
    let device: UInt64
    let inode: UInt64
    let observedModificationDate: Date?
}

enum ProposedOperation: Codable, Sendable {
    case createFolder(parent: FileRef, name: String)
    case copy(sourceID: UUID, destinationFolderID: UUID, newName: String?)
}
```

The real schema must use bounded string/array sizes and Codable representations that avoid ambiguous
`ClosedRange` or associated-value wire formats. The sketch communicates ownership:

- the model proposes filters and operations;
- JBar creates every `ScopeID` and `FileRef`;
- only JBar resolves an ID to a path;
- only `FileOperationExecutor` mutates the filesystem.

### 6.2 Assisted Find pipeline

1. Router classifies a populated `?` draft; nothing leaves the Mac yet.
2. Return snapshots prompt, locale, time zone, and selected `ScopeID`.
3. Planner turn returns a schema-valid, read-only `SearchPlan`.
4. Validator rejects unknown fields, unsupported operations, excessive limits, invalid dates, and a
   scope other than the one selected by the user.
5. `SearchBroker` runs the plan over local metadata and returns at most 40 `FileRef` results.
6. When semantic reranking is needed, JBar may send at most 40 candidate display names, abbreviated
   parent locations, type, size, and modified date in one bounded rerank turn. It never sends the full
   index or search history.
7. JBar builds cards from authoritative local metadata. Model text cannot invent a result card.
8. Follow-ups may reuse the thread, but each new plan starts from the current selected scope and fresh
   file identity checks.

For simple plan shapes, the Assistant can skip the second model turn and present the local matches
directly. This is the preferred latency and privacy path.

### 6.3 Assisted Organize pipeline

1. Return asks Codex for a typed `SearchPlan`; source paths and metadata are not sent.
2. JBar searches one complete immutable index generation locally across configured roots.
3. JBar rejects incomplete scans and more than 40 matches; apps, folders, packages, links, and special
   files are not eligible.
4. User explicitly chooses one owned destination directory.
5. JBar captures exact source/destination identities and creates `FileRef` values.
6. Codex receives opaque IDs, names, sizes, and dates—not paths—and proposes copy destinations.
7. Validator rejects unknown IDs, escaping names, hidden control characters, unsupported operations,
   cross-scope destinations, and excessive batch size.
8. Review UI renders every matched source as copy or skip, with exact locally derived destinations.
9. Separate confirmation freezes the preview.
10. Executor opens each source read-only and each destination with `O_EXCL`, rechecking identities
    before and after the copy; a racing destination is skipped without overwrite.
11. Result UI reports copied, skipped, failed, and changed-since-preview entries. No inverse/Undo
    operation is necessary because originals never changed.

No agent shell participates in this pipeline.

### 6.4 Voice pipeline

1. User presses the microphone control.
2. JBar requests permission if necessary and immediately shows an observable recording state.
3. `SpeechRecognizerAdapter` checks locale availability and on-device support.
4. Audio buffers stay in memory and feed the system recognizer with on-device recognition required.
5. Partial text updates the normal field through a bounded MainActor cadence.
6. Stop ends audio capture and disposes buffers; Cancel also restores the prior draft.
7. The user edits and presses Return, following the same router and permission rules as typed input.

The adapter isolates the legacy and future Speech APIs from the product state machine. API selection
is an implementation detail validated against the minimum macOS version and physical locale matrix.

## 7. Privacy and security contract

- Ordinary queries, indexes, result selections, and voice drafts stay local.
- Codex starts only after a populated explicit Return.
- JBar uses an isolated `CODEX_HOME`, ChatGPT account authentication, the built-in OpenAI provider, and
  no API-key/provider fallback.
- The submitted question is sent to Codex. Candidate metadata is minimized, capped, and disclosed.
- Audio is never sent to Codex; only the user-reviewed transcript may be submitted.
- Assistant turns use restricted read access to an owner-only scratch root and no writable user-file
  roots. General file access occurs in native JBar code.
- Developer Agent uses explicit restricted read/write roots and no agent tool network.
- File contents are not read or transmitted merely because metadata search found them.
- Mutation is previewed and separately confirmed. Model text is never execution authority.
- Paths, prompts, candidate names, transcript text, and file contents are excluded from normal logs.
- App Server children and audio capture stop when their owning window closes.
- Symlinks, hard-link identity, mount changes, path traversal, Unicode control characters, ownership,
  permissions, TOCTOU changes, and destination collisions receive adversarial tests.
- Release builds show the exact build/version/channel so a stale installed copy cannot masquerade as a
  failed feature.

## 8. Performance and resource budgets

These are acceptance targets, not claims about the current build:

| Path | Target |
|---|---:|
| palette visible after hotkey | p95 ≤ 50 ms |
| ordinary local result update | p95 ≤ 100 ms for representative indexed queries |
| work performed during AI draft typing | no network and no Codex process |
| Ask acknowledgement after Return | visible state ≤ 100 ms |
| planner prompt | ≤ 16 KiB user text plus fixed bounded instructions |
| local candidate result | ≤ 40 records |
| candidate metadata sent for rerank | ≤ 40 records and ≤ 64 KiB serialized |
| assisted model loops before showing a useful state | ≤ 2 by default |
| organize local search and preview batch | complete result set ≤ 40 regular files |
| UI streaming updates | coalesced to ≤ 30 frames/second |
| idle resource use without active voice/Assistant | no audio engine and no Codex child |

All caps must be enforced before allocation or serialization. Cancellation must propagate from UI to
planner turn, local search, content extraction, audio capture, and child process.

## 9. Accessibility and localization

- Full keyboard operation, visible focus, and correct VoiceOver roles/labels/order.
- Status is conveyed with words and symbols, not color alone.
- Result names, paths, progress, collision states, and privacy disclosures have useful accessibility
  text.
- Dynamic Type is not an AppKit contract, so support system font scaling, increased contrast, reduced
  motion, and keyboard focus explicitly.
- Preserve marked text for Chinese, Japanese, and Korean input methods.
- Parse natural-language dates using the user's locale/time zone, but serialize absolute normalized
  ranges to the broker.
- Voice locale follows the chosen recognizer, not an inferred language switch mid-utterance in v1.
- User-facing strings are localized resources before voice ships; English-only debug strings never
  become the release UI by accident.

## 10. Testing and validation

### 10.1 Unit tests

- sigil routing, whitespace, empty payloads, IME marked text, and Return boundary;
- `SearchPlan` decoding, schema versioning, field caps, date normalization, and rejection paths;
- search broker filters, sort, caps, cancellation, incomplete roots, and deterministic cards;
- scope capture and `FileRef` identity validation;
- organize plan validation, collision policies, source-change handling, partial failure, and
  exclusive copy operations;
- voice state machine, permission transitions, capability failure, cancellation, and draft restoration;
- redacted logging and user-facing error mapping.

### 10.2 Integration tests

- fake App Server for auth, model catalog, structured output, streaming, interruption, and malformed
  protocol events;
- fail closed on API-key account, wrong provider, model fallback, tool invocation, broad sandbox, or
  unexpected instruction source;
- verify no child starts and no bytes leave the process during draft typing;
- fixture index → planned query → authoritative cards;
- sources in multiple fixture roots → organize preview → confirm → verify originals and copies;
- changing/replacing a file between preview and commit removes it safely;
- permission-denied and disconnected-volume recovery.

### 10.3 AppKit and accessibility tests

- palette states at short/long prompts and small/large screens;
- keyboard navigation, Return, Shift-Return, Escape, Stop, focus restoration, and existing window raise;
- screen-reader order and action labels;
- login browser focus handoff without losing the callback or Assistant window;
- microphone permission and recording indicators;
- deterministic snapshots for Local, Ask draft, connecting, results, no-result, partial-result,
  organize review, copying, completion, and error states.

### 10.4 Real local end-to-end matrix

Use a distributable-looking app in a fresh temporary directory; never replace `/Applications/JBar.app`
while the feature is still under back-and-forth testing.

- exact Debug and Release strict-concurrency test suites;
- exact candidate artifact on Apple Silicon and Intel;
- signed/notarized build only when entering release validation;
- signed-in, signed-out, expired login, offline, exhausted allowance, and unavailable-model states;
- English and Chinese typed queries, Simplified Chinese IME, and at least one additional IME;
- on-device voice supported/unsupported locales and denied permissions;
- file fixtures containing symlinks, hard links, aliases, unreadable folders, mounted volumes, Unicode,
  extremely long names, collisions, and mid-operation changes;
- Finder reveal, open, copy-path, and multi-selection against the exact displayed file;
- Activity Monitor sampling for idle CPU/memory, hotkey-to-paint, search latency, model latency, audio
  cleanup, child cleanup, and repeated open/close leaks.

### 10.5 Product validation

Measure tasks rather than feature admiration:

- Can a new user find and reveal a known file without learning syntax?
- Does `?` solve a query that ordinary filename search could not, and does the user understand why?
- Can the user identify which files support the answer?
- Does the user know what will be sent to Codex and when?
- Can a user review an organize plan and accurately predict the resulting folders?
- Can the user verify originals are byte-for-byte unchanged and existing destinations untouched?
- Can voice users correct transcription before anything runs?

Run 5–8 moderated sessions for Assisted Find before starting mutation work. Require at least 90% task
completion on the core scenarios, zero unanticipated mutations, zero silent scope expansion, and no
critical privacy misunderstanding before promoting the milestone.

## 11. Delivery plan and gates

Source status (2026-08-25): Phases 0 and 1 are implemented for local development. Assisted Find now
fails closed while the local index is loading, crawling, or known to have hit a scan limit instead of
asking Codex to interpret a known-partial corpus as a complete result set. Phase 3 now has the scoped
ID-only plan, complete whole-index search, explicit copy destination, full preview, and native
exclusive copy commit. Originals are unchanged by construction; performance and physical UI release
matrix gates are still open. Phase 2 and Phase 4 have not started. The separate Phase 5 Developer Agent surface exists,
while restricted-read and packaged release/billing audits remain open.

### Phase 0 — make local builds unambiguous

- Add build channel/fingerprint to About and diagnostic output.
- Show a clear unavailable message when an installed build has no Assistant capability.
- Keep the currently tested Codex Agent source slice local; do not install or ship it.

Exit gate: the user can always tell which binary is running and whether it contains `?` support.

### Phase 1 — Assisted Find, metadata-only

- Implement schema-based planner, SearchBroker, compact result cards, Finder actions, and privacy copy.
- Retain the terminal transcript behind Agent Details for diagnostics.

Exit gate: read-only scenarios pass unit, fake-server, real-account, accessibility, privacy, and
performance tests with no model tool execution.

### Phase 2 — scoped content understanding

- Add explicit selected-file consent, text adapter, then PDF adapter, citations, and byte limits.

Exit gate: every factual file answer is traceable to a selected card; unsupported formats fail clearly.

### Phase 3 — global Copy Organize preview

- Add stable references, two typed plans, complete local-index search, review UI, and deterministic
  copy-only executor.

Exit gate: adversarial multi-root fixtures and interruption/race tests show no overwrite, escape,
source mutation, or unreported partial copy.

### Phase 4 — local-first voice

- Add permissions, on-device capability gating, push-to-talk state machine, partial editable draft,
  accessibility, and physical language tests.

Exit gate: no audio/network activity outside visible recording, reliable cleanup, and acceptable
transcription task completion in the supported locale matrix.

### Phase 5 — Developer Agent hardening

- Move today's terminal slice behind an explicit development surface, adopt restricted read roots from
  the minimum supported App Server, and rerun packaged-app sandbox and billing audits.

Exit gate: repository-only read/write behavior is proven on the exact supported runtime and artifact.

## 12. Explicit non-goals for the first public release

- always-listening voice or a wake word;
- silent AI fallback after weak local results;
- uploading the complete index, search history, Home directory, or background content corpus;
- arbitrary natural-language shell over personal files;
- autonomous background organization;
- permanent delete, overwrite, mass rename without preview, or irreversible cleanup;
- web research, browser control, plugins, apps/connectors, computer use, image generation, or multi-agent
  delegation inside Assistant;
- a general chat-history product competing with the Codex app;
- API-key billing, a JBar AI proxy, or a provider fallback.

## 13. Recommended acceptance scenarios

1. `key` finds and opens Keynote locally with no account or network.
2. `? 找到我上周修改的三个预算 PDF` returns authoritative cards and reveals the selected file.
3. `? Joe 发给我的那份合同` explains that content/email knowledge is unavailable unless the user
   selects candidate files or later enables an explicit connector; it does not fabricate a path.
4. `！ 把电脑里八月的收据按月份整理` searches all configured indexed roots, asks for a copy
   destination, previews every copy/skip, handles a collision without overwrite, and confirms that
   every original remains unchanged.
5. Press-and-hold voice transcribes scenario 2 into an editable draft; Cancel sends nothing and Return
   follows the identical Assisted Find path.
6. With Codex signed out or offline, all ordinary launcher scenarios still work normally.

## 14. Sources informing the integration boundary

- [Official OpenAI Codex App Server documentation](https://learn.chatgpt.com/docs/app-server) — rich
  client integration, authentication, threads, structured turn output, sandbox controls, and streamed
  events. Experimental fields are not required by the proposed Assisted Find MVP.
- [Apple Speech framework](https://developer.apple.com/documentation/speech/) and
  [`supportsOnDeviceRecognition`](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition)
  — live/prerecorded transcription and runtime detection of whether recognition can remain on device.
