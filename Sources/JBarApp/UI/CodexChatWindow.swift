import AppKit
import JBarActions

enum CodexChatRole: Equatable {
    case user
    case assistant
    case system
    case tool
}

struct CodexChatMessage: Equatable, Identifiable {
    let id: UUID
    let role: CodexChatRole
    var text: String
    var isStreaming: Bool

    init(id: UUID = UUID(), role: CodexChatRole, text: String, isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.isStreaming = isStreaming
    }
}

enum CodexChatTranscript {
    static func plainText(_ messages: [CodexChatMessage]) -> String {
        messages.map { message in
            let label: String
            switch message.role {
            case .user: label = "YOU"
            case .assistant: label = "CODEX · LUNA"
            case .system: label = "JBAR"
            case .tool: label = "TERMINAL"
            }
            let body = message.text.isEmpty && message.isStreaming ? "Thinking…" : message.text
            return "\(label)\n\(body)"
        }.joined(separator: "\n\n")
    }
}

/// Owns at most one explicit Developer Agent window. Reopening `>` while it is alive raises the
/// same thread; if an answer is running, the new prompt is preserved instead of queued.
@MainActor
final class CodexChatCoordinator {
    private let applicationSupportRoot: URL?
    private var controller: CodexChatWindowController?

    init(applicationSupportRoot: URL? = nil) {
        self.applicationSupportRoot = applicationSupportRoot
    }

    @discardableResult
    func present(prompt: String) -> Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let controller {
            controller.showAndSend(trimmed)
            return true
        }
        guard let workspace = try? CodexWorkspace.jbar() else { return false }
        let newController = CodexChatWindowController(
            session: CodexChatSession(workspace: workspace,
                                      applicationSupportRoot: applicationSupportRoot),
                                                      workspace: workspace)
        newController.onClosed = { [weak self, weak newController] in
            guard let self, self.controller === newController else { return }
            self.controller = nil
        }
        controller = newController
        newController.showAndSend(trimmed)
        return true
    }

    func close() {
        controller?.endConversation()
        controller = nil
    }
}

@MainActor
final class CodexChatWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    var onClosed: (() -> Void)?

    private let session: CodexChatSession
    private let workspace: CodexWorkspace
    private var messages: [CodexChatMessage] = []
    private var toolMessageIDs: [String: UUID] = [:]
    private var toolCommands: [String: (command: String, cwd: String)] = [:]
    private var sendTask: Task<Void, Never>?
    private var isSending = false
    private var ended = false
    private var hasPositionedWindow = false
    private var streamRenderScheduled = false

    private let transcriptView = NSTextView()
    private let transcriptScroll = NSScrollView()
    private let composer = CodexChatComposerTextView()
    private let composerScroll = NSScrollView()
    private let placeholder = NSTextField(labelWithString: "Message Developer Agent…")
    private let statusLabel = NSTextField(labelWithString: "~/jbar · ready")
    private lazy var sendButton = NSButton(title: "Send", target: self,
                                           action: #selector(sendButtonPressed(_:)))

    init(session: CodexChatSession, workspace: CodexWorkspace) {
        self.session = session
        self.workspace = workspace
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        configureWindow(window)
        buildContent(in: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func progressText(_ progress: PaletteActionProgress) -> String {
        switch progress {
        case .connectingToCodex: return "Starting local Codex…"
        case .waitingForChatGPTSignIn: return "Finish ChatGPT sign-in in your browser…"
        case .checkingAccountAndSafety: return "Checking account and safety boundaries…"
        case .preparingLuna: return "Preparing GPT-5.6 Luna · low…"
        case .generatingAnswer: return "Codex is responding…"
        }
    }

    func showAndSend(_ prompt: String) {
        guard !ended, let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        if !hasPositionedWindow {
            window.center()
            hasPositionedWindow = true
        }
        window.makeKeyAndOrderFront(nil)
        if isSending {
            if composer.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                composer.string = prompt
                updatePlaceholder()
            }
            statusLabel.stringValue = "Current answer is still running · next prompt kept below"
            window.makeFirstResponder(composer)
            return
        }
        send(prompt)
    }

    func endConversation() {
        guard !ended else { return }
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard !ended else { return }
        ended = true
        sendTask?.cancel()
        sendTask = nil
        let session = self.session
        Task { await session.close() }
        onClosed?()
        onClosed = nil
    }

    func textDidChange(_ notification: Notification) {
        updatePlaceholder()
    }

    private func configureWindow(_ window: NSWindow) {
        window.title = "JBar Developer Agent"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 440)
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier("JBarCodexChatWindow")
        window.setAccessibilityLabel("JBar Developer Agent")
    }

    private func buildContent(in window: NSWindow) {
        let root = NSVisualEffectView()
        root.material = .underWindowBackground
        root.blendingMode = .behindWindow
        root.state = .active
        window.contentView = root

        let header = makeHeader()
        let separator = NSBox()
        separator.boxType = .separator

        configureTranscript()
        let composerArea = makeComposerArea()

        for view in [header, separator, transcriptScroll, composerArea] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            header.heightAnchor.constraint(equalToConstant: 48),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            transcriptScroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            transcriptScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            transcriptScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            composerArea.topAnchor.constraint(equalTo: transcriptScroll.bottomAnchor, constant: 10),
            composerArea.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            composerArea.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            composerArea.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            composerArea.heightAnchor.constraint(equalToConstant: 112),
        ])
        messages = [CodexChatMessage(role: .system,
                                     text: "Workspace: \(workspace.displayPath)\nCommands and file changes appear here. Network is off; the transcript is ephemeral.")]
        renderTranscript()
    }

    private func makeHeader() -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: "Codex agent")
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        icon.contentTintColor = .systemGreen
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 34),
            icon.heightAnchor.constraint(equalToConstant: 34),
        ])

        let title = NSTextField(labelWithString: "Developer Agent")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let model = NSTextField(labelWithString: "GPT-5.6 LUNA  ·  LOW")
        model.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        model.textColor = .secondaryLabelColor
        let titleStack = NSStackView(views: [title, model])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2

        let safety = NSTextField(labelWithString: "●  ~/JBAR  ·  NETWORK OFF  ·  EPHEMERAL")
        safety.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        safety.textColor = .systemGreen
        safety.setAccessibilityLabel("JBar workspace, network off, ephemeral session")

        let stack = NSStackView(views: [icon, titleStack, NSView(), safety])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        return stack
    }

    private func configureTranscript() {
        transcriptView.frame = NSRect(x: 0, y: 0, width: 700, height: 360)
        transcriptScroll.borderType = .noBorder
        transcriptScroll.drawsBackground = false
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.autohidesScrollers = true
        transcriptScroll.documentView = transcriptView
        transcriptScroll.setAccessibilityLabel("Codex workspace conversation")

        transcriptView.isEditable = false
        transcriptView.isSelectable = true
        transcriptView.drawsBackground = false
        transcriptView.textContainerInset = NSSize(width: 8, height: 14)
        transcriptView.isVerticallyResizable = true
        transcriptView.isHorizontallyResizable = false
        transcriptView.autoresizingMask = [.width]
        transcriptView.minSize = NSSize(width: 0, height: 0)
        transcriptView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                        height: CGFloat.greatestFiniteMagnitude)
        transcriptView.textContainer?.containerSize = NSSize(width: 0,
                                                              height: CGFloat.greatestFiniteMagnitude)
        transcriptView.textContainer?.widthTracksTextView = true
    }

    private func makeComposerArea() -> NSView {
        let area = NSBox()
        area.boxType = .custom
        area.borderColor = NSColor.separatorColor
        area.borderWidth = 1
        area.cornerRadius = 10
        area.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.82)

        composer.frame = NSRect(x: 0, y: 0, width: 700, height: 72)
        composerScroll.borderType = .noBorder
        composerScroll.drawsBackground = false
        composerScroll.hasVerticalScroller = true
        composerScroll.autohidesScrollers = true
        composerScroll.documentView = composer
        composerScroll.translatesAutoresizingMaskIntoConstraints = false
        area.addSubview(composerScroll)

        composer.drawsBackground = false
        composer.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        composer.textColor = .labelColor
        composer.textContainerInset = NSSize(width: 8, height: 8)
        composer.isRichText = false
        composer.allowsUndo = true
        composer.delegate = self
        composer.onSubmit = { [weak self] in self?.submitComposer() }
        composer.setAccessibilityLabel("Message Developer Agent")

        placeholder.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        placeholder.textColor = .placeholderTextColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        area.addSubview(placeholder)

        statusLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        area.addSubview(statusLabel)

        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = ""
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.setAccessibilityLabel("Send message")
        area.addSubview(sendButton)

        NSLayoutConstraint.activate([
            composerScroll.topAnchor.constraint(equalTo: area.topAnchor, constant: 4),
            composerScroll.leadingAnchor.constraint(equalTo: area.leadingAnchor, constant: 5),
            composerScroll.trailingAnchor.constraint(equalTo: area.trailingAnchor, constant: -5),
            composerScroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),
            placeholder.topAnchor.constraint(equalTo: area.topAnchor, constant: 13),
            placeholder.leadingAnchor.constraint(equalTo: area.leadingAnchor, constant: 14),
            statusLabel.leadingAnchor.constraint(equalTo: area.leadingAnchor, constant: 13),
            statusLabel.bottomAnchor.constraint(equalTo: area.bottomAnchor, constant: -9),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: sendButton.leadingAnchor, constant: -10),
            sendButton.trailingAnchor.constraint(equalTo: area.trailingAnchor, constant: -10),
            sendButton.bottomAnchor.constraint(equalTo: area.bottomAnchor, constant: -6),
            sendButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
        ])
        return area
    }

    @objc private func sendButtonPressed(_ sender: NSButton) {
        if isSending { stopCurrentAnswer() } else { submitComposer() }
    }

    private func submitComposer() {
        let prompt = composer.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { NSSound.beep(); return }
        guard !isSending else {
            statusLabel.stringValue = "Wait for the current answer, or press Stop"
            NSSound.beep()
            return
        }
        composer.string = ""
        updatePlaceholder()
        send(prompt)
    }

    private func send(_ prompt: String) {
        guard !ended, !isSending else { return }
        isSending = true
        sendButton.title = "Stop"
        sendButton.setAccessibilityLabel("Stop current answer")
        statusLabel.stringValue = "Starting local Codex…"

        messages.append(CodexChatMessage(role: .user, text: prompt))
        toolMessageIDs.removeAll(keepingCapacity: true)
        toolCommands.removeAll(keepingCapacity: true)
        let responseID = UUID()
        messages.append(CodexChatMessage(id: responseID, role: .assistant, text: "", isStreaming: true))
        renderTranscript()

        let session = self.session
        sendTask = Task { @MainActor [weak self] in
            do {
                let answer = try await session.send(prompt, openLoginURL: { url in
                    await MainActor.run { NSWorkspace.shared.open(url) }
                }, progress: { [weak self] progress in
                    guard let self, !self.ended else { return }
                    self.statusLabel.stringValue = Self.progressText(progress)
                }, onEvent: { [weak self] event in
                    self?.handleAgentEvent(event, before: responseID)
                }, onUpdate: { [weak self] accumulated in
                    self?.updateStreamingMessage(id: responseID, text: accumulated)
                })
                self?.finishMessage(id: responseID, text: answer)
            } catch is CancellationError {
                self?.finishStoppedMessage(id: responseID)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? "Codex stopped safely before producing an answer."
                self?.finishMessage(id: responseID, text: "Error: \(message)", failed: true)
            }
        }
    }

    private func stopCurrentAnswer() {
        guard isSending else { return }
        statusLabel.stringValue = "Stopping current answer…"
        sendTask?.cancel()
        let session = self.session
        Task { await session.cancelCurrentTurn() }
    }

    private func handleAgentEvent(_ event: CodexAgentEvent, before responseID: UUID) {
        guard !ended else { return }
        switch event {
        case .commandStarted(let id, let command, let cwd):
            toolCommands[id] = (command, cwd)
            upsertToolMessage(id: id, text: commandText(command: command, cwd: cwd,
                                                        output: "Running…", exitCode: nil),
                              before: responseID)
            statusLabel.stringValue = "Running in \(displayCwd(cwd))…"
        case .commandOutput(let id, let output):
            guard let metadata = toolCommands[id] else { return }
            upsertToolMessage(id: id, text: commandText(command: metadata.command,
                                                        cwd: metadata.cwd, output: output,
                                                        exitCode: nil), before: responseID)
        case .commandCompleted(let id, let command, let output, let exitCode):
            let cwd = toolCommands[id]?.cwd ?? workspace.url.path
            toolCommands.removeValue(forKey: id)
            upsertToolMessage(id: id, text: commandText(command: command, cwd: cwd,
                                                        output: output, exitCode: exitCode),
                              before: responseID)
            statusLabel.stringValue = "Codex is responding…"
        case .filesChanged(let id, let summary):
            upsertToolMessage(id: id, text: "Files changed\n\(summary)", before: responseID)
            statusLabel.stringValue = "Workspace files changed…"
        }
    }

    private func upsertToolMessage(id: String, text: String, before responseID: UUID) {
        if let messageID = toolMessageIDs[id],
           let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index].text = text
        } else {
            let message = CodexChatMessage(role: .tool, text: text)
            let index = messages.firstIndex(where: { $0.id == responseID }) ?? messages.endIndex
            messages.insert(message, at: index)
            toolMessageIDs[id] = message.id
        }
        scheduleTranscriptRender()
    }

    private func commandText(command: String, cwd: String, output: String, exitCode: Int?) -> String {
        var text = "\(displayCwd(cwd)) $ \(command)"
        if !output.isEmpty { text += "\n\(output.trimmingCharacters(in: .newlines))" }
        if let exitCode { text += "\n[exit \(exitCode)]" }
        return text
    }

    private func displayCwd(_ cwd: String) -> String {
        let canonical = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL.path
        if canonical == workspace.url.path { return workspace.displayPath }
        let relative = workspace.relativePath(cwd)
        return relative.hasPrefix("/") ? relative : workspace.displayPath + "/" + relative
    }

    private func updateStreamingMessage(id: UUID, text: String) {
        guard !ended, let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text = text
        scheduleTranscriptRender()
    }

    private func scheduleTranscriptRender() {
        guard !streamRenderScheduled else { return }
        streamRenderScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30.0) { [weak self] in
            guard let self else { return }
            self.streamRenderScheduled = false
            if !self.ended { self.renderTranscript() }
        }
    }

    private func finishMessage(id: UUID, text: String, failed: Bool = false) {
        guard !ended, let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text = text
        messages[index].isStreaming = false
        finishTurn(status: failed ? "Stopped safely · you can retry" : "\(workspace.displayPath) · ready")
    }

    private func finishStoppedMessage(id: UUID) {
        guard !ended, let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let partial = messages[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
        messages[index].text = partial.isEmpty ? "[Stopped]" : partial + "\n\n[Stopped]"
        messages[index].isStreaming = false
        finishTurn(status: "Stopped · \(workspace.displayPath) is still ready")
    }

    private func finishTurn(status: String) {
        sendTask = nil
        isSending = false
        sendButton.title = "Send"
        sendButton.setAccessibilityLabel("Send message")
        statusLabel.stringValue = status
        renderTranscript()
        window?.makeFirstResponder(composer)
    }

    private func updatePlaceholder() {
        placeholder.isHidden = !composer.string.isEmpty
    }

    private func renderTranscript() {
        let rendered = NSMutableAttributedString()
        let bodyFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let labelFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .bold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 17
        for (index, message) in messages.enumerated() {
            let label: String
            let labelColor: NSColor
            switch message.role {
            case .user:
                label = "YOU\n"
                labelColor = .systemBlue
            case .assistant:
                label = "CODEX · LUNA\n"
                labelColor = .systemGreen
            case .system:
                label = "JBAR\n"
                labelColor = .secondaryLabelColor
            case .tool:
                label = "TERMINAL\n"
                labelColor = .systemOrange
            }
            rendered.append(NSAttributedString(string: label, attributes: [
                .font: labelFont, .foregroundColor: labelColor,
            ]))
            let body = message.text.isEmpty && message.isStreaming ? "Thinking…" : message.text
            let bodyColor: NSColor = message.text.isEmpty && message.isStreaming
                ? .tertiaryLabelColor : .labelColor
            rendered.append(NSAttributedString(string: body, attributes: [
                .font: bodyFont, .foregroundColor: bodyColor, .paragraphStyle: paragraph,
            ]))
            if index < messages.count - 1 { rendered.append(NSAttributedString(string: "\n\n")) }
        }
        transcriptView.textStorage?.setAttributedString(rendered)
        transcriptView.scrollToEndOfDocument(nil)
    }
}

final class CodexChatComposerTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, !flags.contains(.shift), !hasMarkedText() {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }
}
