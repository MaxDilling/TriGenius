import SwiftUI

// MARK: - Time range
//
// The one set of windows every analysis view offers — the Statistics overview and
// each detail page it opens — so a range picked on one reads the same on the next.

enum TimeRange: String, CaseIterable, Identifiable {
    case oneMonth = "M"
    case threeMonths = "3M"
    case sixMonths = "6M"
    case oneYear = "Y"
    case all = "All"

    var id: String { rawValue }

    var months: Int? {
        switch self {
        case .oneMonth: return 1
        case .threeMonths: return 3
        case .sixMonths: return 6
        case .oneYear: return 12
        case .all: return nil
        }
    }

    /// Cut-off date for the window, or nil for `.all`.
    func start(now: Date = Date()) -> Date? {
        months.flatMap { Calendar.current.date(byAdding: .month, value: -$0, to: now) }
    }

    func contains(_ date: Date) -> Bool {
        start().map { date >= $0 } ?? true
    }

    /// Whole weeks back from today the window spans; `.all` reaches back to `first`,
    /// the oldest day of data.
    func weeks(first: Date?) -> Int {
        let now = Date()
        let start = start(now: now) ?? first ?? now
        return max(1, Int((now.timeIntervalSince(start) / (7 * 86_400)).rounded(.up)))
    }

    /// The shortest range spanning `months` — the chat's metric token asks in months.
    static func covering(months: Int) -> TimeRange {
        allCases.first { ($0.months ?? .max) >= months } ?? .all
    }
}

extension View {
    /// The screen-wide range, full width beneath the navigation bar as in Apple Health.
    /// Pinned there rather than scrolling with the content: it governs every chart
    /// below, and those run far enough that a control scrolling out of reach is friction.
    func rangeBar(_ range: Binding<TimeRange>) -> some View {
        safeAreaBar(edge: .top) {
            SegmentedPicker("Range", selection: range, options: TimeRange.allCases, fill: true, label: \.rawValue)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.bottom, Theme.Spacing.s)
        }
    }
}
