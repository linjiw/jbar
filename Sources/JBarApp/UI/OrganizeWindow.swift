import AppKit
import JBarActions
import JBarCore

protocol OrganizePlanning: Sendable {
    func makeOrganizePlan(_ instruction: String, scopeID: String,
                          candidates: [OrganizeCandidate], localeIdentifier: String,
                          timeZoneIdentifier: String, now: Date,
                          openLoginURL: @escaping CodexLoginURLHandler,
                          progress: @escaping PaletteActionProgressHandler) async throws -> OrganizePlan
}

extension CodexTaskSession: OrganizePlanning {}

typealias OrganizeDestinationChooser = @MainActor @Sendable () -> URL?

private enum OrganizeWorkflowError: Error, LocalizedError {
    case incompleteSearch
    case tooManyMatches(Int)
    case noEligibleFiles
    case unsupportedKinds
    case destinationCancelled

    var errorDescription: String? {
        switch self {
        case .incompleteSearch:
            return "The bounded local-index scan was incomplete. Narrow the request; no copy was started."
        case .tooManyMatches(let count):
            let noun = count == 1 ? "file" : "files"
            return "\(count) \(noun) matched, above the 40-file preview limit. Narrow the request so every copy can be reviewed."
        case .noEligibleFiles:
            return "No owner-accessible regular file matched. Apps, folders, packages, and symbolic links are never copied."
        case .unsupportedKinds:
            return "This request targets apps or folders. Copy Organize accepts regular files only."
        case .destinationCancelled:
            return "Destination selection was cancelled. No copy was started."
        }
    }
}

/// Searches the complete local index first, then asks for one explicit copy destination. Source
/// paths are never implicit write scopes because source files are opened read-only and never moved.
@MainActor
final class OrganizeCoordinator {
    private let provider: any SearchProviding
    private let searchPlanner: any AssistantPlanning
    private let organizePlanner: any OrganizePlanning
    private let chooseDestination: OrganizeDestinationChooser
    private let indexStatus: (@MainActor @Sendable () -> IndexStatus?)?
    private var controller: OrganizeWindowController?

    init(provider: any SearchProviding,
         searchPlanner: any AssistantPlanning,
         organizePlanner: any OrganizePlanning,
         chooseDestination: @escaping OrganizeDestinationChooser,
         indexStatus: (@MainActor @Sendable () -> IndexStatus?)? = nil) {
        self.provider = provider
        self.searchPlanner = searchPlanner
        self.organizePlanner = organizePlanner
        self.chooseDestination = chooseDestination
        self.indexStatus = indexStatus
    }

    convenience init(provider: any SearchProviding,
                     searchPlanner: any AssistantPlanning,
                     organizePlanner: any OrganizePlanning,
                     indexStatus: (@MainActor @Sendable () -> IndexStatus?)? = nil) {
        self.init(provider: provider, searchPlanner: searchPlanner,
                  organizePlanner: organizePlanner,
                  chooseDestination: Self.systemDestinationChooser,
                  indexStatus: indexStatus)
    }

    @discardableResult
    func present(instruction: String) -> Bool {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let controller {
            controller.raiseWindow()
            return true
        }
        let newController = OrganizeWindowController(
            provider: provider, searchPlanner: searchPlanner,
            organizePlanner: organizePlanner, chooseDestination: chooseDestination,
            indexStatus: indexStatus
        )
        newController.onClosed = { [weak self, weak newController] in
            guard let self, self.controller === newController else { return }
            self.controller = nil
        }
        controller = newController
        newController.showAndPlan(instruction: trimmed)
        return true
    }

    func close() {
        controller?.endSession()
        controller = nil
    }

    static let systemDestinationChooser: OrganizeDestinationChooser = {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Choose Where JBar Should Put Copies"
        panel.message = "Original files remain where they are. JBar never overwrites an existing destination."
        panel.prompt = "Use as Copy Destination"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.resolvesAliases = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

@MainActor
final class OrganizeWindowController: NSWindowController, NSWindowDelegate {
    var onClosed: (() -> Void)?

    private enum State { case searching, choosingDestination, planning, reviewing, copying, completed, failed }

    private let provider: any SearchProviding
    private let searchPlanner: any AssistantPlanning
    private let organizePlanner: any OrganizePlanning
    private let chooseDestination: OrganizeDestinationChooser
    private let indexStatus: (@MainActor @Sendable () -> IndexStatus?)?
    private let results = ResultsController()
    private var task: Task<Void, Never>?
    private var state: State = .searching
    private var preview: CopyOperationPreview?
    private var ended = false

    private let titleLabel = NSTextField(labelWithString: "Copy Organize Review")
    private let scopeLabel = NSTextField(labelWithString: "All indexed files")
    private let summaryLabel = NSTextField(wrappingLabelWithString: "Preparing a complete copy preview…")
    private let disclosureLabel = NSTextField(wrappingLabelWithString:
        "Search is local. Originals remain unchanged and destination overwrites are impossible.")
    private lazy var cancelButton = NSButton(title: "Cancel", target: self,
                                             action: #selector(cancelPressed(_:)))
    private lazy var copyButton = NSButton(title: "Copy 0 files", target: self,
                                           action: #selector(copyPressed(_:)))

    init(provider: any SearchProviding,
         searchPlanner: any AssistantPlanning,
         organizePlanner: any OrganizePlanning,
         chooseDestination: @escaping OrganizeDestinationChooser,
         indexStatus: (@MainActor @Sendable () -> IndexStatus?)? = nil) {
        self.provider = provider
        self.searchPlanner = searchPlanner
        self.organizePlanner = organizePlanner
        self.chooseDestination = chooseDestination
        self.indexStatus = indexStatus
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 480),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        configureWindow(window)
        buildContent(in: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showAndPlan(instruction: String) {
        guard !ended, let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.center()
        window.makeKeyAndOrderFront(nil)
        if let status = indexStatus?(), let message = IndexReadiness.waitMessage(for: status) {
            finishError(message, codexStarted: false)
            return
        }
        beginPlan(instruction: instruction)
    }

    func raiseWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func endSession() { window?.close() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if state == .copying {
            summaryLabel.stringValue = "Native copy operations are finishing. Keep this window open."
            NSSound.beep()
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard !ended else { return }
        ended = true
        task?.cancel()
        task = nil
        onClosed?()
        onClosed = nil
    }

    static func previewRows(_ preview: CopyOperationPreview) -> [PanelRow] {
        var rows: [PanelRow] = preview.foldersToCreate.map {
            .action(message: "Create destination folder  \($0)/", symbol: "folder.badge.plus")
        }
        for entry in preview.entries {
            let verb = entry.isExecutable ? "Copy" : "Skip"
            let symbol = entry.isExecutable ? "doc.on.doc" : "exclamationmark.triangle"
            let source = sourceDisplay(parent: entry.source.parentDisplay, name: entry.source.name)
            rows.append(.action(message: "\(verb)  \(source) → \(entry.destinationRelativePath)",
                                symbol: symbol))
            if !entry.isExecutable {
                rows.append(.action(message: "Reason  \(entry.explanation)", symbol: "arrow.turn.down.right"))
            }
        }
        return rows.isEmpty ? [.action(message: "No copies proposed", symbol: "tray")] : rows
    }

    static func sourceDisplay(parent: String, name: String) -> String {
        let components = parent.split(separator: "/").suffix(2)
        guard !components.isEmpty else { return name }
        return "…/\(components.joined(separator: "/"))/\(name)"
    }

    static func counted(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }

    /// Force the full 40-result cap and restrict the request to regular-file kinds. A broad request
    /// that exceeds this cap is rejected after the complete index scan instead of silently copying a
    /// partial result page.
    static func copySearchRequest(for plan: SearchPlan) throws -> AssistedSearchRequest {
        let base = AssistedSearchRequest(searchPlan: plan)
        let eligible: Set<ItemKind> = [.document, .image, .video, .audio, .code, .archive, .other]
        let kinds = base.kinds.isEmpty ? eligible : base.kinds.intersection(eligible)
        guard !kinds.isEmpty else { throw OrganizeWorkflowError.unsupportedKinds }
        return AssistedSearchRequest(nameTerms: base.nameTerms, extensions: base.extensions,
                                     kinds: kinds, modifiedAfter: base.modifiedAfter,
                                     modifiedBefore: base.modifiedBefore,
                                     minimumSizeBytes: base.minimumSizeBytes,
                                     maximumSizeBytes: base.maximumSizeBytes,
                                     sort: base.sort, limit: AssistedSearchRequest.maximumResults)
    }

    static func completeCopyRows(from response: AssistedSearchResponse) throws -> [ResultRow] {
        guard !response.cancelled, response.totalMatchesIsComplete else {
            throw OrganizeWorkflowError.incompleteSearch
        }
        guard response.totalMatches <= response.rows.count else {
            throw OrganizeWorkflowError.tooManyMatches(response.totalMatches)
        }
        guard !response.rows.isEmpty else { throw OrganizeWorkflowError.noEligibleFiles }
        return response.rows
    }

    private func configureWindow(_ window: NSWindow) {
        window.title = "JBar Copy Organize Review"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 480)
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier("JBarOrganizeWindow")
        window.setAccessibilityLabel("JBar complete copy-only organize review")
    }

    private func buildContent(in window: NSWindow) {
        let root = NSVisualEffectView()
        root.material = .underWindowBackground
        root.blendingMode = .behindWindow
        root.state = .active
        window.contentView = root

        titleLabel.font = .systemFont(ofSize: 19, weight: .semibold)
        scopeLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .medium)
        scopeLabel.textColor = .secondaryLabelColor
        scopeLabel.lineBreakMode = .byTruncatingMiddle
        summaryLabel.font = .systemFont(ofSize: 13.5)
        disclosureLabel.font = .systemFont(ofSize: 11)
        disclosureLabel.textColor = .secondaryLabelColor
        disclosureLabel.setAccessibilityLabel("Copy Organize safety, privacy, and completeness status")
        [cancelButton, copyButton].forEach { $0.bezelStyle = .rounded }
        copyButton.isEnabled = false
        results.table.permitsKeyboardFocus = true
        results.table.refusesFirstResponder = false
        results.table.allowsMultipleSelection = false
        results.applyLayout(PanelLayoutMetrics(configuredVisibleRows: 9, rowCount: 1))
        results.setRows([.action(message: "Creating a typed search plan…", symbol: "sparkles")])

        let heading = NSStackView(views: [titleLabel, NSView(), scopeLabel])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 10
        let actions = NSStackView(views: [NSView(), cancelButton, copyButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        let separator = NSBox()
        separator.boxType = .separator
        for view in [heading, summaryLabel, separator, results.scrollView, disclosureLabel, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            heading.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            summaryLabel.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            summaryLabel.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            summaryLabel.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            separator.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 13),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            results.scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 5),
            results.scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            results.scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            disclosureLabel.topAnchor.constraint(equalTo: results.scrollView.bottomAnchor, constant: 10),
            disclosureLabel.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            disclosureLabel.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            actions.topAnchor.constraint(equalTo: disclosureLabel.bottomAnchor, constant: 10),
            actions.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            actions.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            actions.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    private func beginPlan(instruction: String) {
        state = .searching
        scopeLabel.stringValue = "All indexed files · search planning"
        summaryLabel.stringValue = "Codex is translating the request into metadata filters. No paths are sent."
        let provider = self.provider
        let searchPlanner = self.searchPlanner
        let organizePlanner = self.organizePlanner
        let chooseDestination = self.chooseDestination
        task = Task { @MainActor [weak self] in
            do {
                let searchPlan = try await searchPlanner.makeSearchPlan(
                    instruction, scopeID: .indexedFiles,
                    localeIdentifier: Locale.current.identifier,
                    timeZoneIdentifier: TimeZone.current.identifier, now: Date(),
                    openLoginURL: { url in await MainActor.run { NSWorkspace.shared.open(url) } },
                    progress: { [weak self] progress in
                        guard let self, !self.ended else { return }
                        self.scopeLabel.stringValue = "All indexed files · \(Self.progressText(progress))"
                    }
                )
                try Task.checkCancellation()
                let request = try Self.copySearchRequest(for: searchPlan)
                self?.scopeLabel.stringValue = "All indexed files · searching locally"
                self?.summaryLabel.stringValue = "Scanning one immutable local index generation; the filesystem is not being crawled."
                self?.results.setRows([.action(message: "Searching the complete local index…",
                                                      symbol: "magnifyingglass")])
                let response = await provider.runAssistedSearch(request)
                try Task.checkCancellation()
                let copyRows = try Self.completeCopyRows(from: response)

                self?.state = .choosingDestination
                self?.scopeLabel.stringValue = "\(copyRows.count) matched files · choose destination"
                self?.summaryLabel.stringValue = "Search complete. Choose one folder where JBar may create copies."
                self?.results.setRows(copyRows.map(PanelRow.result))
                guard let destination = chooseDestination() else {
                    throw OrganizeWorkflowError.destinationCancelled
                }
                try Task.checkCancellation()
                let inputs = copyRows.map {
                    GlobalCopySourceInput(path: $0.path, parentDisplay: $0.parentDisplay)
                }
                let scope = try await Task.detached(priority: .userInitiated) {
                    try GlobalCopyScopeSnapshot.capture(inputs: inputs, destinationFolder: destination)
                }.value

                self?.state = .planning
                self?.scopeLabel.stringValue = "\(scope.files.count) files → \(destination.lastPathComponent)"
                self?.summaryLabel.stringValue = "Asking Codex how to group the matched names. Paths remain local."
                self?.results.setRows([.action(message: "Planning copies with opaque file IDs…",
                                                      symbol: "sparkles")])
                let candidates = scope.files.map {
                    OrganizeCandidate(id: $0.id, name: $0.name,
                                      sizeBytes: $0.identity.size, modifiedAt: $0.modifiedAt)
                }
                let plan = try await organizePlanner.makeOrganizePlan(
                    instruction, scopeID: scope.scopeID, candidates: candidates,
                    localeIdentifier: Locale.current.identifier,
                    timeZoneIdentifier: TimeZone.current.identifier, now: Date(),
                    openLoginURL: { url in await MainActor.run { NSWorkspace.shared.open(url) } },
                    progress: { [weak self] progress in
                        guard let self, !self.ended else { return }
                        self.scopeLabel.stringValue = "Copy destination · \(Self.progressText(progress))"
                    }
                )
                try Task.checkCancellation()
                let operations = plan.operations.map {
                    ProposedFileOperation(sourceID: $0.sourceID,
                                          destinationFolderName: $0.destinationFolderName,
                                          newName: $0.newName)
                }
                let preview = try await Task.detached(priority: .userInitiated) {
                    try CopyOperationExecutor.preview(scope: scope, summary: plan.summary,
                                                      operations: operations)
                }.value
                self?.showPreview(preview, scannedItems: response.scannedItems)
            } catch is CancellationError {
                self?.finishError("Copy Organize stopped. Originals were not changed.")
            } catch {
                self?.finishError((error as? LocalizedError)?.errorDescription
                    ?? "JBar could not build a safe copy preview. Originals were not changed.")
            }
        }
    }

    private static func progressText(_ progress: PaletteActionProgress) -> String {
        switch progress {
        case .connectingToCodex: return "starting Codex"
        case .waitingForChatGPTSignIn: return "waiting for ChatGPT sign-in"
        case .checkingAccountAndSafety: return "checking safety boundaries"
        case .preparingLuna: return "preparing Luna"
        case .generatingAnswer: return "creating typed plan"
        }
    }

    private func showPreview(_ preview: CopyOperationPreview, scannedItems: Int) {
        guard !ended else { return }
        task = nil
        self.preview = preview
        state = .reviewing
        scopeLabel.stringValue = "\(Self.counted(preview.scope.files.count, singular: "file", plural: "files")) → \(URL(fileURLWithPath: preview.scope.destinationRootPath).lastPathComponent)"
        summaryLabel.stringValue = preview.summary.isEmpty
            ? "Review every proposed and skipped copy before confirming."
            : preview.summary
        let renderedRows = Self.previewRows(preview)
        results.setRows(renderedRows)
        results.applyLayout(PanelLayoutMetrics(configuredVisibleRows: 9,
                                               rowCount: max(1, renderedRows.count)))
        results.layout(width: max(0, results.scrollView.bounds.width))
        resizeForRowCount(renderedRows.count)
        disclosureLabel.stringValue = "Scanned \(scannedItems) indexed items locally · \(Self.counted(preview.collisionCount, singular: "collision", plural: "collisions")) · 0 overwrites · \(preview.skippedCount) skipped · originals never move or change. Codex saw \(preview.scope.files.count) names with opaque IDs, sizes, and dates—not paths."
        copyButton.title = "Copy \(Self.counted(preview.executableCount, singular: "file", plural: "files"))"
        copyButton.isEnabled = preview.executableCount > 0
        cancelButton.title = "Cancel"
        window?.makeFirstResponder(copyButton)
    }

    @objc private func copyPressed(_ sender: NSButton) {
        guard state == .reviewing, let preview else { NSSound.beep(); return }
        state = .copying
        copyButton.isEnabled = false
        cancelButton.isEnabled = false
        summaryLabel.stringValue = "Copying with native file APIs. Existing destinations remain untouched."
        task = Task { @MainActor [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try CopyOperationExecutor.commit(preview)
                }.value
                self?.showCopied(result)
            } catch {
                self?.finishError((error as? LocalizedError)?.errorDescription
                    ?? "The copy batch could not be applied safely.")
            }
        }
    }

    private func showCopied(_ result: CopyOperationBatchResult) {
        guard !ended else { return }
        task = nil
        state = .completed
        summaryLabel.stringValue = "Copied \(Self.counted(result.completedCount, singular: "file", plural: "files")); \(result.skippedCount) skipped; \(result.failedCount) failed."
        results.setRows(result.outcomes.map { outcome in
            let symbol = outcome.status == .completed ? "checkmark.circle" : "exclamationmark.triangle"
            return .action(message: "\(outcome.sourceName) → \(outcome.destinationRelativePath) — \(outcome.explanation)",
                           symbol: symbol)
        })
        disclosureLabel.stringValue = "Original files were not moved, renamed, edited, or deleted. No existing destination was overwritten."
        copyButton.isHidden = true
        cancelButton.isEnabled = true
        cancelButton.title = "Done"
        window?.makeFirstResponder(cancelButton)
    }

    @objc private func cancelPressed(_ sender: NSButton) {
        if state == .searching || state == .planning || state == .choosingDestination {
            task?.cancel()
        }
        window?.close()
    }

    private func finishError(_ message: String, codexStarted: Bool = true) {
        guard !ended else { return }
        task = nil
        state = .failed
        summaryLabel.stringValue = message
        results.setRows([.action(message: "Stopped safely", symbol: "xmark.octagon")])
        disclosureLabel.stringValue = codexStarted
            ? "No original was changed and no destination was overwritten."
            : "Codex was not started. The request and all file metadata stayed on this Mac."
        copyButton.isEnabled = false
        copyButton.isHidden = true
        cancelButton.isEnabled = true
        cancelButton.title = "Done"
    }

    private func resizeForRowCount(_ count: Int) {
        guard let window else { return }
        let desiredHeight = min(640, max(480, 320 + CGFloat(min(count, 6)) * ResultsController.rowHeight))
        var frame = window.frame
        let top = frame.maxY
        frame.size.height = desiredHeight
        frame.origin.y = top - desiredHeight
        window.setFrame(frame, display: true, animate: false)
    }
}
