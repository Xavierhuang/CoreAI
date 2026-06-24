import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// iOS-side wrapper around FoundationModels. Simpler than the Mac version:
// no `Tool` protocol (no project folder on iPhone), no PCC option until the
// user upgrades to iOS 27 — gated by ModelKind.
//
// FoundationModels availability:
//   • SystemLanguageModel  — iOS 26+, on Apple-Intelligence-eligible iPhones
//                            (15 Pro / 15 Pro Max / 16 series / 17 series …)
//   • PrivateCloudCompute  — iOS 27+, same hardware eligibility
enum AppleChat {

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
    You are a helpful assistant running entirely on the user's iPhone. \
    Be concise and direct. Plain text only — no markdown headings.
    """

    /// A reusable conversation. Hold one of these for the lifetime of a chat
    /// so multi-turn context is preserved across `respond` calls.
    @available(iOS 26.0, macOS 26.0, *)
    @MainActor
    final class Session {
        private let session: LanguageModelSession
        let kind: ModelKind
        private let pccBox: Any?

        init(kind: ModelKind) {
            self.kind = kind
            switch kind {
            case .onDevice:
                self.pccBox = nil
                self.session = LanguageModelSession(instructions: AppleChat.instructions)
            case .privateCloudCompute:
                if #available(iOS 27.0, macOS 27.0, *) {
                    let pcc = PrivateCloudComputeLanguageModel()
                    self.pccBox = pcc
                    self.session = LanguageModelSession(
                        model: pcc,
                        instructions: AppleChat.instructions
                    )
                } else {
                    self.pccBox = nil
                    self.session = LanguageModelSession(instructions: AppleChat.instructions)
                }
            }
        }

        func respond(to prompt: String) async throws -> String {
            let response = try await session.respond(to: prompt)
            return response.content
        }
    }

    /// nil when this kind is usable; otherwise a friendly explanation.
    @MainActor
    static func unavailableReason(for kind: ModelKind) -> String? {
        switch kind {
        case .onDevice:
            if #available(iOS 26.0, macOS 26.0, *) {
                return onDeviceReason()
            }
            return "Apple Intelligence requires iOS 26 or later."
        case .privateCloudCompute:
            if #available(iOS 27.0, macOS 27.0, *) {
                return pccReason()
            }
            return "Private Cloud Compute requires iOS 27 or later."
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    @MainActor
    private static func onDeviceReason() -> String? {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available: return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "This iPhone doesn't support Apple Intelligence. Need iPhone 15 Pro or newer."
            case .appleIntelligenceNotEnabled:
                return "Turn on Apple Intelligence in Settings → Apple Intelligence & Siri."
            case .modelNotReady:
                return "Apple Intelligence is still downloading. Try again shortly."
            @unknown default:
                return "Apple Intelligence is unavailable."
            }
        }
    }

    @available(iOS 27.0, macOS 27.0, *)
    @MainActor
    private static func pccReason() -> String? {
        let model = PrivateCloudComputeLanguageModel()
        switch model.availability {
        case .available: return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "This iPhone isn't eligible for Private Cloud Compute."
            case .systemNotReady:
                return "Private Cloud Compute isn't ready. Enable Apple Intelligence and try again."
            @unknown default:
                return "Private Cloud Compute is unavailable."
            }
        }
    }
}

// MARK: - Type-erased session holder (same pattern as the Mac version)

@MainActor
final class AppleChatBox {
    private var inner: Any?
    private var builtForKind: AppleChat.ModelKind?

    @available(iOS 26.0, macOS 26.0, *)
    func session(kind: AppleChat.ModelKind) -> AppleChat.Session {
        if let s = inner as? AppleChat.Session, builtForKind == kind {
            return s
        }
        let s = AppleChat.Session(kind: kind)
        inner = s
        builtForKind = kind
        return s
    }

    func reset() {
        inner = nil
        builtForKind = nil
    }
}
