import SwiftUI

// Chat panel with a 4-way backend picker:
//
//   • Claude         — agentic CLI, can edit files in the project root.
//   • Apple          — on-device FoundationModels (macOS 26+). Free, private,
//                      small model with tool calling.
//   • PCC            — Private Cloud Compute server model (macOS 27+).
//                      Bigger Apple model via attested cloud, quota-gated.
//   • Ollama         — local open-source models (Llama / Qwen / DeepSeek …)
//                      served by the local Ollama daemon at :11434. Picks
//                      whichever model the user has pulled.
//
// Each backend keeps its own session/history so flipping the picker doesn't
// reset other conversations.
struct AIChatView: View {

    let rootURL: URL?
    let onFilesModified: () -> Void

    @State private var backend: Backend = .claude
    @State private var messages: [ChatMessage] = [
        ChatMessage(role: .note,
                    text: "Open a folder, then ask. Picker switches between Claude (agentic), "
                        + "Apple on-device, Apple PCC, and Ollama (local open-source).")
    ]
    @State private var inputText: String = ""
    @State private var busy: Bool = false

    // Claude state
    @State private var claudeSessionID: String?
    @State private var askPending: Bool = false
    @State private var askOptions: [String] = []

    // Apple state — separate boxes so the two Apple conversations don't
    // clobber each other when you switch.
    @State private var appleLocalBox = AppleSessionBox()
    @State private var applePCCBox = AppleSessionBox()
    @State private var appleLocalUnavailable: String? = nil
    @State private var applePCCUnavailable: String? = nil
    @State private var pccQuotaSummary: String? = nil

    // Ollama state
    @State private var ollamaModels: [String] = []
    @State private var selectedOllamaModel: String = ""
    @State private var ollamaError: String? = nil
    @State private var ollamaHistory: [OllamaRunner.Message] = []

    // Core AI state — shells out to user's built llm-runner against a
    // user-picked .aimodel file. Multi-turn faked by replaying prior pairs.
    @State private var coreAIModelURL: URL? = CoreAIRunner.defaultModelURL
    @State private var coreAIError: String? = nil
    @State private var coreAIHistory: [(user: String, assistant: String)] = []

    // Thinking indicator
    @State private var thinkingStartedAt: Date?

    // In-flight turn so the user can cancel it (Send button becomes Stop).
    @State private var inflightTask: Task<Void, Never>?

    enum Backend: String, CaseIterable, Identifiable {
        case claude
        case appleLocal
        case applePCC
        case ollama
        case coreAI
        var id: Self { self }

        var pickerLabel: String {
            switch self {
            case .claude: return "Claude"
            case .appleLocal: return "Apple"
            case .applePCC: return "PCC"
            case .ollama: return "Ollama"
            case .coreAI: return "Core AI"
            }
        }

        var short: String {
            switch self {
            case .claude: return "Claude"
            case .appleLocal: return "Apple"
            case .applePCC: return "Apple PCC"
            case .ollama: return "Ollama"
            case .coreAI: return "Core AI"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            backendPicker
                .padding(.horizontal, 8)
                .padding(.top, 6)
            secondaryHeader
            transcript
            Divider()
            if backend == .claude && askPending && !askOptions.isEmpty {
                chipStrip
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            inputRow
                .padding(8)
        }
        .frame(minWidth: 240)
        .onAppear {
            refreshAppleAvailability()
            Task { await refreshOllamaModels() }
            refreshCoreAIStatus()
        }
        .onChange(of: backend) {
            refreshAppleAvailability()
            if backend == .ollama {
                Task { await refreshOllamaModels() }
            }
            if backend == .coreAI {
                refreshCoreAIStatus()
            }
        }
    }

    // Secondary line under the picker: PCC quota, Ollama model menu, etc.
    @ViewBuilder
    private var secondaryHeader: some View {
        switch backend {
        case .applePCC:
            if let quota = pccQuotaSummary {
                Text(quota)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .ollama:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Model:")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if ollamaModels.isEmpty {
                        Text(ollamaError ?? "loading…")
                            .font(.system(size: 11))
                            .foregroundStyle(ollamaError == nil ? Color.secondary : Color.red)
                    } else {
                        Menu {
                            ForEach(ollamaModels, id: \.self) { model in
                                Button(model) { selectedOllamaModel = model }
                            }
                        } label: {
                            Text(selectedOllamaModel.isEmpty ? "(pick one)" : selectedOllamaModel)
                                .font(.system(size: 11))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                    Spacer()
                    Button {
                        Task { await refreshOllamaModels() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                }
                freeRAMBadge
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
        case .coreAI:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Model:")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(coreAIModelURL?.lastPathComponent ?? "(pick a .aimodel)")
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { pickCoreAIModel() }
                        .controlSize(.small)
                }
                if let err = coreAIError {
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.orange)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
        default:
            EmptyView()
        }
    }

    // MARK: - Backend picker

    private var backendPicker: some View {
        Picker("", selection: $backend) {
            ForEach(Backend.allCases) { b in
                Text(b.pickerLabel).tag(b)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(busy)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { msg in
                        messageView(msg).id(msg.id)
                    }
                    if busy {
                        thinkingView.id("thinking")
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: messages.count) {
                if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: busy) {
                if busy { proxy.scrollTo("thinking", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func messageView(_ msg: ChatMessage) -> some View {
        switch msg.role {
        case .you, .claude, .appleLocal, .applePCC, .ollama, .coreAI:
            VStack(alignment: .leading, spacing: 2) {
                Text(msg.role.label)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(msg.role.tint)
                Text(msg.text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .note:
            Text(msg.text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var thinkingView: some View {
        TimelineView(.periodic(from: thinkingStartedAt ?? .now, by: 0.4)) { ctx in
            let elapsed = Int(ctx.date.timeIntervalSince(thinkingStartedAt ?? ctx.date))
            let tick = Int(ctx.date.timeIntervalSince(thinkingStartedAt ?? ctx.date) / 0.4)
            let dots = String(repeating: ".", count: tick % 4)
            let suffix = elapsed > 0 ? " (\(elapsed)s)" : ""
            Text("\(backend.short) is thinking\(dots)\(suffix)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Chips (Claude only)

    private var chipStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(askOptions, id: \.self) { opt in
                    Button(opt) {
                        Task { await submitClaudeAnswer(opt) }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Input

    private var inputRow: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $inputText)
                .textFieldStyle(.roundedBorder)
                .disabled(busy && !askPending)
                .onSubmit { startSendIfIdle() }
            Button(busy ? "Stop" : "Send") {
                if busy {
                    inflightTask?.cancel()
                } else {
                    startSendIfIdle()
                }
            }
            .keyboardShortcut(.return, modifiers: [])
            // Enabled always: when busy → cancels; when idle → sends.
            // Disable only during the small askPending+busy edge case so a
            // double-tap doesn't double-fire.
            .disabled(busy && askPending)
        }
    }

    private var placeholder: String {
        if backend == .claude && askPending { return "Or type a custom response…" }
        return "Ask \(backend.short)…"
    }

    // MARK: - Apple availability

    private func refreshAppleAvailability() {
        appleLocalUnavailable = AppleIntelligenceRunner.unavailableReason(for: .onDevice)
        applePCCUnavailable = AppleIntelligenceRunner.unavailableReason(for: .privateCloudCompute)
        refreshPCCQuota()
    }

    private func refreshPCCQuota() {
        guard backend == .applePCC, #available(macOS 26.0, *) else {
            pccQuotaSummary = nil
            return
        }
        let session = applePCCBox.session(projectRoot: rootURL, kind: .privateCloudCompute)
        pccQuotaSummary = session.quotaSummary
    }

    // MARK: - Free RAM badge

    /// Shows free RAM with color-coded threshold. Auto-refreshes every 3s via
    /// TimelineView. Red = local LLMs will fall back to CPU. Yellow = tight,
    /// small models OK. Green = comfortable for 1-4 GB models.
    @ViewBuilder
    private var freeRAMBadge: some View {
        TimelineView(.periodic(from: .now, by: 3.0)) { _ in
            let r = SystemStats.memoryReport()
            let gb = r.freeGB
            let color: Color = gb >= 3 ? .green : (gb >= 1 ? .yellow : .red)
            let hint: String = gb >= 3
                ? "Plenty for small models on GPU"
                : (gb >= 1 ? "Tight — small models only" : "Likely CPU fallback")
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(String(format: "%.1f GB free", gb))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("· \(hint)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Core AI discovery

    private func refreshCoreAIStatus() {
        coreAIError = CoreAIRunner.unavailableReason(modelURL: coreAIModelURL)
    }

    private func pickCoreAIModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true  // .aimodel is a package directory
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []
        if panel.runModal() == .OK, let url = panel.urls.first {
            coreAIModelURL = url
            refreshCoreAIStatus()
        }
    }

    // MARK: - Ollama discovery

    private func refreshOllamaModels() async {
        do {
            let models = try await OllamaRunner.availableModels()
            ollamaModels = models
            ollamaError = nil
            if selectedOllamaModel.isEmpty || !models.contains(selectedOllamaModel) {
                selectedOllamaModel = models.first ?? ""
            }
            if models.isEmpty {
                ollamaError = "No models installed. Try `ollama pull qwen2.5-coder:7b`."
            }
        } catch {
            ollamaModels = []
            selectedOllamaModel = ""
            ollamaError = error.localizedDescription
        }
    }

    // MARK: - Send / answer

    /// Start a new turn if we're not already running one. Stores the Task
    /// in `inflightTask` so the Stop button can cancel it. Cancellation
    /// propagates into URLSession (Ollama) and LanguageModelSession (Apple)
    /// natively; Process-based backends (Claude, Core AI) won't kill the
    /// child process but the UI will stop waiting.
    private func startSendIfIdle() {
        guard inflightTask == nil else { return }
        inflightTask = Task {
            await send()
            inflightTask = nil
        }
    }

    /// Recognize cancellation across the various Apple/URL APIs so we can
    /// show a single calm "Cancelled" note instead of a scary error.
    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let u = error as? URLError, u.code == .cancelled { return true }
        // Apple's LanguageModelSession surfaces cancellation as a String
        // in some cases; fall back to a substring check.
        let s = error.localizedDescription.lowercased()
        return s.contains("cancelled") || s.contains("canceled")
    }

    private func send() async {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)

        if backend == .claude && askPending {
            if trimmed.isEmpty && !askOptions.isEmpty { return }
            await submitClaudeAnswer(trimmed)
            return
        }

        if busy { return }
        if trimmed.isEmpty { return }

        switch backend {
        case .claude:
            guard let cwd = rootURL else {
                messages.append(.note("Open a folder first — that's where Claude will work."))
                return
            }
            inputText = ""
            messages.append(.user(trimmed))
            await runClaudeTurn(prompt: trimmed, cwd: cwd)

        case .appleLocal:
            if let reason = appleLocalUnavailable {
                messages.append(.note(reason))
                return
            }
            inputText = ""
            messages.append(.user(trimmed))
            await runAppleTurn(prompt: trimmed, kind: .onDevice)

        case .applePCC:
            if let reason = applePCCUnavailable {
                messages.append(.note(reason))
                return
            }
            inputText = ""
            messages.append(.user(trimmed))
            await runAppleTurn(prompt: trimmed, kind: .privateCloudCompute)

        case .ollama:
            if selectedOllamaModel.isEmpty {
                messages.append(.note(ollamaError ?? "Pick an Ollama model first."))
                return
            }
            inputText = ""
            messages.append(.user(trimmed))
            await runOllamaTurn(prompt: trimmed)

        case .coreAI:
            if let reason = CoreAIRunner.unavailableReason(modelURL: coreAIModelURL) {
                messages.append(.note(reason))
                return
            }
            inputText = ""
            messages.append(.user(trimmed))
            await runCoreAITurn(prompt: trimmed)
        }
    }

    // MARK: - Claude turn

    private func submitClaudeAnswer(_ answer: String) async {
        askPending = false
        askOptions = []
        inputText = ""
        messages.append(.note("You answered: \(answer.isEmpty ? "(empty)" : answer)"))
        guard let cwd = rootURL else {
            messages.append(.note("Open a folder first — that's where Claude will work."))
            return
        }
        await runClaudeTurn(prompt: answer, cwd: cwd)
    }

    private func runClaudeTurn(prompt: String, cwd: URL) async {
        startThinking()
        defer { stopThinking() }
        do {
            let result = try await ClaudeRunner.run(
                prompt: prompt, cwd: cwd, sessionID: claudeSessionID
            )
            if let sid = result.sessionID { claudeSessionID = sid }
            onFilesModified()

            if result.isError {
                messages.append(.note("Claude error: \(result.resultText.isEmpty ? "unknown error" : result.resultText)"))
                return
            }
            if let ask = ClaudeRunner.parseAskUser(from: result.resultText) {
                messages.append(.claude(ask.question))
                askPending = true
                askOptions = ask.options
                return
            }
            messages.append(.claude(result.resultText.isEmpty ? "(no text)" : result.resultText))
        } catch {
            if isCancellation(error) {
                messages.append(.note("Cancelled (Claude CLI may still be running in the background)."))
            } else {
                messages.append(.note(error.localizedDescription))
            }
        }
    }

    // MARK: - Apple turn

    private func runAppleTurn(prompt: String, kind: AppleIntelligenceRunner.ModelKind) async {
        startThinking()
        defer {
            stopThinking()
            refreshPCCQuota()   // quota may have moved after a PCC turn
        }

        guard #available(macOS 26.0, *) else {
            messages.append(.note("Apple Intelligence requires macOS 26 or later."))
            return
        }

        let box = (kind == .privateCloudCompute) ? applePCCBox : appleLocalBox
        do {
            let session = box.session(projectRoot: rootURL, kind: kind)
            let answer = try await session.respond(to: prompt)
            let role: ChatMessage.Role = (kind == .privateCloudCompute) ? .applePCC : .appleLocal
            messages.append(.init(role: role, text: answer.isEmpty ? "(no text)" : answer))
        } catch {
            let raw = error.localizedDescription
            if isCancellation(error) {
                messages.append(.note("Cancelled."))
            } else if raw.lowercased().contains("context") && raw.lowercased().contains("window") {
                // Context overflow on the small on-device model — recover by
                // resetting the session so the next turn starts clean.
                box.reset()
                messages.append(.note(
                    "\(kind.label) ran out of context. Reset the conversation; ask again."
                ))
            } else {
                messages.append(.note("\(kind.label) error: \(raw)"))
            }
        }
    }

    // MARK: - Ollama turn

    private func runOllamaTurn(prompt: String) async {
        startThinking()
        defer { stopThinking() }

        // Build the on-the-wire conversation. The system prompt is rebuilt
        // each call so it reflects the current folder. We use `chatWithTools`
        // which exposes listFiles/readFile to the model and runs the local
        // tool loop. Models that don't tool-call will still answer from the
        // pre-injected file tree in the system prompt.
        var messagesToSend: [OllamaRunner.Message] = []
        messagesToSend.append(.init(role: "system", content: buildOllamaSystemPrompt()))
        messagesToSend.append(contentsOf: ollamaHistory)
        messagesToSend.append(.init(role: "user", content: prompt))

        do {
            let assistant = try await OllamaRunner.chatWithTools(
                model: selectedOllamaModel,
                initialMessages: messagesToSend,
                projectRoot: rootURL
            )
            // Persist only the user message + final assistant content for the
            // next turn. We drop the intermediate tool_calls + tool-result
            // messages — they'd inflate context and the model has the answer.
            ollamaHistory.append(.init(role: "user", content: prompt))
            ollamaHistory.append(.init(role: "assistant", content: assistant.content))
            messages.append(.init(
                role: .ollama,
                text: assistant.content.isEmpty ? "(no text)" : assistant.content
            ))
        } catch {
            if isCancellation(error) {
                messages.append(.note("Cancelled."))
            } else {
                messages.append(.note("Ollama error: \(error.localizedDescription)"))
            }
        }
    }

    private func buildOllamaSystemPrompt() -> String {
        var parts = [OllamaRunner.systemPrompt]
        if let root = rootURL {
            let entries = AppleIntelligenceRunner.recursiveListing(root: root, limit: 200)
            parts.append("")
            parts.append("Project root: \(root.path)")
            parts.append("Project files (root-relative):")
            for entry in entries {
                parts.append("  \(entry)")
            }
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Core AI turn

    private func runCoreAITurn(prompt: String) async {
        startThinking()
        defer { stopThinking() }

        guard let modelURL = coreAIModelURL else {
            messages.append(.note("Pick a .aimodel file first."))
            return
        }

        do {
            let reply = try await CoreAIRunner.run(
                userPrompt: prompt,
                modelURL: modelURL,
                priorTurns: coreAIHistory,
                projectRoot: rootURL
            )
            coreAIHistory.append((user: prompt, assistant: reply))
            messages.append(.init(role: .coreAI, text: reply.isEmpty ? "(no text)" : reply))
        } catch {
            if isCancellation(error) {
                messages.append(.note("Cancelled (llm-runner may still be running in the background)."))
            } else {
                messages.append(.note("Core AI error: \(error.localizedDescription)"))
                refreshCoreAIStatus()
            }
        }
    }

    private func startThinking() {
        busy = true
        thinkingStartedAt = .now
    }

    private func stopThinking() {
        busy = false
        thinkingStartedAt = nil
    }
}

// MARK: - Message model

struct ChatMessage: Identifiable, Equatable {
    enum Role {
        case you, claude, appleLocal, applePCC, ollama, coreAI, note
        var label: String {
            switch self {
            case .you: return "You"
            case .claude: return "Claude"
            case .appleLocal: return "Apple (on-device)"
            case .applePCC: return "Apple (PCC)"
            case .ollama: return "Ollama"
            case .coreAI: return "Core AI"
            case .note: return ""
            }
        }
        var tint: Color {
            switch self {
            case .you: return .primary
            case .claude: return .orange
            case .appleLocal: return .blue
            case .applePCC: return .purple
            case .ollama: return .green
            case .coreAI: return .pink
            case .note: return .secondary
            }
        }
    }
    let id = UUID()
    let role: Role
    let text: String

    static func user(_ t: String) -> ChatMessage { .init(role: .you, text: t) }
    static func claude(_ t: String) -> ChatMessage { .init(role: .claude, text: t) }
    static func note(_ t: String) -> ChatMessage { .init(role: .note, text: t) }
}
