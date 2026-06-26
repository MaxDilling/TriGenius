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
    the athlete's dashboard. You receive a compact, PRE-CLASSIFIED snapshot of \
    their current training state. Reply with ONE short, specific, actionable \
    sentence (max ~25 words) about what actually stands out. No greeting, no \
    preamble, no markdown, no quotes, no hashtags — just the sentence. Respond in \
    the athlete's language (default to English).

    Rules:
    - TRUST the Form label you are given. A negative Form (TSB) while fitness is \
    building is NORMAL and productive — never call it "hard training", \
    "overreaching", or a reason to back off UNLESS the snapshot explicitly says \
    fatigue is high (the label for TSB below -30). Do not invent a recovery concern.
    - Be concrete: name the specific thing that stands out — the discipline \
    furthest from its weekly target, fitness (CTL) that is climbing or fading, or a \
    genuinely flagged risk — not generic praise.
    - Interpret, don't recite: do not just restate the numbers back.
    - One idea only. If nothing notable stands out, say so honestly with a brief \
    "steady, balanced week" line rather than manufacturing a problem.
    """

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
