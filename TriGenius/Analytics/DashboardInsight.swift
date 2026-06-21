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

    private static let systemPrompt = """
    You are an evidence-based triathlon coach writing the single insight line on \
    the athlete's dashboard. Given a compact snapshot of their training state, \
    reply with ONE short, encouraging, specific sentence (max ~25 words). \
    No greeting, no preamble, no markdown, no quotes — just the sentence. \
    Respond in the athlete's language (default to English).

    Interpret Form (TSB) with these reference ranges — a negative TSB is normal \
    while building fitness and is NOT "too much training":
    - above +15: very fresh / tapered (race-ready, or detraining if fitness is also low)
    - +5 to +15: fresh
    - -10 to +5: neutral / maintenance
    - -30 to -10: the productive training zone — expected and desirable while building
    - below -30: high fatigue / overreaching — the only range that warrants caution
    """

    /// Today's `yyyy-MM-dd` in POSIX form (cache bucket).
    private static var todayKey: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
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
