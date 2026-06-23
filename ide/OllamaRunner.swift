import Foundation

// HTTP client for a local Ollama daemon at http://localhost:11434.
//
// Two paths:
//   • chat(model:messages:)        — plain prompt → answer. No tools.
//   • chatWithTools(model:...)     — exposes listFiles/readFile to the model
//                                    via Ollama's /api/chat tool_calls protocol
//                                    (OpenAI-compatible). Runs a local loop:
//                                    if the model emits tool_calls, we execute
//                                    them against the project root and feed
//                                    the results back, then ask again.
//
// Whether the small local models reliably USE tools is a model-quality
// question. We expose them; they may still skip and just answer from the
// system prompt (which contains a pre-injected file tree as fallback).
enum OllamaRunner {

    static let baseURL = URL(string: "http://localhost:11434")!

    /// On-the-wire chat message. Roles: "system" / "user" / "assistant" / "tool".
    /// When the model calls tools, the assistant message carries `tool_calls`
    /// (and `content` is usually empty). Tool-result messages we send back
    /// carry `name` so the model knows which tool returned what.
    struct Message: Codable, Sendable, Equatable {
        let role: String
        let content: String
        let tool_calls: [ToolCall]?
        let name: String?

        init(role: String, content: String, tool_calls: [ToolCall]? = nil, name: String? = nil) {
            self.role = role
            self.content = content
            self.tool_calls = tool_calls
            self.name = name
        }
    }

    /// One tool call emitted by the model.
    struct ToolCall: Codable, Sendable, Equatable {
        let function: Function

        struct Function: Codable, Sendable, Equatable {
            let name: String
            // Ollama always serializes arguments as a JSON object. Our tools
            // only take string args, so `[String: String]` covers it.
            let arguments: [String: String]
        }
    }

    /// JSON-schema-style tool advertisement sent in the /api/chat body.
    struct ToolSpec: Encodable, Sendable {
        let type: String   // "function"
        let function: FunctionSpec

        struct FunctionSpec: Encodable, Sendable {
            let name: String
            let description: String
            let parameters: Parameters
        }

        struct Parameters: Encodable, Sendable {
            let type: String   // "object"
            let properties: [String: PropertySpec]
            let required: [String]
        }

        struct PropertySpec: Encodable, Sendable {
            let type: String
            let description: String
        }
    }

    enum RunError: Error, LocalizedError {
        case serverUnreachable
        case noModelsInstalled
        case badResponse(Int, String)
        case decodeFailed(String)
        case toolLoopExceeded(Int)

        var errorDescription: String? {
            switch self {
            case .serverUnreachable:
                return "Can't reach Ollama at localhost:11434. Run `ollama serve` or open the Ollama app, then try again."
            case .noModelsInstalled:
                return "Ollama is running but no models are installed. Run `ollama pull qwen2.5-coder:7b` (or similar) first."
            case .badResponse(let code, let body):
                return "Ollama returned HTTP \(code): \(body.prefix(200))"
            case .decodeFailed(let msg):
                return "Couldn't parse Ollama response: \(msg)"
            case .toolLoopExceeded(let n):
                return "Model called tools too many times in a row (>\(n)). Aborting."
            }
        }
    }

    // MARK: - Listing models

    static func availableModels() async throws -> [String] {
        struct ListResponse: Decodable {
            struct Entry: Decodable { let name: String }
            let models: [Entry]
        }

        let url = baseURL.appendingPathComponent("api/tags")
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(from: url)
        } catch {
            throw RunError.serverUnreachable
        }
        do {
            let resp = try JSONDecoder().decode(ListResponse.self, from: data)
            return resp.models.map(\.name).sorted()
        } catch {
            throw RunError.decodeFailed(error.localizedDescription)
        }
    }

    // MARK: - Plain chat (no tools)

    static func chat(model: String, messages: [Message]) async throws -> String {
        let resp = try await chatRaw(model: model, messages: messages, tools: nil)
        return resp.message.content
    }

    // MARK: - Tool-calling chat
    //
    // Loops: send → if model returned tool_calls, execute them locally,
    // append a tool-role message for each result, send again. Stops when the
    // model returns content without tool_calls, or when we hit maxIterations.

    static func chatWithTools(
        model: String,
        initialMessages: [Message],
        projectRoot: URL?,
        maxIterations: Int = 5
    ) async throws -> Message {
        var msgs = initialMessages
        var toolsToSend: [ToolSpec]? = toolSpecs()

        for _ in 0..<maxIterations {
            let raw: ChatRawResponse
            do {
                raw = try await chatRaw(model: model, messages: msgs, tools: toolsToSend)
            } catch let RunError.badResponse(status, body)
                where status == 400 && body.contains("does not support tools") {
                // The model's template doesn't declare tool support (common
                // for older models like deepseek-coder:6.7b). Fall back to
                // tool-less chat — the model still gets the pre-injected
                // file tree in the system prompt and can answer from that.
                FileHandle.standardError.write(Data(
                    "[OllamaRunner] \(model) does not support tools — retrying without\n".utf8
                ))
                toolsToSend = nil
                raw = try await chatRaw(model: model, messages: msgs, tools: nil)
            }

            let assistant = raw.message
            if let calls = assistant.tool_calls, !calls.isEmpty {
                // The assistant turn (with tool_calls and usually empty
                // content) must be in history before the tool responses.
                msgs.append(assistant)
                for call in calls {
                    let result = executeTool(
                        name: call.function.name,
                        arguments: call.function.arguments,
                        projectRoot: projectRoot
                    )
                    msgs.append(Message(
                        role: "tool",
                        content: result,
                        name: call.function.name
                    ))
                }
                continue
            }
            return assistant
        }
        throw RunError.toolLoopExceeded(maxIterations)
    }

    // MARK: - Low-level POST /api/chat

    private struct ChatRawResponse: Decodable {
        let message: Message
        let done: Bool
    }

    private static func chatRaw(
        model: String,
        messages: [Message],
        tools: [ToolSpec]?
    ) async throws -> ChatRawResponse {
        struct ChatRequest: Encodable {
            let model: String
            let messages: [Message]
            let tools: [ToolSpec]?
            let stream: Bool
        }

        let url = baseURL.appendingPathComponent("api/chat")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 900   // 15 min — big local models on CPU can be SLOW

        let body = ChatRequest(model: model, messages: messages, tools: tools, stream: false)
        req.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            // Pass through cancellation/timeout cleanly.
            throw error
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw RunError.badResponse(http.statusCode, body)
        }

        do {
            return try JSONDecoder().decode(ChatRawResponse.self, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw RunError.decodeFailed("\(error.localizedDescription) — body: \(body.prefix(300))")
        }
    }

    // MARK: - Tool catalog + execution

    /// JSON-schema specs sent with each /api/chat request when tools are on.
    static func toolSpecs() -> [ToolSpec] {
        [
            ToolSpec(
                type: "function",
                function: .init(
                    name: "listFiles",
                    description: "Recursively list files and folders in the user's project as a flat list of project-root-relative paths. Pass path=\"\" for the whole project, or a subdirectory like \"src\" to scope the listing.",
                    parameters: .init(
                        type: "object",
                        properties: [
                            "path": .init(
                                type: "string",
                                description: "Subdirectory relative to the project root. Empty string for everything."
                            )
                        ],
                        required: ["path"]
                    )
                )
            ),
            ToolSpec(
                type: "function",
                function: .init(
                    name: "readFile",
                    description: "Read the contents of a text file in the user's project at a project-root-relative path (e.g. \"src/main.swift\").",
                    parameters: .init(
                        type: "object",
                        properties: [
                            "path": .init(
                                type: "string",
                                description: "Path to a text file, relative to the project root."
                            )
                        ],
                        required: ["path"]
                    )
                )
            ),
        ]
    }

    /// Resolve a model-requested tool call against the open project root.
    /// Returns a string suitable for use as the tool-role message content.
    static func executeTool(
        name: String,
        arguments: [String: String],
        projectRoot: URL?
    ) -> String {
        let path = arguments["path"] ?? ""
        FileHandle.standardError.write(Data(
            "[OllamaTool] \(name)(path=\"\(path)\")\n".utf8
        ))
        guard let root = projectRoot else {
            return "(no project folder is open in the IDE)"
        }
        switch name {
        case "listFiles":
            let entries = AppleIntelligenceRunner.recursiveListing(
                root: root, subdir: path, limit: 500
            )
            return entries.isEmpty ? "(empty)" : entries.joined(separator: "\n")
        case "readFile":
            return readFileSafely(root: root, relativePath: path)
        default:
            return "Unknown tool: \(name)"
        }
    }

    private static func readFileSafely(root: URL, relativePath: String) -> String {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = root.appendingPathComponent(trimmed).standardizedFileURL
        let rootStd = root.standardizedFileURL.path
        if !target.path.hasPrefix(rootStd) {
            return "Path \(target.path) is outside the project root."
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir),
              !isDir.boolValue else {
            return "File not found or is a directory: \(relativePath)"
        }
        guard let raw = try? String(contentsOf: target, encoding: .utf8) else {
            return "Couldn't read file as UTF-8: \(relativePath)"
        }
        let cap = 50_000
        return raw.count > cap ? String(raw.prefix(cap)) + "\n…(truncated)" : raw
    }

    // MARK: - System prompt

    /// System prompt shared with the model. Same shape as Apple's so the
    /// comparison stays fair. Tools are described separately in tool_specs;
    /// here we just tell the model when they're appropriate.
    static let systemPrompt: String = """
    You are embedded in a minimal macOS IDE. Answer the user's questions \
    about the project they have open.

    You have two tools available — listFiles and readFile — both scoped to \
    the user's open project folder. Use them when the user asks about \
    project contents, code, or file structure. The system prompt also \
    contains a pre-injected file tree as a hint, but the tools are the \
    authoritative source for current contents.

    Be concise.
    """
}
