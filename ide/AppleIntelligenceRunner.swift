import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// Apple Intelligence backend, via FoundationModels' LanguageModelSession.
//
// Supports two underlying models:
//   • On-device system model — macOS 26+ (smaller, free, fully private).
//   • Private Cloud Compute (PCC) server model — macOS 27+ (bigger, runs in
//     Apple's verifiable cloud; subject to quota).
//
// All call sites gate on `@available(macOS 26/27, *)` so the rest of the app
// keeps building / running on older OS versions.
//
// To match Claude's "knows about your project" behavior, sessions are built
// with two file-system tools — listFiles and readFile — both scoped to the
// project root the user opened in the IDE.
enum AppleIntelligenceRunner {

    enum ModelKind: Equatable, Sendable {
        case onDevice
        case privateCloudCompute

        var label: String {
            switch self {
            case .onDevice: return "Apple on-device"
            case .privateCloudCompute: return "Apple PCC"
            }
        }
    }

    static let instructions: String = """
    You are embedded in a minimal macOS IDE. Answer the user's questions \
    about the project they have open.

    Each turn, you are given the FULL project file tree as context — a flat \
    list of files with paths relative to the project root, like:
      antyhing/message.txt
      Sources/Foo.swift
      README.md

    Two tools are available:
      • listFiles(path) — recursively lists the project (or a subdirectory). \
        Use ONLY if you need to re-check after files may have changed.
      • readFile(path) — reads the contents of a file. ALWAYS use the full \
        root-relative path as shown in the file tree, e.g. \
        readFile("antyhing/message.txt"), NOT readFile("message.txt").

    RULES:
      1. The file tree in your context is authoritative. Don't claim a file \
         is "not in the project" if it's listed there.
      2. To read a file, pass its FULL root-relative path to readFile.
      3. Be concise.
    """

    /// A reusable conversation backed by either the on-device model or PCC.
    /// Hold one of these for the lifetime of a chat so multi-turn context
    /// is preserved across `respond` calls.
    @available(macOS 26.0, *)
    @MainActor
    final class Session {
        private let session: LanguageModelSession
        let projectRoot: URL?
        let kind: ModelKind

        // Held so we can read quotaUsage / availability on demand. Boxed as
        // Any to avoid a stored property whose type is gated on macOS 27.
        private let pccBox: Any?

        init(projectRoot: URL?, kind: ModelKind) {
            self.projectRoot = projectRoot
            self.kind = kind
            let tools: [any Tool] = projectRoot.map { root in
                [ListFilesTool(projectRoot: root), ReadFileTool(projectRoot: root)]
            } ?? []

            // CRITICAL: project context goes in instructions, NOT in each
            // user prompt. LanguageModelSession keeps the transcript across
            // respond() calls; injecting the file tree per-turn made it grow
            // by ~200 lines every message, blowing the on-device model's
            // small context window after just a few turns. The instructions
            // string lives outside the rolling transcript, so context grows
            // by only the user's message + assistant reply per turn.
            let instructions = Self.buildInstructions(projectRoot: projectRoot)

            switch kind {
            case .onDevice:
                self.pccBox = nil
                self.session = LanguageModelSession(
                    tools: tools,
                    instructions: instructions
                )
            case .privateCloudCompute:
                if #available(macOS 27.0, *) {
                    let pcc = PrivateCloudComputeLanguageModel()
                    self.pccBox = pcc
                    self.session = LanguageModelSession(
                        model: pcc,
                        tools: tools,
                        instructions: instructions
                    )
                } else {
                    self.pccBox = nil
                    self.session = LanguageModelSession(
                        tools: tools,
                        instructions: instructions
                    )
                }
            }
        }

        private static func buildInstructions(projectRoot: URL?) -> String {
            var parts = [AppleIntelligenceRunner.instructions]
            if let root = projectRoot {
                // Keep the listing small — on-device model has a tight context
                // window and the instructions are sent on every turn. Tool
                // `listFiles` is still available if the model wants more.
                let entries = AppleIntelligenceRunner.recursiveListing(root: root, limit: 50)
                parts.append("")
                parts.append("PROJECT CONTEXT:")
                parts.append("Root: \(root.path)")
                parts.append("Files (first 50, root-relative):")
                for e in entries { parts.append("  \(e)") }
            }
            return parts.joined(separator: "\n")
        }

        func respond(to userPrompt: String) async throws -> String {
            // Prompt is now JUST the user's message. The project file tree
            // lives in instructions (above) so it isn't duplicated into the
            // transcript every turn.
            let response = try await session.respond {
                userPrompt
            }
            return response.content
        }

        /// One-line summary of PCC quota state, or nil for on-device.
        var quotaSummary: String? {
            guard kind == .privateCloudCompute else { return nil }
            if #available(macOS 27.0, *),
               let pcc = pccBox as? PrivateCloudComputeLanguageModel {
                let q = pcc.quotaUsage
                switch q.status {
                case .belowLimit(let below):
                    return below.isApproachingLimit
                        ? "PCC quota: approaching limit"
                        : "PCC quota: OK"
                case .limitReached:
                    if let reset = q.resetDate {
                        let fmt = RelativeDateTimeFormatter()
                        return "PCC quota: reached (resets \(fmt.localizedString(for: reset, relativeTo: .now)))"
                    }
                    return "PCC quota: reached"
                }
            }
            return nil
        }

    }

    // Heavy/generated directories we never want to descend into. They make
    // the listing huge and aren't useful to summarize.
    static let skippedDirNames: Set<String> = [
        ".git", ".hg", ".svn",
        "node_modules", "Pods", "Carthage",
        ".build", "build", "DerivedData", ".swiftpm",
        "target", "dist", "out", ".next",
        "__pycache__", ".venv", "venv", ".tox",
        ".idea", ".vscode",
        ".DS_Store",
    ]

    /// Recursive walk of the project, returning project-root-relative paths.
    /// Capped at `limit` entries; if exceeded, the final entry is a
    /// "(truncated…)" sentinel. Hidden files are skipped, plus the names in
    /// `skippedDirNames` (so we don't descend into node_modules etc.).
    static func recursiveListing(root: URL, subdir: String = "", limit: Int = 500) -> [String] {
        let trimmed = subdir.trimmingCharacters(in: .whitespacesAndNewlines)
        let rootStd = root.standardizedFileURL
        let startURL = trimmed.isEmpty
            ? rootStd
            : rootStd.appendingPathComponent(trimmed).standardizedFileURL

        // Don't let the model wander above the project root.
        guard startURL.path.hasPrefix(rootStd.path) else {
            return ["(out of bounds)"]
        }

        guard let enumerator = FileManager.default.enumerator(
            at: startURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else {
            return ["(unable to read)"]
        }

        let rootPath = rootStd.path
        var results: [String] = []

        for case let url as URL in enumerator {
            if results.count >= limit {
                results.append("…(truncated at \(limit) entries)")
                break
            }
            let name = url.lastPathComponent
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if skippedDirNames.contains(name) {
                if isDir { enumerator.skipDescendants() }
                continue
            }
            let fullPath = url.standardizedFileURL.path
            guard fullPath.hasPrefix(rootPath) else { continue }
            let rel = String(
                fullPath
                    .dropFirst(rootPath.count)
                    .drop(while: { $0 == "/" })
            )
            results.append(isDir ? "\(rel)/" : rel)
        }

        return results.sorted()
    }

    /// Human-readable explanation when the requested model can't be used;
    /// nil when OK. Safe to call on any OS — older OS just gets a
    /// "requires macOS X" message.
    @MainActor
    static func unavailableReason(for kind: ModelKind) -> String? {
        switch kind {
        case .onDevice:
            if #available(macOS 26.0, *) {
                return onDeviceReason()
            }
            return "Apple Intelligence requires macOS 26 or later."
        case .privateCloudCompute:
            if #available(macOS 27.0, *) {
                return pccReason()
            }
            return "Private Cloud Compute requires macOS 27 or later."
        }
    }

    @available(macOS 26.0, *)
    @MainActor
    private static func onDeviceReason() -> String? {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available: return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "This Mac doesn't support Apple Intelligence."
            case .appleIntelligenceNotEnabled:
                return "Turn on Apple Intelligence in System Settings → Apple Intelligence & Siri, then relaunch."
            case .modelNotReady:
                return "Apple Intelligence model is still downloading. Try again shortly."
            @unknown default:
                return "Apple Intelligence is unavailable."
            }
        }
    }

    @available(macOS 27.0, *)
    @MainActor
    private static func pccReason() -> String? {
        let model = PrivateCloudComputeLanguageModel()
        switch model.availability {
        case .available: return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "This Mac isn't eligible for Private Cloud Compute."
            case .systemNotReady:
                return "Private Cloud Compute isn't ready yet on this device. Make sure Apple Intelligence is enabled and try again."
            @unknown default:
                return "Private Cloud Compute is unavailable."
            }
        }
    }
}

// MARK: - Tools given to the on-device model
//
// Both tools resolve their `path` argument relative to `projectRoot` and
// reject any path that escapes the root (so the model can't read `/etc` or
// the user's home dir even if it tries). Output is capped to keep the
// context window manageable.

@available(macOS 26.0, *)
struct ListFilesTool: Tool {
    let name = "listFiles"
    let description = "Recursively list files and folders in the user's project as a flat list of project-root-relative paths. Pass path=\"\" for the whole project, or a subdirectory like \"src\" to scope the listing."

    let projectRoot: URL

    @Generable
    struct Arguments {
        @Guide(description: "Subdirectory relative to the project root. Empty string for everything.")
        var path: String
    }

    func call(arguments: Arguments) async throws -> String {
        FileHandle.standardError.write(Data(
            "[ListFilesTool] called with path=\"\(arguments.path)\" (recursive)\n".utf8
        ))
        let entries = AppleIntelligenceRunner.recursiveListing(
            root: projectRoot,
            subdir: arguments.path,
            limit: 500
        )
        FileHandle.standardError.write(Data(
            "[ListFilesTool] returning \(entries.count) entries\n".utf8
        ))
        return entries.isEmpty ? "(empty)" : entries.joined(separator: "\n")
    }
}

@available(macOS 26.0, *)
struct ReadFileTool: Tool {
    let name = "readFile"
    let description = "Read the contents of a text file inside the user's project, at a path relative to the project root."

    let projectRoot: URL

    @Generable
    struct Arguments {
        @Guide(description: "Path to a text file, relative to the project root.")
        var path: String
    }

    func call(arguments: Arguments) async throws -> String {
        FileHandle.standardError.write(Data(
            "[ReadFileTool] called with path=\"\(arguments.path)\"\n".utf8
        ))
        let target = try resolve(arguments.path, under: projectRoot)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir),
              !isDir.boolValue else {
            return "File not found: \(arguments.path)"
        }
        let raw = try String(contentsOf: target, encoding: .utf8)
        // Cap at ~50 KB to avoid blowing the on-device context window.
        let cap = 50_000
        return raw.count > cap ? String(raw.prefix(cap)) + "\n…(truncated)" : raw
    }
}

// Resolve `relativePath` against `root` and reject anything that escapes it.
private func resolve(_ relativePath: String, under root: URL) throws -> URL {
    let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
    let target = root
        .appendingPathComponent(trimmed)
        .standardizedFileURL
    let rootStd = root.standardizedFileURL.path
    if !target.path.hasPrefix(rootStd) {
        throw ToolPathError.outsideProject(target.path)
    }
    return target
}

private enum ToolPathError: Error, LocalizedError {
    case outsideProject(String)
    var errorDescription: String? {
        switch self {
        case .outsideProject(let p): return "Path \(p) is outside the project root."
        }
    }
}

// MARK: - Type-erased session holder
//
// SwiftUI @State can't hold a value whose TYPE is gated on @available
// (you'd need @available on the property itself, which Swift doesn't allow
// in that position). So we box it as Any and cast on use.
//
// Keys the cached session on (projectRoot, kind) so the box rebuilds when
// either the open folder or the chosen model changes.
@MainActor
final class AppleSessionBox {
    private var inner: Any?
    private var builtForRoot: URL?
    private var builtForKind: AppleIntelligenceRunner.ModelKind?

    @available(macOS 26.0, *)
    func session(projectRoot: URL?, kind: AppleIntelligenceRunner.ModelKind) -> AppleIntelligenceRunner.Session {
        if let s = inner as? AppleIntelligenceRunner.Session,
           builtForRoot == projectRoot,
           builtForKind == kind {
            return s
        }
        let s = AppleIntelligenceRunner.Session(projectRoot: projectRoot, kind: kind)
        inner = s
        builtForRoot = projectRoot
        builtForKind = kind
        return s
    }

    func reset() {
        inner = nil
        builtForRoot = nil
        builtForKind = nil
    }
}
