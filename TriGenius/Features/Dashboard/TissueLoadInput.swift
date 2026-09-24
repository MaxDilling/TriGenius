import Foundation

// MARK: - Tissue Load input (store → model)
//
// Shapes the store's sessions into `TissueSession` doses and runs `TissueLoadModel` —
// the one place the Tissue Load surfaces read the store. A completed session is dosed
// per leg from its scored TL, a strength session from its recorded sets (never its
// HR-derived TL); a plan from its planned TL or its prescribed sets. A strength
// session without sets carries no dose.

extension TissueCardModel.Input {
    @MainActor
    static func live(atpPlan: ATPPlan?, today: Date = Date(), calendar: Calendar = .current,
                     store: TrainingDataStore = .shared) -> (input: Self, chronic: [TissueGroup: [ChronicWeek]]?) {
        let start = calendar.startOfDay(for: today)
        let historyStart = calendar.date(byAdding: .day, value: -TissueConstants.historyDays, to: start) ?? start
        let windowEnd = calendar.date(byAdding: .day, value: TissueMetrics.aheadDays - 1, to: start) ?? start

        let completed = store.activities(since: historyStart).map { record -> TissueSession in
            let dose: [TissueGroup: TissueDose]
            if record.family == .strength {
                let details = record.detailsJSON.data(using: .utf8)
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                let entries = (details["strength"] as? [String: Any])?["exercises"] as? [[String: Any]] ?? []
                dose = TissueSession.strength(StrengthSets.rows(performed: entries))
            } else {
                dose = record.sportContributions.reduce(into: [:]) { sum, leg in
                    sum.merge(TissueSession.endurance(leg.family, tl: leg.tss), uniquingKeysWith: +)
                }
            }
            return TissueSession(id: record.id, date: record.date, sport: record.family, title: record.name,
                                 durationMinutes: Int(record.durationMinutes.rounded()), isPlanned: false, dose: dose)
        }
        let planned = store.openScheduledWorkouts(from: start, to: windowEnd).map { plan in
            TissueSession(id: plan.id, date: plan.date, sport: plan.family, title: plan.name,
                          durationMinutes: Int(plan.plannedDurationMinutes.rounded()), isPlanned: true,
                          dose: plan.family == .strength
                              ? TissueSession.strength(StrengthSets.plannedSets(WorkoutPayloadBuilder.parseSteps(plan.stepsJSON) ?? []))
                              : TissueSession.endurance(plan.family, tl: plan.resolvedTargetTSS))
        }

        let period = atpPlan?.weeks.first { week in
            week.weekStart <= start && start < (calendar.date(byAdding: .day, value: 7, to: week.weekStart) ?? week.weekStart)
        }?.period
        return model(completed + planned, period: period, today: start, calendar: calendar)
    }

    /// The model's output as the card, grid and detail consume it.
    static func model(_ sessions: [TissueSession], period: ATPPeriod?, today: Date,
                      calendar: Calendar = .current) -> (input: Self, chronic: [TissueGroup: [ChronicWeek]]?) {
        let output = TissueLoadModel.run(sessions, today: today, past: TissueMetrics.pastDays,
                                         ahead: TissueMetrics.aheadDays, calendar: calendar)
        let input = Self(forecasts: output.forecasts,
                         conflicts: output.conflicts,
                         planned: output.planned,
                         nextKeySession: output.nextKeySession,
                         previouslyListed: [],
                         period: period,
                         sessionCount: output.sessionCount,
                         drivers: output.drivers,
                         today: calendar.startOfDay(for: today))
        return (input, output.chronic)
    }
}
