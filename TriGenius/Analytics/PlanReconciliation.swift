import Foundation

// MARK: - Plan ↔ Activity Reconciliation
//
// Garmin keeps a planned calendar item AND the completed activity as two separate
// things, which TriGenius mirrors into two independent local tables
// (`ScheduledWorkoutRecord` vs `ActivityRecord`). Without reconciliation the same
// session shows twice — once as a pending plan, once as a completed ✓ row.
//
// This collapses that duplication purely on the read/display side (no Garmin
// writes, no DB mutation): a planned workout is "fulfilled" once a matching
// completed activity exists, and fulfilled plans are dropped from the Agenda,
// the calendar grid and the weekly projection.

enum PlanReconciliation {
    /// Planned workouts that have NO matching completed activity. Greedy 1:1:
    /// each completed activity fulfills at most one plan, and each plan is
    /// consumed once — so two planned runs + one completed run leave one plan.
    static func unfulfilled(
        planned: [ScheduledWorkoutRecord],
        completed: [ActivityRecord]
    ) -> [ScheduledWorkoutRecord] {
        let cal = Calendar.current
        var available = completed
        var result: [ScheduledWorkoutRecord] = []
        for p in planned {
            if let idx = available.firstIndex(where: { matches(planned: p, activity: $0, calendar: cal) }) {
                available.remove(at: idx)   // consume this activity 1:1
            } else {
                result.append(p)
            }
        }
        return result
    }

    /// Whether a completed activity fulfills a planned workout: same day, same
    /// sport family, and a tolerant name match (the activity name carries a
    /// location prefix, e.g. "Munich – Lauf (7km) …" fulfills "Lauf (7km) …").
    static func matches(
        planned p: ScheduledWorkoutRecord,
        activity a: ActivityRecord,
        calendar cal: Calendar = .current
    ) -> Bool {
        guard cal.isDate(p.date, inSameDayAs: a.date) else { return false }
        guard SportFamily(sportKey: p.sport) == SportFamily(sportKey: a.sport) else { return false }
        let pn = normalize(p.name)
        let an = normalize(a.name)
        guard !pn.isEmpty, !an.isEmpty else { return false }
        return an.contains(pn) || pn.contains(an)
    }

    /// Lowercased, whitespace-collapsed name for tolerant substring comparison.
    private static func normalize(_ name: String) -> String {
        name.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
