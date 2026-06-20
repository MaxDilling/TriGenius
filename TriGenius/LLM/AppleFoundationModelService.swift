import Foundation
import FoundationModels

// MARK: - Apple Foundation Model Backend
//
// On-device Apple Intelligence backend. Unlike the (stateless) Gemini backend,
// this one OWNS its conversation: it keeps a single `LanguageModelSession`
// alive across turns (faster follow-ups, real multi-turn context) and lets the
// framework run the tool-call loop internally via `CoachToolBridge` tools.

@available(iOS 27.0, macOS 27.0, *)
@MainActor
final class AppleFoundationModelBackend: LLMBackend {
    let displayName = "Apple Intelligence"
    let supportsTools = true
    let managesOwnConversation = true

    var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Persistent session — `nil` until the first turn after a reset, then reused.
    private var session: LanguageModelSession?

    /// Runs the actual tool handler. Set by CoachBrain via `setToolExecutor`.
    private var toolExecutor: (@Sendable (String, String) async -> String)?

    // MARK: - LLMBackend

    func setToolExecutor(_ executor: @escaping @Sendable (String, String) async -> String) {
        self.toolExecutor = executor
    }

    func resetConversation() {
        session = nil
    }

    func respond(
        userMessage: String,
        systemPrompt: String,
        tools: [ToolDefinition]
    ) async throws -> String {
        try ensureAvailable()
        let session = try makeOrReuseSession(systemPrompt: systemPrompt, tools: tools)
        let result = try await session.respond(to: userMessage)
        return result.content
    }

    func respondStreaming(
        userMessage: String,
        systemPrompt: String,
        tools: [ToolDefinition]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    try ensureAvailable()
                    let session = try makeOrReuseSession(systemPrompt: systemPrompt, tools: tools)
                    // Snapshot `.content` is the cumulative response text so far.
                    for try await snapshot in session.streamResponse(to: userMessage) {
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Prepare the model so the first real turn responds faster.
    func prewarm(systemPrompt: String, tools: [ToolDefinition]) {
        guard isAvailable,
              let session = try? makeOrReuseSession(systemPrompt: systemPrompt, tools: tools)
        else { return }
        session.prewarm()
    }

    // Required by the protocol but unused for this backend
    // (`managesOwnConversation == true`). Forward to `respond` defensively.
    func complete(
        systemPrompt: String,
        turns: [ConversationTurn],
        tools: [ToolDefinition]
    ) async throws -> LLMCompletion {
        let lastUserText = turns.last { $0.role == .user }
            .map { turn in
                turn.parts.compactMap { part -> String? in
                    if case .text(let t) = part { return t }
                    return nil
                }.joined(separator: "\n")
            } ?? ""
        let text = try await respond(userMessage: lastUserText, systemPrompt: systemPrompt, tools: tools)
        return LLMCompletion(text: text, toolCalls: [])
    }

    // MARK: - Session lifecycle

    private func makeOrReuseSession(
        systemPrompt: String,
        tools: [ToolDefinition]
    ) throws -> LanguageModelSession {
        if let session { return session }

        let executor = toolExecutor ?? { _, _ in
            "Tool executor not configured."
        }
        let bridged: [any Tool] = try tools.map {
            try CoachToolBridge(definition: $0, executor: executor)
        }
        // The system prompt is baked into the session instructions ONCE — it is
        // not re-sent each turn. CoachBrain rebuilds the session (resetConversation)
        // when the data source / profile changes so instructions stay current.
        let session = LanguageModelSession(model: .default, tools: bridged, instructions: systemPrompt)
        self.session = session
        return session
    }

    private func ensureAvailable() throws {
        switch SystemLanguageModel.default.availability {
        case .available:
            return
        case .unavailable(let reason):
            throw FoundationModelError.unavailable(message: Self.message(for: reason))
        }
    }

    private static func message(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This device doesn't support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Please enable Apple Intelligence in Settings."
        case .modelNotReady:
            return "The Apple Intelligence model is still loading. Please try again shortly."
        @unknown default:
            return "Apple Intelligence is currently unavailable."
        }
    }
}

// MARK: - Unavailability Stub
//
// Returned only if the API surface is somehow unavailable (older OS than the
// deployment target). Kept as a safety net.

final class UnavailableFoundationModelBackend: LLMBackend {
    let displayName = "Apple Intelligence (unavailable)"
    let supportsTools = false
    let isAvailable = false

    func complete(
        systemPrompt: String,
        turns: [ConversationTurn],
        tools: [ToolDefinition]
    ) async throws -> LLMCompletion {
        throw FoundationModelError.notAvailable
    }
}

// MARK: - Factory

enum FoundationModelBackendFactory {
    static func make() -> LLMBackend {
        if #available(iOS 27.0, macOS 27.0, *) {
            return AppleFoundationModelBackend()
        } else {
            return UnavailableFoundationModelBackend()
        }
    }
}

// MARK: - Errors

enum FoundationModelError: LocalizedError {
    case notAvailable
    case unavailable(message: String)

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Apple Intelligence is not available on this device."
        case .unavailable(let message):
            return message
        }
    }
}
