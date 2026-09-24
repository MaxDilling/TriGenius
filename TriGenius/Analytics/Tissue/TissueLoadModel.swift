import Foundation

// MARK: - Tissue load model
//
// Real sessions → the forecast every Tissue Load surface shows. Pure and computed
// on the fly: the dashboard hands it completed and planned sessions already shaped
// into doses (`TissueSession`), nothing is persisted.
//
// 1. Dose. Each session puts a dose on each group, muscle and tendon apart — an
//    endurance session its TL × the sport's weight for that group, a strength
//    session its hard sets (1 per set on a primary group, ½ on a secondary,
//    × `tlPerHardSet`), tendon only where the exercise loads one. A session without
//    exercises carries no dose: unknown load is not modelled.
// 2. Decay. A tissue's morning state is every earlier dose decayed exponentially —
//    muscle with a 1-day time constant, tendon with 3 days.
// 3. Levels. A morning state is read against the athlete's own average for that
//    group and tissue over the last 28 days: under ½ Fresh, under 1× Light (clear
//    for hard work), under 1½ Moderate, under 2× Loaded, else Heavy. The state after
//    a day's sessions — what the cells draw — against the average after-training
//    state the same way.
// 4. Conflicts. A planned session conflicts when it would push a group it loads
//    above that group's highest post-session state of the last 30 days + 10 % —
//    the single-session spike rule. Withheld until 4 weeks of history exist.
// 5. Chronic. Each of the last 6 full weeks' muscle dose against the athlete's own
//    6-week average for the group.
//
// Every constant lives in `TissueConstants`.

nonisolated struct TissueDose: Codable, Hashable, Sendable {
    var muscle = 0.0
    var tendon = 0.0

    var total: Double { muscle + tendon }

    static func + (a: TissueDose, b: TissueDose) -> TissueDose {
        TissueDose(muscle: a.muscle + b.muscle, tendon: a.tendon + b.tendon)
    }

    static func += (a: inout TissueDose, b: TissueDose) { a = a + b }

    static func * (a: TissueDose, factor: Double) -> TissueDose {
        TissueDose(muscle: a.muscle * factor, tendon: a.tendon * factor)
    }
}

/// One completed or planned session, reduced to what it does to each group.
nonisolated struct TissueSession: Sendable {
    /// The stored record it came from.
    var id: String?
    var date: Date
    var sport: SportFamily
    var title: String
    var durationMinutes: Int
    var isPlanned: Bool
    var dose: [TissueGroup: TissueDose]

    static func endurance(_ sport: SportFamily, tl: Double) -> [TissueGroup: TissueDose] {
        (TissueConstants.enduranceWeights[sport] ?? [:]).mapValues { $0 * tl }
    }

    /// How a strength session works a group — the muscle map's two colours.
    nonisolated enum Target: Sendable { case primary, secondary }

    /// A set's exercise and the groups it works — through the library (which carries
    /// the tendon flag) or, for an exercise outside it, Garmin's catalog. Nil for a set
    /// naming neither: it loads nothing.
    static func groups(_ set: StrengthSets.SetRow)
        -> (exercise: Exercise?, primary: [TissueGroup], secondary: [TissueGroup])? {
        let exercise = set.exerciseId.flatMap(ExerciseLibrary.find(id:))
            ?? set.exerciseName.flatMap(ExerciseLibrary.find(garminName:))
        let groups = exercise.map { (primary: $0.primaryGroups, secondary: $0.secondaryGroups) }
            ?? set.exerciseCategory.flatMap { category in
                set.exerciseName.flatMap { GarminMuscles.groups(category: category, name: $0) }
            }
        return groups.map { (exercise, $0.primary, $0.secondary) }
    }

    /// Every group the sets work, primary wherever any set works it as a primary mover.
    static func targets(_ sets: [StrengthSets.SetRow]) -> [TissueGroup: Target] {
        var out: [TissueGroup: Target] = [:]
        for groups in sets.compactMap(Self.groups) {
            for group in groups.secondary where out[group] == nil { out[group] = .secondary }
            for group in groups.primary { out[group] = .primary }
        }
        return out
    }

    static func strength(_ sets: [StrengthSets.SetRow]) -> [TissueGroup: TissueDose] {
        let hardSet = TissueConstants.tlPerHardSet
        var out: [TissueGroup: TissueDose] = [:]
        for groups in sets.compactMap(Self.groups) {
            for group in groups.primary {
                let tendon = groups.exercise?.loadsTendon == true && group.tendonLabel != nil ? hardSet : 0
                out[group, default: .init()] += .init(muscle: hardSet, tendon: tendon)
            }
            for group in groups.secondary {
                out[group, default: .init()] += .init(muscle: hardSet * TissueConstants.secondaryShare)
            }
        }
        return out
    }
}

nonisolated enum TissueLoadModel {

    struct Output: Sendable {
        var forecasts: [TissueForecast]
        var conflicts: [TissueConflict]
        /// The window's planned sessions, the heaviest one marked key.
        var planned: [PlannedSession]
        var nextKeySession: PlannedSession?
        var drivers: [TissueDriver]
        /// Nil until six full weeks of history exist.
        var chronic: [TissueGroup: [ChronicWeek]]?
        var sessionCount: Int
    }

    /// Forecasts cover `past` days before today and `ahead` days from today on.
    static func run(_ sessions: [TissueSession], today: Date, past: Int, ahead days: Int,
                    calendar: Calendar = .current) -> Output {
        let start = calendar.startOfDay(for: today)
        func offset(_ date: Date) -> Int {
            calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: date)).day ?? 0
        }
        let first = -TissueConstants.historyDays
        let length = TissueConstants.historyDays + days
        // A plan left open in the past was not done — only today's and later plans count.
        let inWindow = sessions.filter {
            (($0.isPlanned ? 0 : first)..<days).contains(offset($0.date))
        }
        let completed = inWindow.filter { !$0.isPlanned }
        let planned = inWindow.filter(\.isPlanned).sorted { $0.date < $1.date }

        // Daily dose and morning state per group, indexed by offset − first.
        var daily: [TissueGroup: [TissueDose]] = [:]
        for session in inWindow {
            for (group, dose) in session.dose where dose.total > 0 {
                daily[group, default: Array(repeating: TissueDose(), count: length)][offset(session.date) - first] += dose
            }
        }
        let muscleDecay = exp(-1 / TissueConstants.muscleTimeConstantDays)
        let tendonDecay = exp(-1 / TissueConstants.tendonTimeConstantDays)
        let morning: [TissueGroup: [TissueDose]] = daily.mapValues { doses in
            var states = [TissueDose()]
            for index in 1..<length {
                let carried = states[index - 1] + doses[index - 1]
                states.append(TissueDose(muscle: carried.muscle * muscleDecay, tendon: carried.tendon * tendonDecay))
            }
            return states
        }

        func index(_ offset: Int) -> Int { offset - first }
        func baseline(_ states: [TissueDose]) -> TissueDose {
            let past = states[index(-TissueConstants.baselineDays)..<index(0)]
            let mean = past.reduce(TissueDose(), +) * (1 / Double(past.count))
            let floor = TissueConstants.baselineFloor
            return TissueDose(muscle: max(mean.muscle, floor), tendon: max(mean.tendon, floor))
        }
        func level(_ value: Double, _ baseline: Double) -> LoadLevel {
            let bounds = TissueConstants.levelBounds
            return LoadLevel(rawValue: bounds.firstIndex { value / baseline < $0 } ?? bounds.count) ?? .heavy
        }

        let groups = TissueGroup.allCases.filter { morning[$0] != nil }
        // A state after training is read against the average after-training state, a
        // morning against the average morning — a fresh session always towers over
        // what is left of one by the next morning.
        let baselines = Dictionary(uniqueKeysWithValues: groups.map { ($0, baseline(morning[$0]!)) })
        let trainedBaselines = Dictionary(uniqueKeysWithValues: groups.map { group in
            (group, baseline(zip(morning[group]!, daily[group]!).map(+)))
        })
        func state(_ group: TissueGroup, _ offset: Int, afterTraining: Bool = false) -> TissueDayState {
            let value = morning[group]![index(offset)] + (afterTraining ? daily[group]![index(offset)] : .init())
            let base = (afterTraining ? trainedBaselines : baselines)[group]!
            return TissueDayState(date: calendar.date(byAdding: .day, value: offset, to: start) ?? start,
                                  muscle: level(value.muscle, base.muscle),
                                  tendon: group.tendonLabel == nil ? nil : level(value.tendon, base.tendon))
        }
        let forecasts = groups.map { group in
            TissueForecast(group: group, days: (-past..<days).map { state(group, $0) }, todayIndex: past,
                           afterTraining: (-past..<days).map { state(group, $0, afterTraining: true) })
        }

        func loads(_ session: TissueSession) -> Set<TissueGroup> {
            let largest = session.dose.values.map(\.total).max() ?? 0
            return Set(session.dose.filter { largest > 0 && $0.value.total >= largest * TissueConstants.loadsShare }.keys)
        }
        var plannedSessions = planned.map {
            PlannedSession(id: UUID(), date: $0.date, sport: $0.sport, title: $0.title, isKey: false,
                           loads: loads($0), durationMinutes: $0.durationMinutes, dose: $0.dose, recordId: $0.id)
        }
        func weight(_ session: TissueSession) -> Double { session.dose.values.reduce(0) { $0 + $1.total } }
        if let heaviest = planned.indices.max(by: { weight(planned[$0]) < weight(planned[$1]) }),
           weight(planned[heaviest]) > 0 {
            plannedSessions[heaviest].isKey = true
        }

        let earliest = completed.map { offset($0.date) }.min() ?? 0
        var conflicts: [TissueConflict] = []
        if earliest <= -TissueConstants.minimumHistoryDays {
            // Planned sessions stack on top of what was already done that day.
            var stacked: [TissueGroup: [Int: TissueDose]] = [:]
            for session in completed where offset(session.date) >= 0 {
                for (group, dose) in session.dose {
                    stacked[group, default: [:]][offset(session.date), default: .init()] += dose
                }
            }
            for (session, plannedSession) in zip(planned, plannedSessions) {
                let day = offset(session.date)
                for group in groups where plannedSession.loads.contains(group) {
                    let states = morning[group]!, doses = daily[group]!
                    let peak = (index(-TissueConstants.peakDays)..<index(0)).reduce(TissueDose()) { peak, i in
                        let post = states[i] + doses[i]
                        return TissueDose(muscle: max(peak.muscle, post.muscle), tendon: max(peak.tendon, post.tendon))
                    }
                    let dose = session.dose[group] ?? .init()
                    let after = states[index(day)] + (stacked[group]?[day] ?? .init()) + dose
                    stacked[group, default: [:]][day, default: .init()] += dose
                    let morningState = state(group, day)
                    let tissue: TissueKind? = dose.tendon > 0 && after.tendon > peak.tendon * TissueConstants.spikeMargin ? .tendon
                        : dose.muscle > 0 && after.muscle > peak.muscle * TissueConstants.spikeMargin ? .muscle : nil
                    guard let tissue else { continue }
                    conflicts.append(TissueConflict(group: group, tissue: tissue, session: plannedSession,
                                                    morningLevel: tissue == .tendon ? (morningState.tendon ?? morningState.muscle)
                                                                                    : morningState.muscle))
                }
            }
        }

        let drivers = completed
            .filter { (-TissueConstants.driverDays...0).contains(offset($0.date)) }
            .map { TissueDriver(date: $0.date, sport: $0.sport, title: $0.title, loads: loads($0),
                                dose: $0.dose, recordId: $0.id) }
            .filter { !$0.loads.isEmpty }

        return Output(forecasts: forecasts,
                      conflicts: conflicts.sorted { ($0.session.date, $0.group.anatomicalRank) < ($1.session.date, $1.group.anatomicalRank) },
                      planned: plannedSessions,
                      nextKeySession: plannedSessions.first(where: \.isKey),
                      drivers: drivers,
                      chronic: chronic(completed, earliest: earliest, today: start, calendar: calendar),
                      sessionCount: completed.count)
    }

    /// The last six full weeks' muscle dose per group against the group's own
    /// average over them: −2 (under half) … +2 (over 1.6×), 0 inside 0.8–1.25×.
    private static func chronic(_ completed: [TissueSession], earliest: Int, today: Date,
                                calendar: Calendar) -> [TissueGroup: [ChronicWeek]]? {
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let weeks = (1...TissueConstants.chronicWeeks).reversed().compactMap { calendar.date(byAdding: .day, value: -7 * $0, to: thisWeek) }
        guard let firstWeek = weeks.first,
              let earliestDate = calendar.date(byAdding: .day, value: earliest, to: today),
              earliestDate <= firstWeek else { return nil }
        var out: [TissueGroup: [ChronicWeek]] = [:]
        for group in TissueGroup.allCases {
            let totals = weeks.map { week -> Double in
                let end = calendar.date(byAdding: .day, value: 7, to: week) ?? week
                return completed.filter { $0.date >= week && $0.date < end }.reduce(0) { $0 + ($1.dose[group]?.muscle ?? 0) }
            }
            let mean = totals.reduce(0, +) / Double(totals.count)
            guard mean > 0 else { continue }
            out[group] = zip(weeks, totals).map { week, total in
                let ratio = total / mean
                let deviation = ratio < TissueConstants.chronicFarUnder ? -2 : ratio < TissueConstants.chronicUnder ? -1
                    : ratio <= TissueConstants.chronicOver ? 0 : ratio <= TissueConstants.chronicFarOver ? 1 : 2
                return ChronicWeek(weekStart: week, deviation: deviation)
            }
        }
        return out
    }
}
