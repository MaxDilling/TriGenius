import Foundation

// MARK: - Proactive Coach
//
// Evaluates the athlete's current state (today: PMC / form; later: poor sleep,
// at-risk goals) and produces proactive signals. Deliberately split from the
// chat loop so the SAME evaluation can drive two sinks:
//   (a) a section injected into the coach's system prompt (implemented now), and
//   (b) — later — local push notifications via a background coordinator.
//
// GOAL.md: "Implement Proactive PMC Coach Triggers".

/// A single proactive concern the coach should be aware of / may act on.
struct ProactiveSignal: Sendable {
    enum Severity: Sendable { case info, warning }
    let severity: Severity
    /// One-line, athlete-facing phrasing (reusable as a push notification body).
    let message: String
    /// Deterministic, context-appropriate chat prompt to pre-fill (unsent) when the
    /// athlete taps the notification carrying this signal. nil → no follow-up.
    let followUpPrompt: String?

    init(severity: Severity, message: String, followUpPrompt: String? = nil) {
        self.severity = severity
        self.message = message
        self.followUpPrompt = followUpPrompt
    }
}

enum ProactiveCoach {

    // Heuristic thresholds for TSB (Form). These are coaching rules of thumb,
    // not hard science — labelled as heuristics in the prompt section.
    private static let tsbOvertrainedThreshold = -30.0   // deep fatigue / overreaching
    private static let tsbFreshThreshold = 15.0           // very fresh / detraining-leaning
    private static let ctlDetrainingThreshold = 20.0      // low chronic load

    /// Evaluate the current PMC snapshot into proactive signals.
    static func signals(from snapshot: PMCSnapshot?) -> [ProactiveSignal] {
        guard let s = snapshot else { return [] }
        var out: [ProactiveSignal] = []

        if s.tsb <= tsbOvertrainedThreshold {
            out.append(ProactiveSignal(
                severity: .warning,
                message: "Form (TSB) is very negative (\(rounded(s.tsb))) — accumulated fatigue is high. Overtraining/illness risk; prioritise recovery before adding load.",
                followUpPrompt: "How should I adjust my training this week given my current fatigue?"
            ))
        } else if s.tsb >= tsbFreshThreshold && s.ctl < ctlDetrainingThreshold {
            out.append(ProactiveSignal(
                severity: .warning,
                message: "Form (TSB \(rounded(s.tsb))) is high while fitness (CTL \(rounded(s.ctl))) is low — this points to detraining, not race-readiness. Consistent volume is the lever.",
                followUpPrompt: "Help me build a consistent training plan to raise my fitness."
            ))
        } else if s.tsb >= tsbFreshThreshold {
            out.append(ProactiveSignal(
                severity: .info,
                message: "Form (TSB \(rounded(s.tsb))) is positive — the athlete is fresh and likely well-placed for a key session or race.",
                followUpPrompt: "I'm feeling fresh — what key session should I do?"
            ))
        }

        return out
    }

    // MARK: - Weekly target at risk

    // A discipline is "at risk" when, even counting everything still planned, the
    // week is projected to close meaningfully below its target — e.g. a session
    // was skipped and the remaining days can't make up the volume.
    private static let weeklyAtRiskFraction = 0.85   // projected < 85% of target
    private static let weeklyAtRiskMinGap = 30.0     // and short by ≥ 30 TSS

    /// Flag disciplines whose weekly TSS target is at risk given the projected
    /// close (completed + still-planned). One aggregate warning so the athlete
    /// isn't hit with a signal per discipline.
    static func weeklyTargetSignals(
        targets: [SportFamily: WeeklyTarget],
        projection: [SportFamily: WeeklyProjection]
    ) -> [ProactiveSignal] {
        let atRisk = SportFamily.triathlon.compactMap { family -> (SportFamily, Double)? in
            guard let target = targets[family]?.tss, target > 0 else { return nil }
            let projected = projection[family]?.projectedTSS ?? 0
            let gap = target - projected
            guard projected < target * weeklyAtRiskFraction, gap >= weeklyAtRiskMinGap else { return nil }
            return (family, gap)
        }
        guard !atRisk.isEmpty else { return [] }

        let names = atRisk.map { $0.0.displayName.lowercased() }.joined(separator: ", ")
        let totalGap = Int(atRisk.reduce(0) { $0 + $1.1 }.rounded())
        // Pre-fill a concrete, actionable prompt for the single discipline furthest
        // behind, so the tapped follow-up plans one workout rather than a vague ask.
        let worst = atRisk.max { $0.1 < $1.1 }!.0
        return [ProactiveSignal(
            severity: .warning,
            message: "This week's \(names) target is at risk — even with everything still planned you're projected ~\(totalGap) TSS short. Add or extend a session in the remaining days to stay on track.",
            followUpPrompt: "Plan a \(worst.displayName.lowercased()) workout for me this week to get back on target."
        )]
    }

    /// The system-prompt section describing the current PMC state + any signals.
    /// Returns "" when there is no PMC data yet (keeps the prompt clean). Takes
    /// the full `PMCResult` so the week-over-week trend rides along and the
    /// warm-up caveat renders only while the history is actually short.
    static func promptSection(from result: PMCResult) -> String {
        guard let s = result.snapshot else { return "" }
        var state = "Fitness CTL \(rounded(s.ctl))"
        if let weekAgo = result.value(daysAgo: 7, \.ctl), abs(s.ctl - weekAgo) >= 0.5 {
            state += " (\(signed(s.ctl - weekAgo)) vs a week ago)"
        }
        state += " · Fatigue ATL \(rounded(s.atl)) · Form TSB \(rounded(s.tsb))"
        if let weekAgo = result.value(daysAgo: 7, \.tsb), abs(s.tsb - weekAgo) >= 0.5 {
            state += " (was \(rounded(weekAgo)))"
        }
        var lines = ["=== CURRENT TRAINING LOAD (PMC) ===", state]
        if result.points.count < Int(PMCEngine.ctlTimeConstant) {
            lines.append("Only \(result.points.count) days of training history — CTL hasn't finished its warm-up; treat it as approximate.")
        }
        let sigs = signals(from: s)
        if !sigs.isEmpty {
            lines.append("\nProactive flags to weave in naturally when relevant (don't lecture):")
            for sig in sigs {
                lines.append("- \(sig.severity == .warning ? "⚠️ " : "")\(sig.message)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Training load & injury signals (source-agnostic)

    /// System-prompt section for the source-agnostic derived load metrics
    /// (`TrainingLoadAnalytics`). Mirrors `promptSection(from:)`. Returns "" when
    /// there's no usable data yet, to keep the prompt clean.
    ///
    /// The current week is *in progress*, so everything is framed week-to-date
    /// against absolute baselines — a partial week compared as a percentage
    /// against complete weeks reads as a collapse every Monday–Wednesday.
    /// `reducedVolumePlanned` (ATP recovery/taper/race week) makes the section
    /// say the low numbers are intentional.
    static func loadPromptSection(_ summary: TrainingLoadSummary, reducedVolumePlanned: Bool = false) -> String {
        guard summary.hasData else { return "" }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let dayOfWeek = (cal.dateComponents([.day], from: TrainingVolume.weekStart(of: today), to: today).day ?? 0) + 1
        var lines = [
            "=== TRAINING LOAD (week to date, day \(dayOfWeek) of 7) ===",
            "Heuristics, not hard thresholds. Per sport, this week so far vs the trailing 3-week baseline:"
        ]
        for m in summary.perSport where m.currentWeekSessions > 0 || m.avgSessionsPerWeek > 0 {
            lines.append("- " + sportLine(m))
        }
        if let load = summary.load {
            lines.append("Last week ~\(rounded(load.priorWeekTSS)) TSS; this week ~\(rounded(load.currentWeekTSS)) so far.")
        }
        if reducedVolumePlanned {
            lines.append("The ATP plans reduced volume this week (recovery/taper/race) — low numbers here are intentional, not a training gap.")
        }
        let sigs = loadSignals(summary)
        if !sigs.isEmpty {
            lines.append("\nInjury-load flags to weave in naturally when relevant (don't lecture):")
            for s in sigs { lines.append("- \(s.severity == .warning ? "⚠️ " : "")\(s.message)") }
        }
        return lines.joined(separator: "\n")
    }

    /// Heuristic injury-load flags derived from the per-sport metrics. Thresholds
    /// are coaching rules of thumb anchored to the embedded knowledge base.
    static func loadSignals(_ summary: TrainingLoadSummary) -> [ProactiveSignal] {
        var out: [ProactiveSignal] = []
        for m in summary.perSport {
            switch m.family {
            case .run:
                if let r = m.rampRate, r > 0.30 {
                    out.append(ProactiveSignal(severity: .warning, message: "Run volume is up \(signedPct(r)) on the trailing 3-week average — past ~+30% week-on-week notably raises running injury risk (Nielsen 2014). Hold or ease this week's build.", followUpPrompt: "Review my running load and help me lower injury risk this week."))
                }
                if let p = m.longestProgressionRatio, p > 1.10, let r = m.recentLongest {
                    out.append(ProactiveSignal(severity: .warning, message: "Longest run jumped to \(km(r.distanceKm)) km — >10% over the prior 30-day longest. Single long-run spikes predict injury more than the weekly average; cap long-run growth near 10%.", followUpPrompt: "How should I progress my long run safely from here?"))
                }
                if let share = m.longSessionShare, share > 0.35, shareIsMeaningful(m) {
                    out.append(ProactiveSignal(severity: .warning, message: "The long run is \(pct(share)) of weekly run volume (cap ~25–35%) — spread volume across more sessions to lower per-session impact load.", followUpPrompt: "Help me spread my weekly run volume across more sessions."))
                }
            case .bike:
                if let r = m.rampRate, r > 0.30 {
                    out.append(ProactiveSignal(severity: .info, message: "Bike volume is up \(signedPct(r)) vs the 3-week average — cycling tolerates more than running, but watch fatigue if it keeps climbing.", followUpPrompt: "Is my bike volume ramping too fast? Help me manage the load."))
                }
            case .swim:
                if m.avgSessionsPerWeek > 0, m.avgSessionsPerWeek < 3 {
                    out.append(ProactiveSignal(severity: .info, message: "Swim frequency is ~\(fmt1(m.avgSessionsPerWeek))×/wk — under ~3×/wk slows motor-skill retention for adult-onset swimmers (technique is the primary lever).", followUpPrompt: "Help me fit in more frequent swim sessions this week."))
                }
            default:
                break
            }
        }
        return out
    }

    /// One compact per-sport line for the prompt section. Week-to-date volume is
    /// framed against the absolute 3-week baseline; only an *excess* renders as a
    /// percentage (a partial week is naturally below average — that's not signal).
    private static let minSessionsForShare = 3

    /// The long-session share divides by the *current* week's volume, but the
    /// longest-session window is the last 7 days — it can reach into last week
    /// and produce shares over 100%. Only meaningful when the longest session is
    /// actually part of this week and the week has enough sessions to spread
    /// (one run is always ~100% of volume).
    private static func shareIsMeaningful(_ m: SportLoadMetrics) -> Bool {
        guard m.currentWeekSessions >= minSessionsForShare, let recent = m.recentLongest else { return false }
        return recent.date >= TrainingVolume.weekStart(of: Calendar.current.startOfDay(for: Date()))
    }

    private static func sportLine(_ m: SportLoadMetrics) -> String {
        var parts: [String] = []
        let sessions = "\(m.currentWeekSessions) session\(m.currentWeekSessions == 1 ? "" : "s")"
        switch m.family {
        case .strength, .other:
            parts.append("\(m.family.displayName): \(rounded(m.currentWeekDurationMinutes)) min / \(sessions) so far (3-wk avg \(rounded(m.baselineWeeklyDurationMinutes)) min/wk)")
        default:
            parts.append("\(m.family.displayName): \(km(m.currentWeekDistanceKm)) km / \(sessions) so far (3-wk avg \(km(m.baselineWeeklyDistanceKm)) km/wk)")
        }
        if let r = m.rampRate, r > 0 { parts.append("already \(signedPct(r)) over the weekly avg") }
        if let recent = m.recentLongest {
            var ls = "longest \(longestText(m.family, recent)) (last 7d)"
            if let base = m.baselineLongest { ls += ", prior-30d max \(longestText(m.family, base))" }
            parts.append(ls)
        }
        if let share = m.longSessionShare, shareIsMeaningful(m) {
            parts.append("long-session \(pct(share)) of weekly volume")
        }
        parts.append("~\(fmt1(m.avgSessionsPerWeek))×/wk")
        return parts.joined(separator: "; ")
    }

    /// Longest session rendered in the sport's natural unit (m for swim, km for
    /// bike/run, min for strength).
    private static func longestText(_ family: SportFamily, _ s: LongestSession) -> String {
        switch family {
        case .swim: return "\(rounded(s.distanceKm * 1000)) m"
        case .strength, .other: return "\(rounded(s.durationMinutes)) min"
        case .bike, .run: return "\(km(s.distanceKm)) km"
        }
    }

    private static func km(_ v: Double) -> String { String(format: "%.1f", v) }
    private static func fmt1(_ v: Double) -> String { String(format: "%.1f", v) }
    private static func pct(_ v: Double) -> String { "\(rounded(v * 100))%" }
    private static func signedPct(_ v: Double) -> String { (v >= 0 ? "+" : "") + pct(v) }
    private static func signed(_ v: Double) -> String { (v >= 0 ? "+" : "") + rounded(v) }

    private static func rounded(_ v: Double) -> String {
        String(Int(v.rounded()))
    }
}
