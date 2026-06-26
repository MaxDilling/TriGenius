import Foundation

// MARK: - Dashboard Insight (AI-generated)
//
// FEATURES.md "AI-generated dashboard insight": the one-liner under the weekly
// rings. Replaces the trivial heuristic with a short, LLM-generated insight that
// weaves together PMC state, weekly balance and the plan — one athlete-facing
// sentence, in the athlete's language.
//
// Cached per day (keyed by an input signature) so the dashboard doesn't make a
// model call on every render, and falls back gracefully to the caller-supplied
// heuristic when no backend is configured / available or the call fails.

@MainActor
enum DashboardInsight {

    private static let textKey = "trigenius.dashboardInsight.text"
    private static let dayKey  = "trigenius.dashboardInsight.day"
    private static let sigKey  = "trigenius.dashboardInsight.signature"

    /// The system prompt for the dashboard one-liner. Exposed (not private) so the
    /// Debug Mode viewer in Settings can show it, like the coach's system prompt.
    static let systemPrompt = """
    You are an evidence-based triathlon coach writing the single insight line on \
    the athlete's dashboard. You get a PRE-CLASSIFIED snapshot. Targets reset every \
    Monday, so early in the week the current week is nearly empty — use the \
    week_stage label and last week's completed numbers, never judge "behind" from a \
    fresh week.

    Write ONE short, specific sentence (max ~28 words) in English. No greeting, no \
    preamble, no quotes, no hashtags.

    Voice: talk like a real coach who knows this athlete — warm, direct, a little \
    motivating. Lead with what's going well, then name the one thing that matters. \
    Say "you" and "we". Never sound like a status report.

    Your job: say the ONE thing the athlete cannot see at a glance. The dashboard \
    already shows the raw numbers and today's workout — never repeat them. Add \
    synthesis: connect a trend to the race, a pace-gap to the remaining plan, or \
    flag a real risk.

    Pick the FIRST case that applies:
    1. fatigue_flag = high (or fitness falling): name it briefly, nudge toward easy.
    2. week_stage = start: the current week just began — do NOT call anything \
    "behind". Reflect on how last week went and frame the week ahead toward the \
    named race.
    3. week_stage = mid/late, a discipline pace = behind AND gap_after_plan ≠ none: \
    open with what looks good, name the gap, offer an action link to fix it.
    4. week_stage = mid/late, a discipline pace = behind BUT gap_after_plan = none: \
    reassure — the planned sessions already close it, just execute. NEVER tell \
    them to "prioritize" or "do more" of something already scheduled.
    5. A positive trend (vo2max rising, fitness on plan): reinforce it, tie it to the \
    named race if it's close.
    6. Nothing stands out: one honest, upbeat "strong, balanced week" line pointing \
    at the goal race. Do not manufacture a problem.

    Trust the labels. Negative Form while building is normal and desirable — never \
    call it overreaching or a recovery concern unless fatigue_flag = high.

    ACTION LINK (only case 3): end with at most one link, format \
    (Label)[message to send]. Example: (Plan a bike session)[Plan me an easy Z2 ride for the weekend]

    GOOD examples:
    - (start) "Last week you nailed all three sports and fitness keeps ticking up — let's carry that momentum into a strong week toward Wörthsee."
    - (start) "Big bike week behind you and form is fresh; this week's the one to get the run volume back on track for Wörthsee."
    - (mid/late, gap) "Swim and run are dialed in; bike's fallen behind pace with nothing left on the calendar. (Plan a ride)[Plan me an easy Z2 ride for the weekend]"
    - (mid/late, covered) "Run's a touch behind pace, but today's strides and Sunday's long run already cover it — just execute and you're set."
    - (trend) "VO2max nudged up to 53 and form is peaking right on plan — 30 days out from Wörthsee, you're in a great spot."
    - (steady) "Strong, balanced week across all three sports — we're right on course for Wörthsee Triathlon."

    AVOID:
    - "Prioritize your run this week." (ignores a run is already planned)
    - "Run is behind." said on Monday (the week just reset — nothing is behind yet)
    - "CTL 47, ATL 58, TSB -19 — productive build." (reads the dashboard back)
    """

    // MARK: - Action link

    /// The optional tappable action the coach can append to the insight (case 3 in
    /// the prompt): a short label plus the chat message it should hand off.
    struct Action: Equatable {
        let label: String
        let message: String
    }

    /// An insight split into its display text and an optional trailing action link.
    struct Parsed: Equatable {
        let text: String
        let action: Action?
    }

    /// Matches the `(Label)[message]` action-link syntax — a parenthesised label
    /// immediately followed by a bracketed message, neither containing its own
    /// brackets. The prompt emits at most one, at the end.
    private static let actionLinkRegex = try? NSRegularExpression(
        pattern: #"\(([^()\[\]]+)\)\[([^\[\]]+)\]"#)

    /// Split a raw insight string into its sentence and an optional action link,
    /// stripping the link markup from the visible text. Falls back to the whole
    /// string as plain text when no well-formed link is present.
    static func parse(_ raw: String) -> Parsed {
        let full = raw as NSString
        guard let regex = actionLinkRegex,
              let match = regex.matches(in: raw, range: NSRange(location: 0, length: full.length)).last,
              match.numberOfRanges == 3 else {
            return Parsed(text: raw.trimmingCharacters(in: .whitespacesAndNewlines), action: nil)
        }
        let label = full.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        let message = full.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
        let text = full.replacingCharacters(in: match.range, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, !message.isEmpty else {
            return Parsed(text: raw.trimmingCharacters(in: .whitespacesAndNewlines), action: nil)
        }
        return Parsed(text: text, action: Action(label: label, message: message))
    }

    /// Today's `yyyy-MM-dd` in POSIX form (cache bucket).
    private static var todayKey: String {
        DateFormatter.ymd.string(from: Date())
    }

    /// Cached insight for today iff the inputs (`signature`) are unchanged.
    static func cached(signature: Int) -> String? {
        let d = UserDefaults.standard
        guard d.string(forKey: dayKey) == todayKey,
              d.integer(forKey: sigKey) == signature,
              let text = d.string(forKey: textKey), !text.isEmpty else { return nil }
        return text
    }

    private static func store(_ text: String, signature: Int) {
        let d = UserDefaults.standard
        d.set(text, forKey: textKey)
        d.set(todayKey, forKey: dayKey)
        d.set(signature, forKey: sigKey)
    }

    /// Return the cached insight, or generate a fresh one from `summary`. Falls
    /// back to `fallback` when the backend is unavailable or the call fails.
    static func generate(
        summary: String,
        signature: Int,
        fallback: String,
        makeBackend: () -> LLMBackend
    ) async -> String {
        if let cached = cached(signature: signature) { return cached }

        let backend = makeBackend()
        guard backend.isAvailable else { return fallback }

        do {
            let raw = try await backend.respond(userMessage: summary, systemPrompt: systemPrompt, tools: [])
            let cleaned = clean(raw)
            guard !cleaned.isEmpty else { return fallback }
            store(cleaned, signature: signature)
            return cleaned
        } catch {
            return fallback
        }
    }

    /// Normalise model output into a single tidy sentence for the UI.
    private static func clean(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Collapse any newlines the model added into spaces.
        s = s.replacingOccurrences(of: "\n", with: " ")
        // Strip a single layer of surrounding quotes.
        if s.count >= 2, let f = s.first, let l = s.last,
           (f == "\"" && l == "\"") || (f == "'" && l == "'") {
            s = String(s.dropFirst().dropLast())
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
