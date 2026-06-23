import Foundation

// Drives the `claude` CLI in print mode, so it uses the user's Claude
// subscription (their `claude login` session) rather than a pay-per-use API
// key. The CLI runs its own read/write/edit tool loop scoped to `cwd`.
enum ClaudeRunner {

    struct TurnResult {
        let sessionID: String?
        let resultText: String
        let isError: Bool
    }

    enum RunError: Error, LocalizedError {
        case claudeNotFound
        case launchFailed(String)
        case nonJSONOutput(status: Int32, message: String)

        var errorDescription: String? {
            switch self {
            case .claudeNotFound:
                return "Couldn't find the `claude` CLI. Install Claude Code and run "
                     + "`claude login` to sign in with your subscription, then relaunch."
            case .launchFailed(let m):
                return "Failed to launch claude: \(m)"
            case .nonJSONOutput(let s, let m):
                return "claude CLI error (exit \(s)): \(m)"
            }
        }
    }

    static let systemPrompt: String = """
    You are embedded in a minimal macOS IDE. Make focused changes to files in \
    the working directory and briefly explain what you did.

    When you need the user to make a real decision or resolve an ambiguity, \
    ask a multiple-choice question instead of guessing. To do that, reply \
    with ONLY a fenced code block labeled ask_user containing JSON, and \
    nothing else in that turn:
    ```ask_user
    {"question": "Which database should I use?", "options": ["SQLite", "Postgres"]}
    ```
    The IDE renders each option as a clickable button and sends the user's \
    choice back as the next message. The user may also type a custom answer. \
    Use this only for genuine decisions — don't over-ask.
    """

    // A GUI app launched via Finder/`open` inherits a minimal PATH, so we
    // probe the usual install locations directly.
    static func locateClaude() -> String? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude",
        ]
        return candidates.first(where: { fm.isExecutableFile(atPath: $0) })
    }

    /// Run one turn. Returns parsed JSON result. Off-main-thread safe to call.
    static func run(prompt: String, cwd: URL, sessionID: String?) async throws -> TurnResult {
        guard let cli = locateClaude() else { throw RunError.claudeNotFound }

        return try await Task.detached(priority: .userInitiated) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: cli)
            var args: [String] = [
                "-p", prompt,
                "--output-format", "json",
                // Full agent powers: print mode can't prompt for approval, so
                // bypass permission gating to give the embedded agent the same
                // reach as Claude Code (Bash, Read, Write, Edit, …). This is a
                // trusted, single-user IDE running on the user's machine.
                "--permission-mode", "bypassPermissions",
                "--append-system-prompt", systemPrompt,
            ]
            if let sid = sessionID, !sid.isEmpty {
                args += ["--resume", sid]
            }
            task.arguments = args
            task.currentDirectoryURL = cwd

            // Give the child a workable PATH so it can find node/helpers.
            var env = ProcessInfo.processInfo.environment
            let home = NSHomeDirectory()
            let existing = env["PATH"] ?? ""
            env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(existing)"
            task.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            task.standardOutput = outPipe
            task.standardError = errPipe

            do {
                try task.run()
            } catch {
                throw RunError.launchFailed(error.localizedDescription)
            }

            // Drain both pipes concurrently so a full stderr buffer can't
            // deadlock the child while we block reading stdout.
            async let outData: Data = readAll(outPipe.fileHandleForReading)
            async let errData: Data = readAll(errPipe.fileHandleForReading)
            let (out, err) = await (outData, errData)
            task.waitUntilExit()
            let status = task.terminationStatus

            if let parsed = try? JSONSerialization.jsonObject(with: out) as? [String: Any] {
                let sid = parsed["session_id"] as? String
                let result = parsed["result"] as? String ?? ""
                let isError = (parsed["is_error"] as? Bool) ?? false
                return TurnResult(sessionID: sid, resultText: result, isError: isError)
            }

            let errStr = String(data: err, encoding: .utf8) ?? ""
            let outStr = String(data: out, encoding: .utf8) ?? ""
            let msg = !errStr.isEmpty ? errStr : (!outStr.isEmpty ? outStr : "no output")
            throw RunError.nonJSONOutput(
                status: status,
                message: msg.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }.value
    }

    private static func readAll(_ handle: FileHandle) async -> Data {
        await Task.detached(priority: .utility) {
            (try? handle.readToEnd()) ?? Data()
        }.value
    }

    // MARK: - ask_user parsing

    struct AskUser {
        let question: String
        let options: [String]
    }

    /// Extract an ask_user request from Claude's reply. Accepts either a
    /// fenced ```ask_user … ``` block or a bare JSON object with "question".
    static func parseAskUser(from text: String) -> AskUser? {
        guard !text.isEmpty else { return nil }
        var jsonStr: String?

        if let fenceRange = text.range(of: "```ask_user") {
            let afterFence = text[fenceRange.upperBound...]
            if let closeRange = afterFence.range(of: "```") {
                jsonStr = String(afterFence[..<closeRange.lowerBound])
            } else {
                jsonStr = String(afterFence)
            }
        } else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") && trimmed.contains("\"question\"") {
                jsonStr = trimmed
            }
        }

        guard let raw = jsonStr?.trimmingCharacters(in: .whitespacesAndNewlines),
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let q = obj["question"] as? String, !q.isEmpty
        else { return nil }

        let opts = (obj["options"] as? [Any])?.compactMap { $0 as? String } ?? []
        return AskUser(question: q, options: opts)
    }
}
