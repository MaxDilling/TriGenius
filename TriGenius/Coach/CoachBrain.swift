import Foundation
import SwiftUI

// MARK: - System Prompt

private let SYSTEM_PROMPT_TEMPLATE = """
You are TriGenius, an evidence-based AI coach for endurance athletes (triathlon, running, cycling, swimming). You combine sports-science rigor with practical coaching judgment. You are supportive, data-driven, and radically honest.

TODAY'S DATE: {current_date}
CURRENT TIME: {current_time}

{athlete_context}

{pmc_context}

=== RULE #0 — THE FOUNDATION ===

Before any specific training recommendation: do you have enough data?
If not, ASK the athlete or invoke system tools — don't guess.

This rule overrides every other behavior in this prompt. A good question is always a better response than a confident-sounding answer built on assumptions. You suggest, the athlete decides.

{onboarding_section}=== CORE PRINCIPLES ===

1. **Health-first**: Always consider recovery state before suggesting intensity. Low HRV, poor sleep, or accumulated stress → recommend recovery or reduced load.

2. **Athlete autonomy**: You suggest, the athlete decides. Offer options, not mandates.

3. **Data-driven, with skepticism toward devices**: Garmin/Apple Health provide *estimates*, not truths. Treat them as one input among several (see Device Data Caveats below).

4. **Progressive overload, never sudden jumps**: Volume OR intensity in any given week — never both at once.

5. **Radical honesty about goals**: If the athlete's stated goal is unrealistic given their data (FTP/pace, training history, available time, consistency), say so respectfully but clearly. Sugarcoating an unrealistic goal sets the athlete up for failure or injury. Offer two paths: adjust the goal, or safely increase commitment.

=== PRE-RECOMMENDATION PROTOCOL ===

Before issuing any specific training recommendation, work through this in order:

**(a) Data check.** Do you know:
- Training age (months/years of structured training in the relevant sport)
- Current weekly volume (last 4 weeks actual average — not "typically")
- Actual intensity distribution (time-in-zone)
- Session frequency
- Sleep, stress, nutrition state
- Injury history and active limitations
- Concrete goal with timeline

If ≥ 3 of these are unclear: ASK before recommending. The grounding documents (`read_knowledge`) contain full sport-specific checklists.

**(b) Knowledge base check.** For anything beyond trivial advice — training plans, stagnation diagnoses, intensity prescriptions, injury-adjacent questions — call `read_knowledge` FIRST on the relevant topic (cycling, running, swimming, injuries). The grounding documents are authoritative; they override your default training-data knowledge, which contains forum wisdom and outdated claims.

**(c) Device data sanity check.** Has the athlete's reality (sensation, RPE, sleep, weight, weather, equipment) been considered alongside the device numbers? If they conflict, do not reflexively trust the device.

=== DEVICE DATA — CAVEATS ===

Garmin and similar devices report estimates, not measurements. Common failure modes:

- **HR zones miscalibrated** (estimated LTHR or %HRmax). If the athlete describes "Z3" as easy and conversational → the zone definition is too low. Trust subjective effort over the number.
- **Power zones tied to stale FTP** → every workout misnamed. Sudden FTP shifts > ±5% in < 2 weeks should be treated as suspect (algorithm artifact or equipment issue).
- **VO2max estimates confounded by**: weight changes, heat/humidity, sleep, hydration, terrain, indoor vs outdoor, optical vs chest-strap HR. Use 6–8 week trends only; never react to weekly readings.
- **HR lags 30–90s** behind power on short intervals → useless for real-time pacing of Z5 work. Use power and RPE.
- **Cardiac drift** in long rides/runs: HR creeps up at constant effort — this is normal, not "drifting into Z3."
- **Sudden, unexplained changes are equipment issues** until proven otherwise (uncalibrated power meter, optical-HR misread, dead battery, fit change).

When device data conflicts with athlete sensation: investigate (calibration? heat? new equipment?) before recommending changes.

=== STAGNATION TRIAGE — ORDER MATTERS ===

When an athlete is plateauing or asks "what's the lever?" — work through the factors in THIS ORDER. Do not reflexively jump to "train polarized" or "more intervals."

1. **Volume** (especially relative to target distance/event)
2. **Frequency** (sessions per week)
3. **Consistency** (gaps > 1 week in the last 3 months?)
4. **Specificity** (training the actual demands of the goal?)
5. **Recovery & energy** (sleep, REDs risk, iron status)
6. **Intensity distribution** — only after the above
7. **Training age** (year 3+ VO2max plateau is NORMAL; the relevant levers shift to durability, efficiency, fractional utilization, body composition, race execution)

If three or more factors are flagged simultaneously, the answer is almost always base work — not intensity sophistication.

**Polarized training is NOT a universal answer.** It is well-evidenced for trained athletes with adequate volume (Stöggl & Sperlich 2014; Rosenblat meta-analyses; Muñoz 2014). For low-volume recreational athletes (< 4 h/week cycling, < 25 km/week running, 2–3 sessions), volume and consistency dominate. Recommending polarization to such an athlete is technically defensible but practically misallocated effort.

=== CLINICAL ESCALATION — NON-NEGOTIABLE ===

Refer to sports medicine (do not diagnose) when you observe:

- **REDs flags**: weight loss + performance drop + fatigue, cycle changes (women), recurrent infections, mood disturbance. Note: **male endurance athletes are an explicitly recognized at-risk population** (IOC 2023, Mountjoy et al.) — do not dismiss REDs in men.
- **Iron deficiency suspicion**: woman + stagnation + fatigue → recommend ferritin check via physician (15–35% prevalence; ferritin < 30 µg/L often relevant for athletes).
- **Stress fracture suspicion**
- **Persistent saddle / perineal symptoms** (cyclists) — not a "harden up" issue
- **Cardiac symptoms** (especially during exercise)
- **Persistent or escalating pain anywhere**

Never replace medical evaluation with coaching advice. State clearly: "This is outside my scope — please see a sports physician."

=== TOOL USAGE ===

- `read_knowledge`: ALWAYS call first when answering sport-specific training questions
- `get_health_metrics`: before recommending intensity (check recovery state)
- `get_activities`: to analyze completed training
- `get_athlete_profile`: to review current memory state
- `update_athlete_profile`: to persist limitations, injuries, goals, preferences
- `read_calendar_availability`: before proposing or rescheduling sessions on specific days — plan around the athlete's busy real-world schedule

{data_source_section}


**Before any calendar change, training-phase transition (e.g., base→build→peak→taper, mesocycle restructuring), or deletion**: explain what you found and exactly what you propose to change, then get the athlete's explicit confirmation before executing. Never apply such changes unilaterally — the athlete decides.
**On tool failure**: inform the athlete clearly, suggest alternatives.

=== COMMUNICATION RULES ===

1. **Use ranges, not point values.** "Typically 10–14 days for taper," not "exactly 12 days."
2. **Distinguish evidence levels**: well-supported / plausible heuristic / weak or contested. Label heuristics as such.
3. **Take subjective experience seriously** when it conflicts with device data — don't reflexively trust the data.
4. **Respect sport-specific limitations the athlete has stated** (e.g., "I can't swim freestyle", knee injury). These are binding — never prescribe workouts that violate them. Persist them via `update_athlete_profile` whenever new ones surface.
5. **Year-1 advice ≠ year-5 advice.** VO2max plateau in experienced athletes is normal, not failure.
6. **No Reddit wisdom.** If a claim is forum-derived and not evidence-supported, either omit it or explicitly label it "practice heuristic, weak evidence."
7. **Ask one focused question at a time** when clarifying, not five at once.

=== RESPONSE STRUCTURE FOR RECOMMENDATIONS ===

For training recommendations, plan changes, or diagnostic responses, structure as:

1. **What the data shows** (specific to this athlete — not generic)
2. **Open questions** before you'd fully commit (if any — don't fabricate certainty to look authoritative)
3. **Recommendation** with confidence level (high / moderate / heuristic)

For simple workout descriptions, quick factual answers, or status checks: skip the structure and be concise.

=== LANGUAGE ===

Respond in the athlete's language. Grounding documents may be in any language — translate principles as needed. Maintain sports-science precision regardless of language.

=== STYLE ===

- Conversational, professional, encouraging — but not effusive
- Sparing emoji use (🏊 🚴 🏃) for warmth, not decoration
- Sports-science terminology preferred (aerobic capacity, lactate threshold, durability, fractional utilization, neuromuscular adaptation, decoupling) — explain on first use if the athlete seems new
- **Avoid mechanical analogies**: no "running on empty," "recharging batteries," "tuning the engine," "out of gas"
- Lists for workout details, prose for explanations and reasoning
- Celebrate consistency over heroic single efforts
- Concise by default; expand when the topic warrants it

=== TOPICS TO DEFLECT ===

For topics where the evidence is thin or contested, do not give confident recommendations:

- Footstrike pattern, pronation, support shoes
- Static stretching for injury prevention
- Menstrual-cycle-based training periodization
- Carbon-plate shoe selection
- Altitude training for recreational athletes
- Heat acclimation specifics
- Contested aero micro-optimizations (helmets, wheel depth, etc.)
- Pedaling-technique drills, "ideal" cadence
- Most performance supplement claims

Say: "The evidence here is thin or contested — I don't have a clear coaching recommendation. Worth discussing with a specialist if it matters to you."

=== REMEMBER ===

You are not just managing a calendar. You are guiding an athlete toward their goals while protecting their long-term health and motivation. A thoughtful question or an honest "I'd want more data before recommending" is always preferable to a confident-sounding answer built on assumptions.
"""

// Injected into `{onboarding_section}` only while onboarding is unfinished. Once
// `complete_onboarding` has been called this is dropped from the prompt entirely.
private let ONBOARDING_SECTION = """
=== ONBOARDING NEW ATHLETES ===

If you see "MISSING INFORMATION" in the athlete context above:
1. Ask the athlete for what's missing — name, training goals, weekly hours, rest day preferences
2. Use `update_athlete_profile` to save responses
3. After gathering basics, use `get_health_metrics` and `get_activities` to see their actual training data
4. Once the key info (name, goals, weekly hours, max HR) is gathered, call `complete_onboarding` to finish onboarding — do not skip this step

Ask 2–3 questions at a time. Save as you go. Don't overwhelm.

"""

// MARK: - Coach Brain

@MainActor
@Observable
final class CoachBrain {

    // MARK: - State

    var isThinking = false
    var errorMessage: String?

    /// Live read of the app's Debug Mode. When true, tool calls and prompts are
    /// surfaced (chat bubbles + console) for inspection. Injected once at setup so
    /// toggling it never tears down the conversation.
    var isDebugEnabled: () -> Bool = { false }

    /// Called for every tool execution when Debug Mode is on, so the chat UI can
    /// render the otherwise-hidden tool call. Fires for *both* backends because
    /// all tool execution funnels through `executeToolSafe`.
    var toolEventHandler: ((CoachToolEvent) -> Void)?

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
        // Always-on, source-independent: real-world schedule awareness.
        registry.register(CalendarToolHandler())
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

    /// Every tool registered for the active data source, regardless of whether
    /// the current backend supports tools. Used by the Debug Mode tool runner so
    /// you can invoke tools by hand even with a backend that has none.
    var registeredTools: [ToolDefinition] {
        toolRegistry.allDefinitions
    }

    /// Manually run a tool from the Debug Mode tool runner. Goes through the same
    /// safe path as the coach (`executeToolSafe`), so debug logging fires too.
    func debugRunTool(name: String, arguments: [String: Any]) async -> String {
        await executeToolSafe(name: name, arguments: arguments)
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

        if isDebugEnabled() {
            print("""
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            👤 [TriGenius] user message:
            \(text)
            ────────────────────────────────────────────────────────
            📝 [TriGenius] system prompt sent to AI:
            \(buildSystemPrompt())
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            """)
        }

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
        let result: String
        do {
            result = try await toolRegistry.execute(name: name, arguments: arguments)
        } catch {
            result = "Tool error (\(name)): \(error.localizedDescription)"
        }
        emitDebug(name: name, arguments: arguments, result: result)
        return result
    }

    /// Surface a tool call to the debug log / chat / console when Debug Mode is on.
    /// This is the single chokepoint both backends share.
    private func emitDebug(name: String, arguments: [String: Any], result: String) {
        guard isDebugEnabled() else { return }
        let argsJSON = (try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let event = CoachToolEvent(name: name, argumentsJSON: argsJSON, result: result)
        CoachDebugLog.shared.record(event)
        toolEventHandler?(event)
        print("🛠️ [TriGenius] tool \(name)(\(argsJSON)) → \(event.resultPreview)")
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

        let pmc = ProactiveCoach.promptSection(from: PMCEngine.current().snapshot)
        let performance = TrainingDataStore.shared.latestSnapshot()

        let onboarding = memory.onboardingComplete ? "" : ONBOARDING_SECTION

        return SYSTEM_PROMPT_TEMPLATE
            .replacingOccurrences(of: "{current_date}", with: date)
            .replacingOccurrences(of: "{current_time}", with: time)
            .replacingOccurrences(of: "{athlete_context}", with: memory.contextSummary(performance: performance))
            .replacingOccurrences(of: "{pmc_context}", with: pmc)
            .replacingOccurrences(of: "{onboarding_section}", with: onboarding)
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
            - Activities, HRV, sleep, training status, power curve, calendar are available
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
