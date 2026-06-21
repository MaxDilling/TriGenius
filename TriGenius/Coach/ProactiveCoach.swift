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
                message: "Form (TSB) is very negative (\(rounded(s.tsb))) — accumulated fatigue is high. Overtraining/illness risk; prioritise recovery before adding load."
            ))
        } else if s.tsb >= tsbFreshThreshold && s.ctl < ctlDetrainingThreshold {
            out.append(ProactiveSignal(
                severity: .warning,
                message: "Form (TSB \(rounded(s.tsb))) is high while fitness (CTL \(rounded(s.ctl))) is low — this points to detraining, not race-readiness. Consistent volume is the lever."
            ))
        } else if s.tsb >= tsbFreshThreshold {
            out.append(ProactiveSignal(
                severity: .info,
                message: "Form (TSB \(rounded(s.tsb))) is positive — the athlete is fresh and likely well-placed for a key session or race."
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
        return [ProactiveSignal(
            severity: .warning,
            message: "This week's \(names) target is at risk — even with everything still planned you're projected ~\(totalGap) TSS short. Add or extend a session in the remaining days to stay on track."
        )]
    }

    /// The system-prompt section describing the current PMC state + any signals.
    /// Returns "" when there is no PMC data yet (keeps the prompt clean).
    static func promptSection(from snapshot: PMCSnapshot?) -> String {
        guard let s = snapshot else { return "" }
        var lines = [
            "=== CURRENT TRAINING LOAD (PMC) ===",
            "These are locally computed from stored TSS (heuristic; CTL needs >6 weeks of history to be reliable):",
            "- Fitness (CTL, 42-day): \(rounded(s.ctl))",
            "- Fatigue (ATL, 7-day): \(rounded(s.atl))",
            "- Form (TSB = CTL−ATL): \(rounded(s.tsb))"
        ]
        let sigs = signals(from: s)
        if !sigs.isEmpty {
            lines.append("\nProactive flags to weave in naturally when relevant (don't lecture):")
            for sig in sigs {
                lines.append("- \(sig.severity == .warning ? "⚠️ " : "")\(sig.message)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func rounded(_ v: Double) -> String {
        String(Int(v.rounded()))
    }
}
