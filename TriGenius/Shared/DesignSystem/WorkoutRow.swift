import SwiftUI

/// One compact workout row — date column, sport disc, title over summary, chevron —
/// as the label of a `NavigationLink`. Rows in one card are split by a `Divider`
/// inset by `dividerInset`, so it starts under the disc.
struct WorkoutRow: View {
    let date: Date
    let family: SportFamily
    let title: String
    let summary: String
    var checkmark = false

    static let dividerInset: CGFloat = 62

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            dateColumn

            ZStack {
                Circle().fill(family.color.opacity(0.25))
                Image(systemName: family.icon)
                    .font(.headline)
                    .foregroundStyle(family.color)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).lineLimit(1)
                Text(summary).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)

            if checkmark {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.Palette.success)
            }
            Chevron()
        }
        .padding(.vertical, Theme.Spacing.m)
        .padding(.horizontal, Theme.Spacing.l)
        .contentShape(.rect)
    }

    private var dateColumn: some View {
        let isToday = Calendar.current.isDateInToday(date)
        return VStack(spacing: 2) {
            Text(date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(.caption).foregroundStyle(isToday ? Color.accentColor : .secondary)
            Text(date.formatted(.dateTime.day()))
                .font(.title2.bold())
                .foregroundStyle(isToday ? Color.accentColor : .primary)
        }
        .frame(width: 34)
    }
}
