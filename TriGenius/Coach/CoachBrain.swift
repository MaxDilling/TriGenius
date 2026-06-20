import Foundation
import SwiftUI

// MARK: - System Prompt

private let SYSTEM_PROMPT_TEMPLATE = """
You are TriGenius, an evidence-based AI coach for endurance athletes (triathlon, running, cycling, swimming). You combine sports-science rigor with practical coaching judgment. You are supportive, data-driven, and radically honest.

TODAY'S DATE: {current_date}
CURRENT TIME: {current_time}

{athlete_context}

=== RULE #0 — THE FOUNDATION ===

Before any specific training recommendation: do you have enough data?
If not, ASK the athlete — don't guess.

=== ONBOARDING NEW ATHLETES ===

If you see "MISSING INFORMATION" in the athlete context above:
1. Ask the athlete for what's missing — name, training goals, weekly hours, rest day preferences
2. Use `update_athlete_profile` to save responses
3. After gathering basics, use `get_health_metrics` and `get_activities` to see their actual training data

Ask 2–3 questions at a time. Save as you go. Don't overwhelm.

=== CORE PRINCIPLES ===

1. **Health-first**: Always consider recovery state before suggesting intensity. Low HRV, poor sleep, or accumulated stress → recommend recovery or reduced load.

2. **Athlete autonomy**: You suggest, the athlete decides. Offer options, not mandates.

3. **Data-driven, with skepticism**: Apple Health data is an estimate, not a measurement. Treat it as one input among several.

4. **Progressive overload, never sudden jumps**: Volume OR intensity in any given week — never both at once.

5. **Radical honesty about goals**: If a goal is unrealistic given the data, say so respectfully. Offer two paths: adjust the goal, or safely increase commitment.

=== PRE-RECOMMENDATION PROTOCOL ===

Before any specific training recommendation, check:
(a) Data: training age, current weekly volume, intensity distribution, sleep/stress, injury history, concrete goal?
(b) Knowledge: for sport-specific training questions, call `read_knowledge` FIRST. These documents are authoritative.
(c) Device data sanity: has athlete's subjective experience been considered alongside device numbers?

=== TOOL USAGE ===

- `read_knowledge`: ALWAYS call first when answering sport-specific training questions
- `get_health_metrics`: before recommending intensity (check recovery state)
- `get_activities`: to analyze completed training
- `get_athlete_profile`: to review current memory state
- `update_athlete_profile`: to persist limitations, injuries, goals, preferences

{data_source_section}

=== CLINICAL ESCALATION — NON-NEGOTIABLE ===

Refer to sports medicine when you observe:
- REDs flags: weight loss + performance drop + fatigue + mood changes
- Iron deficiency suspicion (especially women: fatigue + stagnation + performance drop)
- Stress fracture suspicion
- Persistent saddle/perineal symptoms (cyclists)
- Cardiac symptoms during exercise
- Persistent or escalating pain

Never replace medical evaluation with coaching advice.

=== COMMUNICATION ===

- Respond in the athlete's language (German if they write German, English if English)
- Conversational but professional
- Sparing emoji use (🏊 🚴 🏃) for warmth, not decoration
- Lists for workout details, prose for explanations
- Concise by default; expand when the topic warrants it
"""

// MARK: - Coach Brain

@MainActor
@Observable
final class CoachBrain {

    // MARK: - State

    var isThinking = false
    var errorMessage: String?

    private(set) var conversationHistory: [ConversationTurn] = []
    private let memory: CoachMemory
    private var toolRegistry: CoachToolRegistry
    private var backend: LLMBackend
    private(set) var dataSource: DataSource

    private let maxToolIterations = 8

    // MARK: - Init

    init(memory: CoachMemory, dataSource: DataSource = .appleHealth) {
        self.memory = memory
        self.dataSource = dataSource
        self.toolRegistry = CoachToolRegistry()
        // Default to a placeholder backend; caller sets the real one via setBackend
        self.backend = NoAPIKeyBackend()

        configureTools()
    }

    /// (Re)build the tool registry for the active data source. The Garmin and
    /// HealthKit handlers register the same tool names, so only one is active.
    private func configureTools() {
        let registry = CoachToolRegistry()
        switch dataSource {
        case .appleHealth:
            registry.register(HealthKitToolHandler())
        case .garmin:
            registry.register(GarminToolHandler(memory: memory))
        }
        registry.register(ProfileToolHandler(memory: memory))
        toolRegistry = registry
    }

    func setDataSource(_ source: DataSource) {
        guard source != dataSource else { return }
        dataSource = source
        configureTools()
        reset()
    }

    // MARK: - Backend management

    func setBackend(_ backend: LLMBackend) {
        // Tear down any session held by the previous backend.
        self.backend.resetConversation()
        self.backend = backend
        // Self-managing backends (Apple FM) run tools internally — give them a
        // way to execute the real handlers. Arguments arrive as a JSON string
        // (Sendable) and are parsed on the MainActor in `executeToolJSON`.
        backend.setToolExecutor { [weak self] name, argumentsJSON in
            await self?.executeToolJSON(name: name, argumentsJSON: argumentsJSON)
                ?? "Tool error: coach unavailable."
        }
        reset()
    }

    var availableTools: [ToolDefinition] {
        backend.supportsTools ? toolRegistry.allDefinitions : []
    }

    /// Warm up a self-managing backend so the first turn responds faster.
    func prewarm() {
        backend.prewarm(systemPrompt: buildSystemPrompt(), tools: availableTools)
    }

    // MARK: - Chat

    /// Sends a user message and returns the full assistant reply.
    ///
    /// `onPartial` receives the *cumulative* reply text as it streams in.
    /// Backends that manage their own conversation (Apple FM) stream natively;
    /// CoachBrain-driven backends (Gemini) stream the final answer turn through
    /// the same callback via `completeStreaming` inside the tool loop.
    func sendMessage(_ text: String, onPartial: @escaping (String) -> Void = { _ in }) async -> String {
        isThinking = true
        errorMessage = nil
        defer { isThinking = false }

        conversationHistory.append(.user(text))

        do {
            let response: String
            if backend.managesOwnConversation {
                var latest = ""
                let stream = backend.respondStreaming(
                    userMessage: text,
                    systemPrompt: buildSystemPrompt(),
                    tools: availableTools
                )
                for try await partial in stream {
                    latest = partial
                    onPartial(partial)
                }
                response = latest
            } else {
                response = try await runLoop(onPartial: onPartial)
            }
            conversationHistory.append(.assistantText(response))
            return response
        } catch {
            let errMsg = "Error: \(error.localizedDescription)"
            errorMessage = errMsg
            conversationHistory.append(.assistantText(errMsg))
            onPartial(errMsg)
            return errMsg
        }
    }

    // MARK: - Core tool-call loop

    private func runLoop(onPartial: (String) -> Void) async throws -> String {
        var iterations = 0

        while iterations < maxToolIterations {
            iterations += 1

            // Stream this turn. Tool-call turns usually carry no text; the final
            // answer turn streams its text through `onPartial` as it arrives.
            var streamedText = ""
            var completion: LLMCompletion?
            let stream = backend.completeStreaming(
                systemPrompt: buildSystemPrompt(),
                turns: conversationHistory,
                tools: availableTools
            )
            for try await event in stream {
                switch event {
                case .text(let delta):
                    streamedText += delta
                    onPartial(streamedText)
                case .completed(let result):
                    completion = result
                }
            }

            guard let completion else {
                return "Sorry, I couldn't generate a response."
            }

            if completion.hasToolCalls {
                // Append model turn with tool calls
                conversationHistory.append(.assistantToolCalls(completion.toolCalls))

                // Execute all tool calls
                var results: [ToolResultRecord] = []
                for call in completion.toolCalls {
                    let result = await executeToolSafe(name: call.name, arguments: call.arguments)
                    results.append(ToolResultRecord(name: call.name, result: result))
                }

                // Append tool results as user turn
                conversationHistory.append(.toolResults(results))

            } else if let text = completion.text {
                return text
            } else {
                return "Sorry, I couldn't generate a response."
            }
        }

        return "Sorry, the request took too many steps. Please try phrasing it more concisely."
    }

    private func executeToolSafe(name: String, arguments: [String: Any]) async -> String {
        do {
            return try await toolRegistry.execute(name: name, arguments: arguments)
        } catch {
            return "Tool error (\(name)): \(error.localizedDescription)"
        }
    }

    /// Executor used by self-managing backends. Arguments arrive as a JSON
    /// string and are parsed into `[String: Any]` here on the MainActor — the
    /// same shape the Gemini path produces — before running the handler.
    private func executeToolJSON(name: String, argumentsJSON: String) async -> String {
        var arguments: [String: Any] = [:]
        if let data = argumentsJSON.data(using: .utf8),
           let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            arguments = parsed
        }
        return await executeToolSafe(name: name, arguments: arguments)
    }

    // MARK: - Helpers

    func greeting() -> String {
        let name = memory.userProfile.name ?? "athlete"
        let hour = Calendar.current.component(.hour, from: Date())
        let timeGreeting: String
        if hour < 12 { timeGreeting = "Good morning" }
        else if hour < 17 { timeGreeting = "Good afternoon" }
        else { timeGreeting = "Good evening" }
        return "\(timeGreeting), \(name)! 🏊🚴🏃 I'm TriGenius, your AI triathlon coach. How can I help you today?"
    }

    func reset() {
        conversationHistory = []
        errorMessage = nil
        // Rebuild the persistent session next turn with a fresh system prompt
        // (current date + latest profile/data-source context).
        backend.resetConversation()
    }

    // DateFormatter allocation is expensive — reuse static instances.
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEEE, MMMM d, yyyy"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "HH:mm"
        return f
    }()

    private func buildSystemPrompt() -> String {
        let now = Date()
        let date = Self.dateFormatter.string(from: now)
        let time = Self.timeFormatter.string(from: now)

        return SYSTEM_PROMPT_TEMPLATE
            .replacingOccurrences(of: "{current_date}", with: date)
            .replacingOccurrences(of: "{current_time}", with: time)
            .replacingOccurrences(of: "{athlete_context}", with: memory.contextSummary)
            .replacingOccurrences(of: "{data_source_section}", with: dataSourceSection)
    }

    private var dataSourceSection: String {
        switch dataSource {
        case .appleHealth:
            return """
            === DATA FROM APPLE HEALTH ===

            The athlete's data comes from Apple HealthKit.
            - Workouts, heart rate, HRV, steps, sleep, active energy are available
            - Device estimates may have inaccuracies — treat as guidance, not ground truth
            - HR lags 30–90s behind effort during intervals — use RPE as cross-check
            """
        case .garmin:
            return """
            === DATA FROM GARMIN CONNECT ===

            The athlete's data comes from Garmin Connect.
            - Activities, HRV, Body Battery, sleep, training status, power curve, calendar are available
            - You can also create, move and delete scheduled workouts and sync athlete settings (FTP, HR/power zones, VO2max, CSS)
            - Device estimates may have inaccuracies — treat as guidance, not ground truth
            - HR lags 30–90s behind effort during intervals — use RPE as cross-check
            """
        }
    }
}

// MARK: - Backend factory

enum BackendType: String, CaseIterable, Identifiable {
    case gemini = "Gemini"
    case appleIntelligence = "Apple Intelligence"

    var id: String { rawValue }
    var displayName: String { rawValue }
}

enum BackendFactory {
    static func make(type: BackendType, apiKey: String = "") -> LLMBackend {
        switch type {
        case .gemini:
            return GeminiBackend(apiKey: apiKey)
        case .appleIntelligence:
            return FoundationModelBackendFactory.make()
        }
    }
}

// MARK: - No API Key stub

private final class NoAPIKeyBackend: LLMBackend {
    let displayName = "No backend configured"
    let supportsTools = false
    let isAvailable = false

    func complete(
        systemPrompt: String,
        turns: [ConversationTurn],
        tools: [ToolDefinition]
    ) async throws -> LLMCompletion {
        throw CoachBrainError.noBackend
    }
}

enum CoachBrainError: LocalizedError {
    case noBackend

    var errorDescription: String? {
        "No AI backend configured. Please enter a Gemini API key in Settings."
    }
}
