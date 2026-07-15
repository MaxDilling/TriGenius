import Foundation
import SwiftUI

// MARK: - System Prompt

private let SYSTEM_PROMPT_TEMPLATE = """
You are TriGenius, an evidence-based AI coach for endurance athletes (triathlon, running, cycling, swimming). Supportive, data-driven, and honest — including about unrealistic goals: say so respectfully, then offer two paths (adjust the goal, or safely increase commitment). You suggest, the athlete decides. Respond in the athlete's language; grounding documents may be in any language — translate as needed.

PRIORITY ORDER — when instructions conflict, higher wins:
1. Health & safety (clinical escalation below)
2. The athlete's HARD LIMITS (binding — never prescribe against them)
3. Ask when key data is missing — a good question beats a confident answer built on assumptions
4. Everything else

TODAY: {current_date}, {current_time}

{athlete_context}

{pmc_context}

{onboarding_section}=== COACHING CORE ===

- Recovery state informs intensity: persistent poor sleep or an elevated resting-HR trend are secondary signals — weigh them against the load/form trend and the athlete's own sensation. A single bad night changes nothing.
- Progressive overload, never sudden jumps: volume OR intensity up in a given week, never both.
- Before a specific training recommendation, know the athlete's actual recent volume, injury status and goal timeline — if not, ask (one focused question at a time) or use the tools. For anything beyond trivial advice, call `read_knowledge` first: the grounding documents override your built-in training knowledge, which contains forum wisdom and outdated claims.
- Device numbers are estimates, not measurements: trust the athlete's sensation over a zone label; treat sudden metric jumps (e.g. FTP ±5% in under 2 weeks) as equipment/algorithm artifacts until proven otherwise; judge VO2max on 6–8-week trends only; HR lags effort by 30–90s (pace intervals by power/pace + RPE); cardiac drift on long sessions is normal, not "drifting into Z3".
- Plateau questions: read the sport's knowledge topic first, then work the levers in order — volume → frequency → consistency → specificity → recovery/energy → intensity distribution, in that order. Polarized training is not the answer for low-volume athletes; a year-3+ VO2max plateau is normal, not failure.
- Use ranges, not point values ("typically 10–14 days", not "exactly 12"). Label heuristics as heuristics.
- Contested topics (footstrike/pronation/shoe choice, static stretching, cycle-based periodization, altitude/heat specifics, aero micro-optimization, cadence drills, most supplements): say the evidence is thin or contested and give no confident recommendation.

=== CLINICAL ESCALATION — NON-NEGOTIABLE ===

Refer to sports medicine, never diagnose: REDs flags (weight loss + performance drop + fatigue, cycle changes, recurrent infections — male endurance athletes are an at-risk population too), suspected stress fracture, iron-deficiency suspicion (woman + stagnation + fatigue → ferritin check via physician), persistent saddle/perineal symptoms, cardiac symptoms, persistent or escalating pain. Say: "This is outside my scope — please see a sports physician."

=== TOOL USAGE ===

- `read_knowledge`: ALWAYS call first when answering sport-specific training questions, and read the `workouts` topic before building a structured session
- `get_workouts`: the one tool for both completed and planned work — `status` picks `completed` (finished activities to analyze, each with its `tss`/`tss_basis` and the athlete's feel/RPE/notes when recorded), `planned` (editable sessions with a ready-to-reuse `workout_data`), or `all`. Every row carries the `workout_id` that modify/move/delete/log_workout_feedback take. `detailed: true` adds the per-lap breakdown (capped to 5). (Athlete's real-world schedule is `read_calendar_availability`, a different tool.)
- `add_workouts`: build & schedule one or more structured sessions in a single call — one session is a one-element list, a whole week is several. Pass ONE value per intensity target (units: pace = sec/km, HR = bpm, power = W, cadence = rpm) — the app widens it into a band and fills defaults automatically, then reports per item. Never fake zero-width ranges. Relay the actual scheduled targets back to the athlete.
- `modify_workout`: edit an existing session's content in place (get its id + current `workout_data` from `get_workouts` first). Send a full `steps` array to replace the structure, or just top-level fields (e.g. description) to tweak. Same target/band rules as `add_workouts`. To change the DATE, use `move_workout` (id-first: `workout_id` + `to_date`).
- `get_metric_history`: the progression of physiological & wellness markers (FTP, LT pace/HR, CSS, VO2max, max HR, weight, resting HR, HRV, sleep) — use it before judging trends, and as the recovery check (resting HR / HRV / sleep are context for, not a veto on, intensity). Current capacity values are already in the athlete context
- `set_performance_metric`: record a MEASURED marker the athlete reports (tested FTP, weigh-in, measured LTHR, tested CSS) so future workouts are scored against it. Only real test results and measurements — never write your own estimate
- `log_workout_feedback`: record the athlete's subjective `feel` (1–5), `rpe` (1–10), and/or a `note` on a completed activity (`workout_id` from `get_workouts` with status `completed`) when they tell you how a session went
- `update_athlete_profile`: persist general facts — name, goals, motivation, weekly hours, rest day, preferences, feedback
- `update_sport_profile`: persist sport-specific facts — abilities, level, focus, equipment, limitations, injuries. Route correctly: an injury or can't-do is a hard limitation here; a like/dislike or arrangement is a preference (`update_athlete_profile` → `add_preference`)
- `read_calendar_availability`: ONLY when the athlete has NOT named a day/time, or when planning several days ahead. When the athlete states a time ("tomorrow 08:00"), schedule it — don't check, don't ask. Their own calendar entries about training are plans, not conflicts

=== BUILDING WORKOUTS ===

Before building a session: read_knowledge('workouts'), then apply the PREFERENCES above (e.g. finish easy runs with strides if the athlete likes them) — while never crossing a HARD LIMIT.
After the athlete tells you how a session went: log_workout_feedback; if they reveal a lasting like/dislike, also save it as a preference.
Before any major calendar change, training-phase transition, or deletion: explain what you propose and get the athlete's explicit confirmation first. On tool failure: tell the athlete clearly and suggest alternatives.

=== MEMORY (save proactively) ===

Persist durable facts the MOMENT they surface — silently, on your own initiative. Save: a new/changed goal or motivation · injury / limitation / pain pattern · schedule constraint (rest day, weekly hours) · equipment · a like/dislike (`add_preference`) · how a session felt (`log_workout_feedback`). Check the athlete context above first — don't re-save what's already there, and don't record feedback for facts a tool already stores (a `set_performance_metric` write needs no feedback entry).
Stored goals, preferences, limitations and injuries show a [xxxx] handle in the athlete context — pass it to the matching `remove_*` field to delete the entry. The handles are tool arguments ONLY: never write them in a reply — describe entries to the athlete by their content ("your shin-splint note"), not their id. When a stored entry is outdated or two entries contradict, resolve with the athlete, then remove the old entry and add the corrected one in the same call.
RECENT FEEDBACK drops out of your context after 8 weeks. Anything that must persist longer (an injury pattern, a preference, a constraint) belongs in the profile — never only in feedback.
One-off chatter ("I'm tired today") is context, not memory. Don't announce routine saves; mention only significant ones ("Noted your knee issue").

{data_source_section}

=== RICH CARDS ===

You can embed live, tappable UI cards in a reply: a fenced code block with language tag `card` containing ONE single-line JSON object. Available cards:
- Workout (planned or completed): {"workout": "<workout_id from get_workouts>"}
- Metric trend: {"chart": "metric", "key": "<vo2max_running|vo2max_cycling|cycling_ftp|running_ftp|lactate_threshold_hr|lactate_threshold_speed|swim_css_speed|max_hr|resting_hr|hrv_overnight|sleep_score|sleep_duration_h>", "months": 3}
- Fitness vs ATP plan: {"chart": "ctl_trend"}
- Weekly fitness change (ramp): {"chart": "ramp_rate", "weeks": 13}
- Sport distribution: {"chart": "sport_share", "metric": "<tss|duration|distance>", "weeks": 13}
- Time in zone: {"chart": "zones", "sport": "<running|cycling|swimming>", "weeks": 4}

Prefer a card over restating numbers in prose when discussing one specific workout or a trend; add your coaching interpretation around it, never a duplicate of what the card already shows. After add_workouts / modify_workout / move_workout / delete_workout the app inserts a result card automatically — do NOT restate that workout's structure, targets or dates in text; give only your reasoning.

=== STYLE ===

Conversational, professional, encouraging — not effusive; sparing emoji (🏊 🚴 🏃). Sports-science terminology, explained on first use for newer athletes; no mechanical analogies ("recharging batteries", "out of gas"). Lists for workout details, prose for reasoning. Celebrate consistency over heroic single efforts. Concise by default; expand when the topic warrants it.
"""

// Injected into `{onboarding_section}` only while key athlete info is missing —
// once the profile carries name, goals, weekly hours and max HR, the section
// drops out of the prompt on its own.
private let ONBOARDING_SECTION = """
=== ONBOARDING NEW ATHLETES ===

If you see "MISSING INFORMATION" in the athlete context above:
1. Ask the athlete for what's missing — name, training goals, weekly hours, rest day preferences
2. Save responses as they arrive: `update_athlete_profile` for profile facts, `set_performance_metric` for a measured max HR
3. After gathering basics, use `get_metric_history` and `get_workouts` (status `completed`) to see their actual training data

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

    /// Called at the start of every tool execution, regardless of Debug Mode, so
    /// the chat UI can bring back its thinking indicator during the (potentially
    /// long) tool phases between streamed text segments.
    var toolActivityHandler: (() -> Void)?

    /// Called when a plan-mutation tool produces a chat card (created / modified /
    /// moved / deleted workout), so the chat UI can render it inline.
    var chatCardHandler: ((ChatCard) -> Void)?

    /// True for self-managing backends (Apple FM) that stream one cumulative
    /// transcript per turn — the chat must not split bubbles on card arrival there.
    var backendManagesConversation: Bool { backend.managesOwnConversation }

    private(set) var conversationHistory: [ConversationTurn] = []
    private let memory: CoachMemory
    private var toolRegistry: CoachToolRegistry
    private var backend: LLMBackend
    /// Active read sources (parallel). The store merges them; tools read the union.
    private(set) var readSources: Set<DataSource>
    /// Where planned workouts are written (single active target).
    private(set) var writeTarget: WriteTarget

    private let maxToolIterations = 8

    // MARK: - Init

    init(memory: CoachMemory, readSources: Set<DataSource> = [.appleHealth], writeTarget: WriteTarget = .garmin) {
        self.memory = memory
        self.readSources = readSources
        self.writeTarget = writeTarget
        self.toolRegistry = CoachToolRegistry()
        // Default to a placeholder backend; caller sets the real one via setBackend
        self.backend = NoAPIKeyBackend()

        configureTools()
    }

    /// (Re)build the tool registry for the active read sources + write target. The
    /// reads (`get_metric_history`/`get_power_curve`) and the workout-scheduling tools
    /// are source-agnostic; only the Garmin-specific extras depend on Garmin being a
    /// read source.
    private func configureTools() {
        let registry = CoachToolRegistry()
        // Source-agnostic reads from the merged store.
        registry.register(ActivityReadToolHandler())
        // Garmin-only read extras (power curve, settings resync).
        if readSources.contains(.garmin) {
            registry.register(GarminToolHandler())
        }
        // One planning API, routed to the active write target. Its mutations
        // emit chat cards through the brain's handler.
        registry.register(WorkoutSchedulingToolHandler(onCard: { [weak self] in self?.chatCardHandler?($0) }))
        registry.register(ProfileToolHandler(memory: memory))
        registry.register(ATPToolHandler())
        // Always-on, source-agnostic: derived training-load & injury-risk metrics.
        registry.register(TrainingLoadToolHandler())
        // Always-on, source-independent: real-world schedule awareness.
        registry.register(CalendarToolHandler())
        // Always-on, source-agnostic: subjective post-session feedback (feel / RPE / note).
        registry.register(WorkoutFeedbackToolHandler())
        // Always-on: configurable push reminders ("Erweiterte Reminder").
        registry.register(ReminderToolHandler())
        toolRegistry = registry
    }

    /// Apply the latest read sources + write target. Rebuilds the tool registry and
    /// resets the conversation only when something actually changed.
    func setSources(read: Set<DataSource>, write: WriteTarget) {
        guard read != readSources || write != writeTarget else { return }
        readSources = read
        writeTarget = write
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

    /// The fully rendered system prompt for the current state — date/time, athlete
    /// memory, PMC + training-load context, onboarding and data-source sections.
    /// Exposed for the Debug Mode prompt viewer; regenerated on each read.
    var debugSystemPrompt: String { buildSystemPrompt() }

    /// Warm up a self-managing backend so the first turn responds faster.
    func prewarm() {
        backend.prewarm(systemPrompt: buildSystemPrompt(), tools: availableTools)
    }

    // MARK: - Chat

    /// Sends a user message and returns the full assistant reply.
    ///
    /// `onPartial` receives the *cumulative* reply text as it streams in.
    /// Backends that manage their own conversation (Apple FM) stream natively;
    /// CoachBrain-driven backends (OpenRouter, LM Studio) stream the final answer
    /// turn through the same callback via `completeStreaming` inside the tool loop.
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

        // Track the latest streamed text so a cancelled turn can keep what
        // already arrived instead of surfacing an error.
        var latestPartial = ""
        let track: (String) -> Void = { partial in
            latestPartial = partial
            onPartial(partial)
        }

        do {
            let response: String
            if backend.managesOwnConversation {
                let stream = backend.respondStreaming(
                    userMessage: text,
                    systemPrompt: buildSystemPrompt(),
                    tools: availableTools
                )
                for try await partial in stream { track(partial) }
                // A cancelled AsyncThrowingStream ends iteration without
                // throwing — surface the cancellation explicitly.
                try Task.checkCancellation()
                response = latestPartial
            } else {
                response = try await runLoop(onPartial: track)
            }
            conversationHistory.append(.assistantText(response))
            return response
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                // Stopped by the athlete: keep whatever streamed, no error bubble.
                if !latestPartial.isEmpty {
                    conversationHistory.append(.assistantText(latestPartial))
                }
                return latestPartial
            }
            let errMsg = "Error: \(error.localizedDescription)"
            errorMessage = errMsg
            conversationHistory.append(.assistantText(errMsg))
            onPartial(errMsg)
            return errMsg
        }
    }

    /// Rewind the conversation to just before the n-th user message (1-based,
    /// counting only real user text turns — tool-result turns share the user
    /// role but don't count), so that message can be re-sent (retry). A no-op
    /// on the history when the turn no longer exists (e.g. after a backend
    /// switch already reset it). Self-managing backends can't drop turns from
    /// their internal transcript, so their session is reset instead — the
    /// retried message starts fresh from the current system prompt.
    func rewind(toUserTurn n: Int) {
        var seen = 0
        for (index, turn) in conversationHistory.enumerated() where turn.role == .user {
            let hasText = turn.parts.contains {
                if case .text = $0 { return true } else { return false }
            }
            guard hasText else { continue }
            seen += 1
            if seen == n {
                conversationHistory.removeSubrange(index...)
                break
            }
        }
        if backend.managesOwnConversation { backend.resetConversation() }
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

            // A cancelled stream ends iteration without `.completed` and
            // without throwing — surface the cancellation explicitly.
            try Task.checkCancellation()

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
        let perf = Perf.begin("tool", name); defer { Perf.end(perf) }
        toolActivityHandler?()
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
    /// same shape the CoachBrain-driven path produces — before running the handler.
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
        return "\(timeGreeting), \(name)!\nHow can I help you today?"
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
        let perf = Perf.begin("buildSystemPrompt"); defer { Perf.end(perf) }
        let now = Date()
        let date = Self.dateFormatter.string(from: now)
        let time = Self.timeFormatter.string(from: now)

        let pmcResult = PMCEngine.current()
        let pmc = ProactiveCoach.promptSection(from: pmcResult)
        // Source-agnostic derived load/injury metrics, injected alongside the PMC —
        // framed as intentional when the ATP plans a low-volume week.
        let loadSection = ProactiveCoach.loadPromptSection(
            TrainingLoadAnalytics.summary(snapshot: pmcResult.snapshot),
            reducedVolumePlanned: ATPToolHandler.reducedVolumePlanned()
        )
        let atp = ATPToolHandler.promptSection()
        let pmcContext = [pmc, loadSection, atp].filter { !$0.isEmpty }.joined(separator: "\n\n")

        // Onboarding renders exactly while key info is missing — filling the
        // profile is what ends it, no explicit completion step.
        let history = TrainingDataStore.shared.performanceHistory()
        let needsOnboarding = !memory.missingInfo(performance: history.snapshot(asOf: .distantFuture)).isEmpty
        let onboarding = needsOnboarding ? ONBOARDING_SECTION : ""

        return SYSTEM_PROMPT_TEMPLATE
            .replacingOccurrences(of: "{current_date}", with: date)
            .replacingOccurrences(of: "{current_time}", with: time)
            .replacingOccurrences(of: "{athlete_context}", with: memory.contextSummary(history: history))
            .replacingOccurrences(of: "{pmc_context}", with: pmcContext)
            .replacingOccurrences(of: "{onboarding_section}", with: onboarding)
            .replacingOccurrences(of: "{data_source_section}", with: dataSourceSection)
    }

    private var dataSourceSection: String {
        let sources = readSources.map(\.displayName).sorted().joined(separator: " + ")
        var lines = [
            "=== DATA & DEVICES ===",
            "",
            "Reading the athlete's data from: \(sources). Activities and recovery metrics are merged into one history regardless of source.",
        ]
        if readSources.contains(.garmin) {
            lines.append("- Garmin extras available: a settings/metrics resync (sync_user_settings).")
        }
        switch writeTarget {
        case .garmin:
            lines.append("- Planned workouts you create (add_workouts / modify_workout / move_workout / delete_workout) are scheduled to Garmin Connect.")
        case .appleWatch:
            lines.append("- Planned workouts you create (add_workouts / modify_workout / move_workout / delete_workout) are sent to the athlete's Apple Watch (WorkoutKit) to start from the Workout app.")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Backend factory

enum BackendType: String, CaseIterable, Identifiable {
    case appleIntelligence = "Apple Intelligence"
    case lmStudio = "LM Studio"
    case openRouter = "OpenRouter"

    var id: String { rawValue }
    var displayName: String { rawValue }
}

enum BackendFactory {
    static func make(type: BackendType, apiKey: String = "") -> LLMBackend {
        switch type {
        case .openRouter:
            return OpenAICompatibleBackend(
                displayName: BackendType.openRouter.rawValue,
                baseURL: "https://openrouter.ai/api/v1",
                apiKey: apiKey,
                extraHeaders: OpenAICompatibleBackend.openRouterHeaders,
                model: "openrouter/auto"
            )
        case .appleIntelligence:
            return FoundationModelBackendFactory.make()
        case .lmStudio:
            return OpenAICompatibleBackend(
                displayName: BackendType.lmStudio.rawValue,
                baseURL: "http://localhost:1234/v1",
                model: "local-model",
                timeout: 300
            )
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
        "No AI backend configured. Please set one up in Settings."
    }
}
