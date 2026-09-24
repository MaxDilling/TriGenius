#if DEBUG
import Foundation

// Preview data run through the real `TissueLoadModel`: seven weeks of a typical
// triathlon week with a slowly growing long run, then the week ahead. Pinned to the
// Monday the design frames were drawn for, so the weekdays match the frames.

enum TissuePreviewFixture {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.firstWeekday = 2
        return calendar
    }()
    static let locale = Locale(identifier: "en_US")
    static let monday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 21))!

    /// The usual week continues — load everywhere, nothing wrong.
    static var buildWeek: TissueCardModel.Input { input(ahead: week(from: 0, longRunTL: 120), period: .build1).input }
    /// Tomorrow's long run is twice the longest of the last month.
    static var conflict: TissueCardModel.Input { input(ahead: week(from: 1, longRunTL: 240, longRunDay: 0), period: .build2).input }
    /// Race week: short sessions, Sunday's race the heaviest.
    static var taper: TissueCardModel.Input {
        input(ahead: [run(1, tl: 40), swim(2, tl: 30), run(6, tl: 110, title: "Olympic distance")], period: .race).input
    }
    static var chronic: TissueChronicModel? {
        input(ahead: [], period: .build1).chronic.flatMap { TissueChronicModel.make(history: $0, calendar: calendar, locale: locale) }
    }

    private static func input(ahead: [TissueSession], period: ATPPeriod)
        -> (input: TissueCardModel.Input, chronic: [TissueGroup: [ChronicWeek]]?) {
        let history = (1...7).flatMap { weeksAgo in week(from: -7 * weeksAgo, longRunTL: 130 - 7 * Double(weeksAgo)) }
        return TissueCardModel.Input.model(history + ahead, period: period, today: monday, calendar: calendar)
    }

    /// Tue intervals, Wed swim, Thu ride, Fri strength, Sat long ride, Sun long run.
    private static func week(from offset: Int, longRunTL: Double, longRunDay: Int = 6) -> [TissueSession] {
        [run(offset + 1, tl: 70, title: "Threshold run"),
         swim(offset + 2, tl: 50),
         session(offset + 3, .bike, "Endurance ride", dose: TissueSession.endurance(.bike, tl: 80)),
         session(offset + 4, .strength, "Gym", dose: TissueSession.strength(
            ["back_squat", "romanian_deadlift", "standing_calf_raise", "seated_cable_row"].flatMap { id in
                Array(repeating: StrengthSets.SetRow(exerciseId: id, reps: 8), count: 3)
            })),
         session(offset + 5, .bike, "Long ride", dose: TissueSession.endurance(.bike, tl: 150)),
         run(offset + longRunDay, tl: longRunTL, title: "Long run")]
    }

    private static func run(_ offset: Int, tl: Double, title: String = "Easy run") -> TissueSession {
        session(offset, .run, title, dose: TissueSession.endurance(.run, tl: tl))
    }

    private static func swim(_ offset: Int, tl: Double) -> TissueSession {
        session(offset, .swim, "Technique", dose: TissueSession.endurance(.swim, tl: tl))
    }

    /// Planned from the frame Monday on, done before it.
    private static func session(_ offset: Int, _ sport: SportFamily, _ title: String,
                                dose: [TissueGroup: TissueDose]) -> TissueSession {
        TissueSession(date: calendar.date(byAdding: .day, value: offset, to: monday)!, sport: sport, title: title,
                      durationMinutes: 60, isPlanned: offset >= 0, dose: dose)
    }
}
#endif
