import Foundation

// MARK: - Training Load Analytics
//
// The source-agnostic, injury-relevant *derived* layer on top of the local store.
// Both Garmin and Apple Health feed `TrainingDataStore`, so these metrics read the
// same regardless of data source — the abstraction the coach should reason over.
//
// What it computes, and why (grounded in Assets/Knowledge):
//   - Weekly volume + week-over-week ramp rate per sport (RUNNING.md §4 / Nielsen
//     2014: weekly increases >30% notably raise running injury risk).
//   - Longest single session + its progression vs the prior 30-day longest
//     (RUNNING.md §4: the single long-run spike is "a stronger injury predictor
//     than the weekly average"; ≤10% progression rule).
//   - Long-session share of weekly volume (RUNNING.md §5: run cap 25–35%).
//   - Frequency per sport (SWIMMING.md §7: ≥3×/wk for skill retention).
//   - Acute vs chronic load tracked SEPARATELY + a week-over-week TSS step change —
//     deliberately not a single ACWR ratio (INJURIES.MD / CYCLING.md §5 critique
//     ACWR as a deterministic gate; "track acute and chronic separately, watch for
//     step changes").
//
// Pure and @MainActor; reuses `TrainingVolume`, `PMCEngine`, `SportFamily`, `TSS`.
// Rendering + heuristic flags live in `ProactiveCoach`; the on-demand tool
// (`get_training_load`) serializes the summary.

/// The volume metric a sport's ramp / longest-session / share heuristics key on:
/// distance for the endurance disciplines, duration for strength/other.
private func primaryVolume(_ family: SportFamily, distanceKm: Double, durationMinutes: Double) -> Double {
    switch family {
    case .strength, .other: return durationMinutes
    case .swim, .bike, .run: return distanceKm
    }
}

/// A single session's extent, kept for both display and the progression ratio.
struct LongestSession: Sendable {
    let distanceKm: Double
    let durationMinutes: Double
    let date: Date
    let name: String
}

/// Per-sport derived load/volume metrics over the recent window.
struct SportLoadMetrics: Sendable {
    let family: SportFamily

    /// Current (in-progress) week.
    let currentWeekDistanceKm: Double
    let currentWeekDurationMinutes: Double
    let currentWeekSessions: Int

    /// Mean weekly distance/duration over the trailing 3 completed weeks (ramp baseline).
    let baselineWeeklyDistanceKm: Double
    let baselineWeeklyDurationMinutes: Double

    /// Current-week volume vs the trailing-3-week mean, as a fraction (0.30 = +30%).
    /// Nil when there's no baseline to compare against. Keyed on the sport's primary metric.
    let rampRate: Double?

    /// Longest single session in the last 7 days, and the longest in the 30 days
    /// before that (the progression baseline). Nil when the window has no session.
    let recentLongest: LongestSession?
    let baselineLongest: LongestSession?

    /// recentLongest as a fraction of current-week volume (0.35 = 35%), primary metric.
    let longSessionShare: Double?

    /// Average sessions/week over the trailing completed weeks.
    let avgSessionsPerWeek: Double

    /// recentLongest ÷ baselineLongest on the primary metric (1.10 = +10%). Nil when either is missing.
    var longestProgressionRatio: Double? {
        guard let r = recentLongest, let b = baselineLongest else { return nil }
        let rv = primaryVolume(family, distanceKm: r.distanceKm, durationMinutes: r.durationMinutes)
        let bv = primaryVolume(family, distanceKm: b.distanceKm, durationMinutes: b.durationMinutes)
        guard bv > 0 else { return nil }
        return rv / bv
    }
}

/// Acute vs chronic load — kept as separate numbers plus a week-over-week step
/// change, never collapsed into one ratio.
struct LoadBlock: Sendable {
    let ctl: Double          // Fitness, 42-day EWMA
    let atl: Double          // Fatigue, 7-day EWMA
    let tsb: Double          // Form
    let currentWeekTSS: Double
    let priorWeekTSS: Double
    var weekOverWeekTSSDelta: Double { currentWeekTSS - priorWeekTSS }
}

struct TrainingLoadSummary: Sendable {
    let weeks: Int
    let perSport: [SportLoadMetrics]
    let load: LoadBlock?
    var hasData: Bool { load != nil || perSport.contains { $0.currentWeekSessions > 0 || $0.avgSessionsPerWeek > 0 } }
}

enum TrainingLoadAnalytics {

    /// Compute the full source-agnostic summary from the local store. Pass a
    /// precomputed PMC `snapshot` to avoid recomputing the chart (CoachBrain
    /// already has it for the PMC prompt section).
    @MainActor
    static func summary(
        store: TrainingDataStore? = nil,
        snapshot: PMCSnapshot? = nil,
        today: Date = Date(),
        weeks: Int = 6
    ) -> TrainingLoadSummary {
        let store = store ?? .shared
        let cal = Calendar.current

        // Fetch enough history for both the weekly buckets and the 30-day-before
        // longest-session baseline (37 days back, with a little slack).
        let lookbackDays = max(weeks * 7 + 7, 45)
        let from = cal.date(byAdding: .day, value: -lookbackDays, to: today) ?? today
        let records = store.activities(from: from, to: today)

        let buckets = TrainingVolume.weeklyBuckets(records: records, weeks: weeks, today: today)
        guard let currentBucket = buckets.last else {
            return TrainingLoadSummary(weeks: weeks, perSport: [], load: nil)
        }
        let completed = buckets.dropLast()                       // exclude in-progress week
        let baselineWeeks = Array(completed.suffix(3))           // ramp baseline
        let frequencyWeeks = Array(completed.suffix(4))          // frequency window

        // Longest-session windows: last 7 days vs the 30 days before that.
        let recentStart = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: today)) ?? today
        let baselineStart = cal.date(byAdding: .day, value: -37, to: cal.startOfDay(for: today)) ?? today

        // Which sports to surface: the triathlon disciplines always (a zero week is
        // itself a signal), plus strength when the athlete actually does it.
        var families = SportFamily.triathlon
        let didStrength = records.contains { SportFamily(sportKey: $0.sport) == .strength }
        if didStrength { families.append(.strength) }

        let perSport: [SportLoadMetrics] = families.map { family in
            let current = currentBucket.totals(for: family)

            let baseDistances = baselineWeeks.map { $0.totals(for: family).distanceKm }
            let baseDurations = baselineWeeks.map { $0.totals(for: family).durationMinutes }
            let baselineDistance = baseDistances.isEmpty ? 0 : baseDistances.reduce(0, +) / Double(baseDistances.count)
            let baselineDuration = baseDurations.isEmpty ? 0 : baseDurations.reduce(0, +) / Double(baseDurations.count)

            let curPrimary = primaryVolume(family, distanceKm: current.distanceKm, durationMinutes: current.durationMinutes)
            let basePrimary = primaryVolume(family, distanceKm: baselineDistance, durationMinutes: baselineDuration)
            let ramp: Double? = basePrimary > 0 ? (curPrimary / basePrimary) - 1 : nil

            let recentLongest = longest(in: records, family: family, on: recentStart, before: today)
            let baselineLongest = longest(in: records, family: family, on: baselineStart, before: recentStart)

            var share: Double? = nil
            if let r = recentLongest, curPrimary > 0 {
                share = primaryVolume(family, distanceKm: r.distanceKm, durationMinutes: r.durationMinutes) / curPrimary
            }

            let sessions = frequencyWeeks.map { $0.totals(for: family).sessions }
            let avgSessions = sessions.isEmpty ? 0 : Double(sessions.reduce(0, +)) / Double(sessions.count)

            return SportLoadMetrics(
                family: family,
                currentWeekDistanceKm: current.distanceKm,
                currentWeekDurationMinutes: current.durationMinutes,
                currentWeekSessions: current.sessions,
                baselineWeeklyDistanceKm: baselineDistance,
                baselineWeeklyDurationMinutes: baselineDuration,
                rampRate: ramp,
                recentLongest: recentLongest,
                baselineLongest: baselineLongest,
                longSessionShare: share,
                avgSessionsPerWeek: avgSessions
            )
        }

        // Acute vs chronic + weekly TSS step change.
        let snap = snapshot ?? PMCEngine.current().snapshot
        let load: LoadBlock? = snap.map { s in
            let currentTSS = SportFamily.allCases.reduce(0.0) { $0 + currentBucket.totals(for: $1).tss }
            let priorTSS: Double = completed.last.map { wk in
                SportFamily.allCases.reduce(0.0) { $0 + wk.totals(for: $1).tss }
            } ?? 0
            return LoadBlock(ctl: s.ctl, atl: s.atl, tsb: s.tsb, currentWeekTSS: currentTSS, priorWeekTSS: priorTSS)
        }

        return TrainingLoadSummary(weeks: weeks, perSport: perSport, load: load)
    }

    /// The longest session of `family` with `start <= date < end`, by primary metric.
    private static func longest(in records: [ActivityRecord], family: SportFamily, on start: Date, before end: Date) -> LongestSession? {
        let matching = records.filter {
            SportFamily(sportKey: $0.sport) == family && $0.date >= start && $0.date < end
        }
        return matching.max {
            primaryVolume(family, distanceKm: $0.distanceKm, durationMinutes: $0.durationMinutes)
                < primaryVolume(family, distanceKm: $1.distanceKm, durationMinutes: $1.durationMinutes)
        }.map {
            LongestSession(distanceKm: $0.distanceKm, durationMinutes: $0.durationMinutes, date: $0.date, name: $0.name)
        }
    }
}
