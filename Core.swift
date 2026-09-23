import Foundation
import FoundationModels

// Shared by the app (main.swift) and the command-line tool (cli.swift).

enum Chat {
    /// e.g. "AFM 3 Core Advanced · 8,192-token context". The variant and its
    /// context size depend on the Mac.
    static var modelSummary: String {
        let model = SystemLanguageModel.default
        return "\(model.variant.displayName) · \(model.contextSize.formatted())-token context"
    }

    static func unavailableMessage(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            "This Mac doesn't support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            "Apple Intelligence is turned off. Enable it in System Settings > Apple Intelligence & Siri."
        case .modelNotReady:
            "The model is still downloading or preparing. Try again in a bit."
        @unknown default:
            "The model is unavailable for an unknown reason."
        }
    }

    /// Answers one stateless query (no conversation carry-over).
    /// `onPartial` receives the whole response so far on every update.
    ///
    /// The on-device model occasionally aborts mid-generation (tokengeneration
    /// error 10); one retry usually recovers, so a failed first attempt is
    /// reported through `onRetry` and run again.
    @MainActor
    static func answer(_ question: String,
                       onRetry: () -> Void = {},
                       onPartial: (String) -> Void) async throws {
        for attempt in 1...2 {
            do {
                let stream = LanguageModelSession().streamResponse(to: question)
                for try await partial in stream { onPartial(partial.content) }
                return
            } catch let error where attempt == 1 && isRetryable(error) {
                onRetry()
            }
        }
    }

    /// Whether a failure is worth one retry. The typed model errors (context
    /// overflow, guardrails, refusals, unsupported language…) would fail the
    /// same way again; timeouts and untyped aborts may not.
    private static func isRetryable(_ error: any Error) -> Bool {
        switch error {
        case is CancellationError:
            false
        case LanguageModelError.timeout:
            true
        case is LanguageModelError, is LanguageModelSession.Error, is SystemLanguageModel.Error:
            false
        default:
            true
        }
    }

    static func describe(_ error: any Error) -> String {
        if case .contextSizeExceeded(let info)? = error as? LanguageModelError {
            return "The question doesn't fit the model's \(info.contextSize.formatted())-token context. Try a shorter one."
        }
        return "Error: \(error.localizedDescription)"
    }
}
