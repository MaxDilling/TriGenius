import SwiftUI

// MARK: - Tissue Load grid
//
// Every group against every day: the card's three rows without the editing down to
// three. Each cell draws the tissue that *governs* that morning — the muscle fill,
// with the tendon's diamond on top when the tendon is the one holding the group back.
//
// Used by the tap-through screen on the phone and, at wide sizes, in place of the
// dashboard card. The day columns share the width the card leaves them.

nonisolated struct TissueGridDay: Identifiable, Sendable {
    let date: Date
    let letter: String
    let dayNumber: String
    let sport: SportFamily?
    let isKey: Bool
    let isToday: Bool

    var id: Date { date }
}

nonisolated struct TissueGridRow: Identifiable, Sendable {
    let group: TissueGroup
    let clearLabel: String
    let days: [TissueDayState]
    let conflictDay: Int?

    var id: TissueGroup { group }
}

struct TissueGrid: View {
    let days: [TissueGridDay]
    let rows: [TissueGridRow]
    var isWide = false
    var onSelect: (TissueGroup) -> Void = { _ in }

    private var cell: CGSize { isWide ? TissueMetrics.gridCellWide : TissueMetrics.gridCellPhone }
    private var gap: CGFloat { isWide ? Theme.Spacing.xs : 2 }
    private var nameColumn: CGFloat { isWide ? 110 : 74 }
    /// Wide enough for "Later" or a localized weekday on one line at the 375 pt floor.
    private var clearColumn: CGFloat { isWide ? 72 : 66 }

    var body: some View {
        VStack(alignment: .leading, spacing: gap) {
            header
            ForEach(rows) { row in
                Button { onSelect(row.group) } label: { rowBody(row) }
                    .buttonStyle(.plain)
            }
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.s) {
            Color.clear.frame(width: nameColumn, height: 0)
            // Over the clear column and aligned like its values.
            Text("Clear by")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
                .frame(width: clearColumn, alignment: .leading)
            HStack(spacing: gap) {
                ForEach(days) { day in
                    VStack(spacing: 1) {
                        Text(day.letter)
                            .font(.caption2)
                            .foregroundStyle(day.isToday ? Color.primary : .secondary)
                        Text(day.dayNumber)
                            .font(day.isToday ? .caption2.weight(.bold) : .caption2)
                            .foregroundStyle(day.isToday ? Color.primary : .secondary)
                        marker(day)
                    }
                    .frame(minWidth: cell.width, maxWidth: .infinity)
                }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.large)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func marker(_ day: TissueGridDay) -> some View {
        if let sport = day.sport {
            Circle()
                .fill(Theme.Palette.sport(sport))
                .frame(width: TissueMetrics.sportDot, height: TissueMetrics.sportDot)
                .frame(width: TissueMetrics.keyRing, height: TissueMetrics.keyRing)
                .overlay {
                    if day.isKey {
                        Circle().strokeBorder(Color.primary, lineWidth: TissueMetrics.keyRingWidth)
                    }
                }
        } else {
            Color.clear.frame(height: TissueMetrics.keyRing)
        }
    }

    private func rowBody(_ row: TissueGridRow) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Text(row.group.label)
                .font(.footnote.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: nameColumn, alignment: .leading)
            Text(row.clearLabel)
                .font(.footnote.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: clearColumn, alignment: .leading)
            HStack(spacing: gap) {
                ForEach(Array(row.days.enumerated()), id: \.offset) { index, day in
                    cellView(day, isToday: days.indices.contains(index) && days[index].isToday,
                             isConflict: index == row.conflictDay)
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.large)
        }
        .frame(minHeight: TissueMetrics.gridRow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.group.label), clear \(row.clearLabel)")
    }

    private func cellView(_ day: TissueDayState, isToday: Bool, isConflict: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        return shape
            .fill(Theme.Palette.Tissue.load(day.muscle))
            .overlay {
                // The tendon only takes the cell when it is the one holding the group back.
                if day.governing == .tendon, let tendon = day.tendon {
                    TendonMark(level: tendon, side: min(cell.height, 10))
                }
            }
            .overlay {
                if isConflict {
                    shape.strokeBorder(Theme.Palette.Tissue.conflict,
                                       lineWidth: TissueMetrics.conflictOutline)
                } else if isToday {
                    shape.strokeBorder(Color.primary, lineWidth: TissueMetrics.conflictOutline)
                }
            }
            .frame(minWidth: cell.width, maxWidth: .infinity)
            .frame(height: cell.height)
    }
}

/// The marks and what they mean, shown once under the grid.
struct TissueLegend: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.m) { items }
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                HStack(spacing: Theme.Spacing.m) { items }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var items: some View {
        label(AnyView(MuscleMark(level: .loaded)), "muscle")
        label(AnyView(TendonMark(level: .loaded)), "tendon")
        label(AnyView(MuscleMark(level: .fresh)), "clear")
    }

    private func label(_ mark: AnyView, _ text: String) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            mark
            Text(text)
        }
    }
}
