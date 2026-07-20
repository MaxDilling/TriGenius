import Foundation
import FoundationModels

// MARK: - Apple Foundation Model Backend
//
// On-device Apple Intelligence backend. Unlike the stateless cloud backends,
// this one OWNS its conversation: it keeps a single `LanguageModelSession`
// alive across turns (faster follow-ups, real multi-turn context) and lets the
// framework run the tool-call loop internally via `CoachToolBridge` tools.

@available(iOS 27.0, macOS 27.0, *)
@MainActor
final class AppleFoundationModelBackend: LLMBackend {
    let displayName = "Apple Intelligence"
    let supportsTools = true
    let managesOwnConversation = true

    /// When `true`, the session runs on Apple's Private Cloud Compute
    /// (`PrivateCloudComputeLanguageModel`, the stronger server model) instead of
    /// the on-device `SystemLanguageModel.default`. Both are fed the same bridged
    /// tools + instructions, so the coach behaves identically bar model strength.
    private let useCloud: Bool

    init(useCloud: Bool = false) {
        self.useCloud = useCloud
    }

    var isAvailable: Bool {
        AppleModelAvailability.isAvailable(cloud: useCloud)
    }

    /// Persistent session — `nil` until the first turn after a reset, then reused.
    private var session: LanguageModelSession?

    /// Prior conversation to rehydrate into the next session build (set by
    /// `seedTranscript`, e.g. after a restart or a mid-chat backend switch).
    /// Consumed and cleared when the session is created, so the on-device model
    /// keeps context that would otherwise live only in the discarded session.
    private var pendingSeed: [ConversationTurn] = []

    /// Runs the actual tool handler. Set by CoachBrain via `setToolExecutor`.
    private var toolExecutor: (@Sendable (String, String) async -> String)?

    // MARK: - LLMBackend

    func setToolExecutor(_ executor: @escaping @Sendable (String, String) async -> String) {
        self.toolExecutor = executor
    }

    func resetConversation() {
        session = nil
    }

    func seedTranscript(_ turns: [ConversationTurn]) {
        pendingSeed = turns
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
        // The system prompt is baked into the session ONCE — it is not re-sent each
        // turn. CoachBrain rebuilds the session (resetConversation) when the data
        // source / profile changes so instructions stay current, re-seeding the
        // prior turns so context survives. A blank-slate session uses `instructions:`;
        // a restored/switched-into one rehydrates from a Transcript of the seed.
        let session: LanguageModelSession
        if pendingSeed.isEmpty {
            session = useCloud
                ? LanguageModelSession(model: PrivateCloudComputeLanguageModel(), tools: bridged, instructions: systemPrompt)
                : LanguageModelSession(model: SystemLanguageModel.default, tools: bridged, instructions: systemPrompt)
        } else {
            let transcript = Self.makeTranscript(systemPrompt: systemPrompt, seed: pendingSeed)
            session = useCloud
                ? LanguageModelSession(model: PrivateCloudComputeLanguageModel(), tools: bridged, transcript: transcript)
                : LanguageModelSession(model: SystemLanguageModel.default, tools: bridged, transcript: transcript)
            pendingSeed = []
        }
        self.session = session
        return session
    }

    /// Rebuild a `Transcript` from the persisted text turns: a leading
    /// instructions entry (the system prompt) then one prompt/response entry per
    /// user/assistant turn. Tool turns aren't in the seed (we persist text only),
    /// so the transcript is clean prompt/response pairs.
    private static func makeTranscript(systemPrompt: String, seed: [ConversationTurn]) -> Transcript {
        var entries: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: systemPrompt))],
                toolDefinitions: []
            ))
        ]
        for turn in seed {
            let text = turn.parts.compactMap { part -> String? in
                if case .text(let t) = part { return t }
                return nil
            }.joined(separator: "\n")
            guard !text.isEmpty else { continue }
            let segment = Transcript.Segment.text(Transcript.TextSegment(content: text))
            switch turn.role {
            case .user: entries.append(.prompt(Transcript.Prompt(segments: [segment])))
            case .assistant: entries.append(.response(Transcript.Response(segments: [segment])))
            }
        }
        return Transcript(entries: entries)
    }

    private func ensureAvailable() throws {
        if let message = AppleModelAvailability.unavailableMessage(cloud: useCloud) {
            throw FoundationModelError.unavailable(message: message)
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

// MARK: - Availability
//
// One place to ask "can Apple's model answer right now?", for both the
// on-device `SystemLanguageModel` and the Private Cloud Compute server model.
// Feeds the backend's readiness checks and the Settings status readout.

@available(iOS 27.0, macOS 27.0, *)
enum AppleModelAvailability {
    /// A UI-ready line about one model: available + (for cloud) its quota state.
    struct Status {
        let isAvailable: Bool
        /// Reason it's unavailable, or the quota note when available; `nil` = plain "available".
        let detail: String?
    }

    static func isAvailable(cloud: Bool) -> Bool {
        cloud ? cloudStatus().isAvailable : onDeviceStatus().isAvailable
    }

    /// A localized reason string when the chosen model can't answer, else `nil`.
    static func unavailableMessage(cloud: Bool) -> String? {
        let status = cloud ? cloudStatus() : onDeviceStatus()
        return status.isAvailable ? nil : status.detail
    }

    static func onDeviceStatus() -> Status {
        switch SystemLanguageModel.default.availability {
        case .available:
            return Status(isAvailable: true, detail: nil)
        case .unavailable(let reason):
            return Status(isAvailable: false, detail: message(for: reason))
        }
    }

    static func cloudStatus() -> Status {
        let model = PrivateCloudComputeLanguageModel()
        switch model.availability {
        case .available:
            return Status(isAvailable: true, detail: quotaNote(model.quotaUsage))
        case .unavailable(let reason):
            return Status(isAvailable: false, detail: message(for: reason))
        }
    }

    private static func quotaNote(_ usage: PrivateCloudComputeLanguageModel.QuotaUsage) -> String? {
        switch usage.status {
        case .belowLimit(let below):
            return below.isApproachingLimit ? "Quota almost used up" : nil
        case .limitReached:
            if let reset = usage.resetDate {
                return "Quota reached — resets \(reset.formatted(.relative(presentation: .named)))"
            }
            return "Quota reached"
        @unknown default:
            return nil
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

    private static func message(for reason: PrivateCloudComputeLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This device doesn't support Private Cloud Compute."
        case .systemNotReady:
            return "Private Cloud Compute is still getting ready. Please try again shortly."
        @unknown default:
            return "Private Cloud Compute is currently unavailable."
        }
    }
}

// MARK: - Factory

enum FoundationModelBackendFactory {
    static func make(useCloud: Bool = false) -> LLMBackend {
        if #available(iOS 27.0, macOS 27.0, *) {
            return AppleFoundationModelBackend(useCloud: useCloud)
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
