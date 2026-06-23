import Foundation

// Backend that runs an exported `.aimodel` (Apple's Core AI on-device LLM
// format) by shelling out to the `llm-runner` CLI from `apple/coreai-models`.
//
// Three pieces have to be present for this to actually run:
//   1. The runtime framework: /System/Library/Frameworks/CoreAI.framework
//      — ships with macOS 27, NOT present on macOS 26.
//   2. The user's `llm-runner` binary, built from their checkout:
//        cd ~/coreai-models && swift build --product llm-runner -c release
//   3. A `.aimodel` bundle exported via the Python recipes.
//
// `unavailableReason()` checks all three and returns a precise message about
// which one is missing. If everything's there, `run(...)` shells out and
// returns the generated text.
enum CoreAIRunner {

    enum RunError: Error, LocalizedError {
        case runtimeMissing
        case runnerMissing(String)
        case modelMissing(String)
        case launchFailed(String)
        case nonZeroExit(Int32, String)

        var errorDescription: String? {
            switch self {
            case .runtimeMissing:
                return "Core AI framework isn't present on this Mac. It ships with macOS 27 — your exported .aimodel is ready when you upgrade."
            case .runnerMissing(let path):
                return "llm-runner not found at \(path). Build it with: cd ~/coreai-models && swift build --product llm-runner -c release"
            case .modelMissing(let path):
                return "No .aimodel at \(path). Pick a different file or export one via the coreai-models Python pipeline."
            case .launchFailed(let m):
                return "Failed to launch llm-runner: \(m)"
            case .nonZeroExit(let code, let body):
                return "llm-runner exited \(code): \(body.prefix(400))"
            }
        }
    }

    /// Default location where the user's `llm-runner` build lives.
    static var defaultRunnerURL: URL {
        URL(fileURLWithPath: "\(NSHomeDirectory())/coreai-models/.build/release/llm-runner")
    }

    /// Default `.aimodel` bundle (the qwen3 0.6B export the user produced).
    static var defaultModelURL: URL {
        URL(fileURLWithPath: "\(NSHomeDirectory())/coreai-models/exports/qwen3_0_6b_4bit_dynamic/qwen3_0_6b_4bit_dynamic.aimodel")
    }

    /// nil when ready to run; otherwise human-readable explanation.
    static func unavailableReason(modelURL: URL?) -> String? {
        let runtimePath = "/System/Library/Frameworks/CoreAI.framework/CoreAI"
        if !FileManager.default.fileExists(atPath: runtimePath) {
            return "Core AI framework not on disk (requires macOS 27). Your .aimodel is ready when you upgrade."
        }
        let runner = defaultRunnerURL
        if !FileManager.default.isExecutableFile(atPath: runner.path) {
            return "llm-runner not built. Run: cd ~/coreai-models && swift build --product llm-runner -c release"
        }
        if let m = modelURL, !FileManager.default.fileExists(atPath: m.path) {
            return "Selected .aimodel doesn't exist: \(m.path)"
        }
        if modelURL == nil {
            return "Pick a .aimodel file first."
        }
        return nil
    }

    static let systemPrompt: String = """
    You are embedded in a minimal macOS IDE. Answer the user's questions \
    about the project they have open.

    Each turn you are given the FULL project file tree as context — a flat \
    list of files with paths relative to the project root, like:
      antyhing/message.txt
      Sources/Foo.swift
      README.md

    Treat that list as authoritative. Be concise.
    """

    /// Run a single turn against the model. `priorTurns` lets us fake
    /// multi-turn by replaying prior User/Assistant exchanges in the prompt,
    /// since llm-runner is one-shot on the wire.
    static func run(
        userPrompt: String,
        modelURL: URL,
        priorTurns: [(user: String, assistant: String)],
        projectRoot: URL?,
        maxTokens: Int = 1024,
        temperature: Double = 0.7
    ) async throws -> String {
        if let reason = unavailableReason(modelURL: modelURL) {
            // Surface the reason as an error so the caller can append a note.
            if reason.contains("Core AI framework") { throw RunError.runtimeMissing }
            if reason.contains("llm-runner") { throw RunError.runnerMissing(defaultRunnerURL.path) }
            throw RunError.modelMissing(modelURL.path)
        }

        // Build the one-shot prompt: system + project context + history +
        // current user turn, ending with "Assistant:" so the model knows
        // it's its turn.
        var lines: [String] = [systemPrompt]
        if let root = projectRoot {
            let entries = AppleIntelligenceRunner.recursiveListing(root: root, limit: 200)
            lines.append("")
            lines.append("Project root: \(root.path)")
            lines.append("Project files (root-relative):")
            for e in entries { lines.append("  \(e)") }
        }
        lines.append("")
        for turn in priorTurns {
            lines.append("User: \(turn.user)")
            lines.append("Assistant: \(turn.assistant)")
        }
        lines.append("User: \(userPrompt)")
        lines.append("Assistant: ")
        let prompt = lines.joined(separator: "\n")

        return try await Task.detached(priority: .userInitiated) {
            let task = Process()
            task.executableURL = defaultRunnerURL
            task.arguments = [
                "--model", modelURL.path,
                "--prompt", prompt,
                "--max-tokens", "\(maxTokens)",
                "--temperature", "\(temperature)",
            ]

            let outPipe = Pipe()
            let errPipe = Pipe()
            task.standardOutput = outPipe
            task.standardError = errPipe

            do { try task.run() }
            catch { throw RunError.launchFailed(error.localizedDescription) }

            async let outData: Data = readAll(outPipe.fileHandleForReading)
            async let errData: Data = readAll(errPipe.fileHandleForReading)
            let (out, err) = await (outData, errData)
            task.waitUntilExit()
            let status = task.terminationStatus

            let stdout = String(data: out, encoding: .utf8) ?? ""
            let stderr = String(data: err, encoding: .utf8) ?? ""

            if status != 0 {
                // dyld misses on macOS 26 because CoreAI.framework isn't on
                // disk. Translate to a specific runtime-missing error.
                if stderr.contains("CoreAI.framework") && stderr.contains("Library not loaded") {
                    throw RunError.runtimeMissing
                }
                throw RunError.nonZeroExit(
                    status,
                    stderr.isEmpty ? stdout : stderr
                )
            }

            // llm-runner prints generation tokens to stdout, possibly with
            // status lines mixed in. Best-effort: take the text after the
            // last "Assistant:" if present, else the whole stdout, trimmed.
            let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed
        }.value
    }

    private static func readAll(_ handle: FileHandle) async -> Data {
        await Task.detached(priority: .utility) {
            (try? handle.readToEnd()) ?? Data()
        }.value
    }
}
