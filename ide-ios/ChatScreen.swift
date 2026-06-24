import SwiftUI

// Main (and only) screen on iPhone. Backend picker at top, transcript in
// the middle, input row at the bottom — the iOS-native chat layout.
//
// Only Apple Intelligence backends appear (iOS can't shell out to the
// `claude` CLI or run an Ollama daemon, and Core AI on iOS would need the
// CoreAILanguageModels SPM dep — left for a future pass).
struct ChatScreen: View {

    @State private var backend: Backend = .appleLocal
    @State private var messages: [Message] = [
        .note("Type a message and pick a backend at the top. Apple Local is free + private. Apple Cloud (PCC) needs iOS 27.")
    ]
    @State private var inputText: String = ""
    @State private var busy: Bool = false

    @State private var appleLocalBox = AppleChatBox()
    @State private var applePCCBox = AppleChatBox()
    @State private var appleLocalUnavailable: String? = nil
    @State private var applePCCUnavailable: String? = nil

    @State private var inflightTask: Task<Void, Never>?
    @State private var thinkingStartedAt: Date?

    enum Backend: String, CaseIterable, Identifiable {
        case appleLocal = "Apple"
        case applePCC = "Apple PCC"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Backend", selection: $backend) {
                ForEach(Backend.allCases) { b in
                    Text(b.rawValue).tag(b)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)
            .disabled(busy)

            availabilityBanner

            transcript

            inputRow
        }
        .navigationTitle("CoreAI · iPhone")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    clearChat()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(busy)
            }
        }
        .onAppear { refreshAvailability() }
        .onChange(of: backend) { refreshAvailability() }
    }

    @ViewBuilder
    private var availabilityBanner: some View {
        let reason: String? = backend == .appleLocal ? appleLocalUnavailable : applePCCUnavailable
        if let reason {
            Text(reason)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.yellow.opacity(0.18))
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(messages) { msg in
                        bubble(msg).id(msg.id)
                    }
                    if busy {
                        thinkingView.id("thinking")
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: messages.count) {
                if let last = messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: busy) {
                if busy { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } }
            }
        }
    }

    @ViewBuilder
    private func bubble(_ msg: Message) -> some View {
        switch msg.role {
        case .you, .apple:
            VStack(alignment: .leading, spacing: 4) {
                Text(msg.role.label)
                    .font(.caption2.bold())
                    .foregroundStyle(msg.role.tint)
                Text(msg.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .note:
            Text(msg.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var thinkingView: some View {
        TimelineView(.periodic(from: thinkingStartedAt ?? .now, by: 0.4)) { ctx in
            let elapsed = Int(ctx.date.timeIntervalSince(thinkingStartedAt ?? ctx.date))
            let tick = Int(ctx.date.timeIntervalSince(thinkingStartedAt ?? ctx.date) / 0.4)
            let dots = String(repeating: ".", count: tick % 4)
            let suffix = elapsed > 0 ? " (\(elapsed)s)" : ""
            Text("Thinking\(dots)\(suffix)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField("Ask Apple…", text: $inputText, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .disabled(busy)
                .submitLabel(.send)
                .onSubmit { startSend() }
            Button(busy ? "Stop" : "Send") {
                if busy {
                    inflightTask?.cancel()
                } else {
                    startSend()
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Behavior

    private func refreshAvailability() {
        appleLocalUnavailable = AppleChat.unavailableReason(for: .onDevice)
        applePCCUnavailable = AppleChat.unavailableReason(for: .privateCloudCompute)
    }

    private func clearChat() {
        messages = [.note("Cleared. Sessions reset.")]
        appleLocalBox.reset()
        applePCCBox.reset()
    }

    private func startSend() {
        guard inflightTask == nil else { return }
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || busy { return }
        inputText = ""
        messages.append(.user(trimmed))
        inflightTask = Task {
            await runTurn(prompt: trimmed)
            inflightTask = nil
        }
    }

    @MainActor
    private func runTurn(prompt: String) async {
        busy = true
        thinkingStartedAt = .now
        defer {
            busy = false
            thinkingStartedAt = nil
        }

        let kind: AppleChat.ModelKind = (backend == .applePCC) ? .privateCloudCompute : .onDevice
        if let reason = AppleChat.unavailableReason(for: kind) {
            messages.append(.note(reason))
            return
        }

        guard #available(iOS 26.0, macOS 26.0, *) else {
            messages.append(.note("Apple Intelligence requires iOS 26 or later."))
            return
        }

        let box = (kind == .privateCloudCompute) ? applePCCBox : appleLocalBox
        do {
            let session = box.session(kind: kind)
            let reply = try await session.respond(to: prompt)
            messages.append(.apple(reply.isEmpty ? "(no text)" : reply))
        } catch {
            if error is CancellationError {
                messages.append(.note("Cancelled."))
            } else {
                messages.append(.note("\(kind.label) error: \(error.localizedDescription)"))
            }
        }
    }
}

// MARK: - Message model

struct Message: Identifiable, Equatable {
    enum Role {
        case you, apple, note
        var label: String {
            switch self {
            case .you: return "You"
            case .apple: return "Apple Intelligence"
            case .note: return ""
            }
        }
        var tint: Color {
            switch self {
            case .you: return .primary
            case .apple: return .blue
            case .note: return .secondary
            }
        }
    }
    let id = UUID()
    let role: Role
    let text: String

    static func user(_ t: String) -> Message { .init(role: .you, text: t) }
    static func apple(_ t: String) -> Message { .init(role: .apple, text: t) }
    static func note(_ t: String) -> Message { .init(role: .note, text: t) }
}
