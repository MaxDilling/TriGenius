import Foundation

// MARK: - Tool Definition

nonisolated struct ToolDefinition {
    let name: String
    let description: String
    /// JSON Schema object (type: "object", properties: {...}, required: [...])
    let parameters: [String: Any]
}

// MARK: - Conversation Model

struct ConversationTurn {
    enum Role { case user, assistant }
    let role: Role
    let parts: [TurnPart]

    static func user(_ text: String) -> ConversationTurn {
        ConversationTurn(role: .user, parts: [.text(text)])
    }

    static func assistantText(_ text: String) -> ConversationTurn {
        ConversationTurn(role: .assistant, parts: [.text(text)])
    }

    static func assistantToolCalls(_ calls: [ToolCallRecord]) -> ConversationTurn {
        ConversationTurn(role: .assistant, parts: calls.map { .toolCall($0) })
    }

    static func toolResults(_ results: [ToolResultRecord]) -> ConversationTurn {
        ConversationTurn(role: .user, parts: results.map { .toolResult($0) })
    }
}

enum TurnPart {
    case text(String)
    case toolCall(ToolCallRecord)
    case toolResult(ToolResultRecord)
}

struct ToolCallRecord {
    let name: String
    let arguments: [String: Any]
    /// Opaque, backend-specific token that must be echoed back with the tool
    /// call when continuing the conversation. OpenAI-compatible backends stash
    /// the `tool_call_id` here; other backends ignore it.
    var thoughtSignature: String? = nil
}

struct ToolResultRecord {
    let name: String
    let result: String
}

// MARK: - LLM Completion

/// One web-search citation (`url_citation` annotation) attached to a reply.
struct WebCitation: Equatable {
    let title: String?
    let url: String
}

struct LLMCompletion {
    let text: String?
    let toolCalls: [ToolCallRecord]
    /// Web-search citations the provider reported for this turn — surfaced as
    /// a globe badge on the chat bubble whose popover lists the sources.
    var webCitations: [WebCitation] = []

    var hasToolCalls: Bool { !toolCalls.isEmpty }
}

/// Incremental output from a streaming `complete(...)` call.
enum LLMStreamEvent {
    /// A chunk of newly generated assistant text (a delta, not cumulative).
    case text(String)
    /// A chunk of the model's reasoning trace (a delta) — models that don't
    /// emit reasoning never produce this event.
    case reasoning(String)
    /// Terminal event: the full completion, including any tool calls. The
    /// CoachBrain loop needs this to decide whether to run another iteration.
    case completed(LLMCompletion)
}

// MARK: - Backend Protocol

protocol LLMBackend: AnyObject {
    var displayName: String { get }
    var supportsTools: Bool { get }
    var isAvailable: Bool { get }

    /// When `true`, the backend owns its own conversation transcript and runs
    /// the tool-call loop internally (e.g. Apple FoundationModels). CoachBrain
    /// must NOT feed prior turns or drive its own loop — it calls `respond(...)`
    /// / `respondStreaming(...)` with only the latest user message.
    /// When `false` (default), CoachBrain drives the loop via `complete(...)`.
    var managesOwnConversation: Bool { get }

    func complete(
        systemPrompt: String,
        turns: [ConversationTurn],
        tools: [ToolDefinition]
    ) async throws -> LLMCompletion

    /// Streaming variant of `complete(...)` for CoachBrain-driven backends.
    /// Emits `.text` deltas as the model generates, then a single `.completed`
    /// carrying the full text and any tool calls. The default implementation
    /// wraps `complete(...)` and emits the whole reply in one delta, so
    /// non-streaming backends need not implement it.
    func completeStreaming(
        systemPrompt: String,
        turns: [ConversationTurn],
        tools: [ToolDefinition]
    ) -> AsyncThrowingStream<LLMStreamEvent, Error>

    /// Single-turn entry for self-managing backends. `systemPrompt` / `tools`
    /// configure the session on first use after a reset; later calls reuse it.
    func respond(
        userMessage: String,
        systemPrompt: String,
        tools: [ToolDefinition]
    ) async throws -> String

    /// Streaming variant. Yields the *cumulative* assistant text as it grows.
    func respondStreaming(
        userMessage: String,
        systemPrompt: String,
        tools: [ToolDefinition]
    ) -> AsyncThrowingStream<String, Error>

    /// Tear down any persistent session/transcript. Called on backend change,
    /// data-source change, and manual reset.
    func resetConversation()

    /// Optionally warm up the model ahead of the first turn. No-op by default.
    func prewarm(systemPrompt: String, tools: [ToolDefinition])

    /// Install the closure a self-managing backend uses to execute tool calls.
    /// Receives the tool name and a JSON string of arguments, returns the
    /// tool's textual result. No-op for backends that don't call tools.
    func setToolExecutor(_ executor: @escaping @Sendable (String, String) async -> String)
}

// MARK: - Default implementations
//
// Backends that don't manage their own conversation (OpenAI-compatible, stubs)
// get these for free and keep using `complete(...)` driven by CoachBrain.

extension LLMBackend {
    var managesOwnConversation: Bool { false }

    func respond(
        userMessage: String,
        systemPrompt: String,
        tools: [ToolDefinition]
    ) async throws -> String {
        let completion = try await complete(
            systemPrompt: systemPrompt,
            turns: [.user(userMessage)],
            tools: tools
        )
        return completion.text ?? ""
    }

    func completeStreaming(
        systemPrompt: String,
        turns: [ConversationTurn],
        tools: [ToolDefinition]
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let completion = try await complete(
                        systemPrompt: systemPrompt,
                        turns: turns,
                        tools: tools
                    )
                    if let text = completion.text, !text.isEmpty {
                        continuation.yield(.text(text))
                    }
                    continuation.yield(.completed(completion))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func respondStreaming(
        userMessage: String,
        systemPrompt: String,
        tools: [ToolDefinition]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let text = try await respond(
                        userMessage: userMessage,
                        systemPrompt: systemPrompt,
                        tools: tools
                    )
                    continuation.yield(text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func resetConversation() {}

    func setToolExecutor(_ executor: @escaping @Sendable (String, String) async -> String) {}

    func prewarm(systemPrompt: String, tools: [ToolDefinition]) {}
}
