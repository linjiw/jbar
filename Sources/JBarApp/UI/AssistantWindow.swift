import AppKit
import JBarActions
import JBarCore

protocol AssistantPlanning: Sendable {
    func makeSearchPlan(_ prompt: String, scopeID: ScopeID,
                        localeIdentifier: String, timeZoneIdentifier: String, now: Date,
                        openLoginURL: @escaping CodexLoginURLHandler,
                        progress: @escaping PaletteActionProgressHandler) async throws -> SearchPlan
}

extension CodexTaskSession: AssistantPlanning {}

extension AssistedSearchRequest {
    init(searchPlan plan: SearchPlan) {
        let kinds = Set(plan.kinds.map { kind -> ItemKind in
            switch kind {
            case .app: return .app
            case .folder: return .folder
            case .document: return .document
            case .image: return .image
            case .video: return .video
            case .audio: return .audio
            case .code: return .code
            case .archive: return .archive
            case .other: return .other
            }
        })
        let sort: AssistedSearchSort = switch plan.sort {
        case .relevance: .relevance
        case .modifiedDescending: .modifiedDescending
        case .nameAscending: .nameAscending
        }
        self.init(nameTerms: plan.nameTerms, extensions: Set(plan.extensions), kinds: kinds,
                  modifiedAfter: plan.modifiedAfter, modifiedBefore: plan.modifiedBefore,
                  minimumSizeBytes: plan.minimumSizeBytes,
                  maximumSizeBytes: plan.maximumSizeBytes, sort: sort, limit: plan.limit)
    }
}

/// Owns one read-only Assistant result window. It is created only by the explicit Return path.
@MainActor
final class AssistantCoordinator {
    private let provider: any SearchProviding
    private let launcher: AppLauncher
    private let planner: any AssistantPlanning
    private let indexStatus: (@MainActor @Sendable () -> IndexStatus?)?
    private var controller: AssistantWindowController?

    init(provider: any SearchProviding, launcher: AppLauncher,
         planner: any AssistantPlanning = CodexTaskSession(),
         indexStatus: (@MainActor @Sendable () -> IndexStatus?)? = nil) {
        self.provider = provider
        self.launcher = launcher
        self.planner = planner
        self.indexStatus = indexStatus
    }

    @discardableResult
    func present(prompt: String) -> Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let controller {
            controller.showAndSearch(trimmed)
            return true
        }
        let newController = AssistantWindowController(provider: provider, launcher: launcher,
                                                      planner: planner, indexStatus: indexStatus)
        newController.onClosed = { [weak self, weak newController] in
            guard let self, self.controller === newController else { return }
            self.controller = nil
        }
        controller = newController
        newController.showAndSearch(trimmed)
        return true
    }

    func close() {
        controller?.endSession()
        controller = nil
    }
}

@MainActor
final class AssistantWindowController: NSWindowController, NSWindowDelegate {
    var onClosed: (() -> Void)?

    private let provider: any SearchProviding
    private let launcher: AppLauncher
    private let planner: any AssistantPlanning
    private let indexStatus: (@MainActor @Sendable () -> IndexStatus?)?
    private let results = ResultsController()
    private var searchTask: Task<Void, Never>?
    private var activePrompt = ""
    private var ended = false
    private var hasPositionedWindow = false

    private let titleLabel = NSTextField(labelWithString: "Assistant")
    private let statusLabel = NSTextField(labelWithString: "Indexed files · ready")
    private let summaryLabel = NSTextField(wrappingLabelWithString: "Ask JBar to find files using local metadata.")
    private let disclosureLabel = NSTextField(wrappingLabelWithString:
        "AI starts only after Return. File search and file actions run locally.")
    private lazy var stopButton = NSButton(title: "Stop", target: self,
                                           action: #selector(stopPressed(_:)))
    private lazy var openButton = NSButton(title: "Open", target: self,
                                           action: #selector(openPressed(_:)))
    private lazy var revealButton = NSButton(title: "Reveal in Finder", target: self,
                                             action: #selector(revealPressed(_:)))
    private lazy var copyButton = NSButton(title: "Copy Path", target: self,
                                           action: #selector(copyPressed(_:)))

    init(provider: any SearchProviding, launcher: AppLauncher,
         planner: any AssistantPlanning,
         indexStatus: (@MainActor @Sendable () -> IndexStatus?)? = nil) {
        self.provider = provider
        self.launcher = launcher
        self.planner = planner
        self.indexStatus = indexStatus
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 440),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        configureWindow(window)
        buildContent(in: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showAndSearch(_ prompt: String) {
        guard !ended, let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        if !hasPositionedWindow {
            window.center()
            hasPositionedWindow = true
        }
        window.makeKeyAndOrderFront(nil)
        guard searchTask == nil else {
            statusLabel.stringValue = "Current search is still running · press Stop before a new request"
            NSSound.beep()
            return
        }
        activePrompt = prompt
        if let status = indexStatus?(), let message = IndexReadiness.waitMessage(for: status) {
            showIndexWait(message)
            return
        }
        beginSearch(prompt)
    }

    func endSession() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard !ended else { return }
        ended = true
        searchTask?.cancel()
        searchTask = nil
        onClosed?()
        onClosed = nil
    }

    static func progressText(_ progress: PaletteActionProgress) -> String {
        switch progress {
        case .connectingToCodex: return "Starting local Codex planner…"
        case .waitingForChatGPTSignIn: return "Finish ChatGPT sign-in in your browser…"
        case .checkingAccountAndSafety: return "Checking account and read-only boundaries…"
        case .preparingLuna: return "Preparing GPT-5.6 Luna · low…"
        case .generatingAnswer: return "Creating a read-only SearchPlan…"
        }
    }

    static func summaryText(for response: AssistedSearchResponse) -> String {
        if response.cancelled { return "Search stopped before the local index scan completed." }
        if response.rows.isEmpty {
            return response.totalMatchesIsComplete
                ? "No indexed file matched the planned metadata filters."
                : "No match was found before the bounded local scan stopped. Results may be incomplete."
        }
        let count = response.totalMatchesIsComplete ? response.totalMatches : response.rows.count
        let noun = count == 1 ? "result" : "results"
        if response.totalMatchesIsComplete, response.totalMatches > response.rows.count {
            return "Found \(count) \(noun) in the local index; showing the first \(response.rows.count)."
        }
        return response.totalMatchesIsComplete
            ? "Found \(count) \(noun) in the local index."
            : "Showing \(response.rows.count) \(noun) from an incomplete bounded local scan."
    }

    /// A partial app-only generation is published quickly so launcher typing stays useful. Assistant
    /// must not call that partial generation a complete file search: wait until the coordinator has
    /// either loaded a valid snapshot or finished its crawl before spending an AI turn.
    private func configureWindow(_ window: NSWindow) {
        window.title = "JBar Assistant"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 440)
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier("JBarAssistantWindow")
        window.setAccessibilityLabel("JBar Assistant file results")
    }

    private func buildContent(in window: NSWindow) {
        let root = NSVisualEffectView()
        root.material = .underWindowBackground
        root.blendingMode = .behindWindow
        root.state = .active
        window.contentView = root

        titleLabel.font = .systemFont(ofSize: 19, weight: .semibold)
        statusLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.font = .systemFont(ofSize: 13.5)
        disclosureLabel.font = .systemFont(ofSize: 11)
        disclosureLabel.textColor = .secondaryLabelColor
        disclosureLabel.setAccessibilityLabel(
            "Privacy: Codex receives the submitted question, locale, time zone, and Indexed files scope. File metadata and paths stay local.")

        stopButton.bezelStyle = .rounded
        stopButton.isHidden = true
        stopButton.setAccessibilityLabel("Stop Assistant planning and local search")
        [openButton, revealButton, copyButton].forEach {
            $0.bezelStyle = .rounded
            $0.isEnabled = false
        }
        openButton.keyEquivalent = "\r"
        revealButton.keyEquivalent = "\r"
        revealButton.keyEquivalentModifierMask = [.command]
        copyButton.keyEquivalent = "c"
        copyButton.keyEquivalentModifierMask = [.command]
        results.opensOnSingleClick = false
        results.onOpen = { [weak self] row in self?.open(row) }
        results.onReveal = { [weak self] row in _ = self?.launcher.reveal(row) }
        results.onCopyPath = { [weak self] row in self?.launcher.copyPath(row) }
        results.table.permitsKeyboardFocus = true
        results.table.refusesFirstResponder = false
        results.table.allowsMultipleSelection = false
        results.applyLayout(PanelLayoutMetrics(configuredVisibleRows: 8, rowCount: 0))

        let heading = NSStackView(views: [titleLabel, NSView(), statusLabel, stopButton])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 10
        let actions = NSStackView(views: [NSView(), openButton, revealButton, copyButton])
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

    private func beginSearch(_ prompt: String) {
        results.setRows([.action(message: "Waiting for a typed, read-only plan…", symbol: "sparkles")])
        summaryLabel.stringValue = "Understanding your request. No file metadata has been sent."
        disclosureLabel.stringValue = "AI received your submitted question, locale, time zone, and Indexed files scope. File metadata and paths stay local."
        statusLabel.stringValue = "Indexed files · Luna · starting"
        stopButton.isHidden = false
        setActionsEnabled(false)

        let provider = self.provider
        let planner = self.planner
        searchTask = Task { @MainActor [weak self] in
            do {
                let plan = try await planner.makeSearchPlan(
                    prompt, scopeID: .indexedFiles,
                    localeIdentifier: Locale.current.identifier,
                    timeZoneIdentifier: TimeZone.current.identifier, now: Date(),
                    openLoginURL: { url in
                        await MainActor.run { NSWorkspace.shared.open(url) }
                    }, progress: { [weak self] progress in
                        guard let self, !self.ended else { return }
                        self.statusLabel.stringValue = "Indexed files · " + Self.progressText(progress)
                    }
                )
                try Task.checkCancellation()
                self?.statusLabel.stringValue = "Indexed files · searching locally"
                self?.results.setRows([.action(message: "Searching the local index…", symbol: "magnifyingglass")])
                let response = await provider.runAssistedSearch(AssistedSearchRequest(searchPlan: plan))
                try Task.checkCancellation()
                self?.finish(plan: plan, response: response)
            } catch is CancellationError {
                self?.finishStopped()
            } catch {
                self?.finish(error: error)
            }
        }
    }

    private func showIndexWait(_ message: String) {
        searchTask = nil
        stopButton.isHidden = true
        statusLabel.stringValue = "Indexed files · indexing in progress"
        summaryLabel.stringValue = message
        disclosureLabel.stringValue = "Codex was not started. Your question and file metadata stayed on this Mac."
        results.setRows([.action(message: "Wait for the local index, then submit again", symbol: "clock")])
        setActionsEnabled(false)
    }

    private func finish(plan: SearchPlan, response: AssistedSearchResponse) {
        guard !ended else { return }
        searchTask = nil
        stopButton.isHidden = true
        statusLabel.stringValue = response.totalMatchesIsComplete
            ? "Indexed files · local results complete"
            : "Indexed files · local results incomplete"
        summaryLabel.stringValue = Self.summaryText(for: response)
        results.setRows(response.rows.isEmpty
            ? [.action(message: "No matching indexed files", symbol: "magnifyingglass")]
            : response.rows.map(PanelRow.result))
        results.applyLayout(PanelLayoutMetrics(configuredVisibleRows: 8,
                                               rowCount: max(1, response.rows.count)))
        results.layout(width: max(0, results.scrollView.bounds.width))
        resizeForResultCount(response.rows.count)
        let rerank = plan.needsCandidateRerank
            ? " Candidate reranking was requested but not sent; JBar used local ordering."
            : ""
        disclosureLabel.stringValue = "AI used your question plus locale, time zone, and scope name. Metadata for \(response.scannedItems) indexed items and all result paths stayed local.\(rerank)"
        setActionsEnabled(!response.rows.isEmpty)
        if !response.rows.isEmpty { window?.makeFirstResponder(results.table) }
    }

    private func finishStopped() {
        guard !ended else { return }
        searchTask = nil
        stopButton.isHidden = true
        statusLabel.stringValue = "Indexed files · stopped"
        summaryLabel.stringValue = "Assistant stopped. No file was changed."
        results.setRows([.action(message: "Stopped safely", symbol: "stop.circle")])
        setActionsEnabled(false)
    }

    private func finish(error: Error) {
        guard !ended else { return }
        searchTask = nil
        stopButton.isHidden = true
        statusLabel.stringValue = "Indexed files · stopped safely"
        summaryLabel.stringValue = (error as? LocalizedError)?.errorDescription
            ?? "Assistant could not create a safe search plan."
        results.setRows([.action(message: "No local file action was taken", symbol: "xmark.octagon")])
        setActionsEnabled(false)
    }

    private func setActionsEnabled(_ enabled: Bool) {
        openButton.isEnabled = enabled
        revealButton.isEnabled = enabled
        copyButton.isEnabled = enabled
    }

    private func resizeForResultCount(_ count: Int) {
        guard let window else { return }
        let desiredHeight = min(590, max(440, 330 + CGFloat(min(count, 5)) * ResultsController.rowHeight))
        var frame = window.frame
        let top = frame.maxY
        frame.size.height = desiredHeight
        frame.origin.y = top - desiredHeight
        window.setFrame(frame, display: true, animate: false)
    }

    private var selectedResult: ResultRow? { results.selectedResult ?? results.firstResult }

    @objc private func stopPressed(_ sender: NSButton) {
        searchTask?.cancel()
    }

    @objc private func openPressed(_ sender: NSButton) {
        guard let row = selectedResult else { NSSound.beep(); return }
        open(row)
    }

    @objc private func revealPressed(_ sender: NSButton) {
        guard let row = selectedResult else { NSSound.beep(); return }
        _ = launcher.reveal(row)
    }

    @objc private func copyPressed(_ sender: NSButton) {
        guard let row = selectedResult else { NSSound.beep(); return }
        launcher.copyPath(row)
    }

    private func open(_ row: ResultRow) {
        launcher.open(row, query: nil) { _ in }
    }
}
