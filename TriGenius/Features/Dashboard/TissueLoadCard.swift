import SwiftUI

// MARK: - Tissue Load card (Dashboard)
//
// Three rows answering one question each: when is this group clear for hard work
// again — or, where there is room, the full grid. A row opens its group, the card
// the Tissue Load screen; the closing row names what is free today and hands
// planning it to the coach.

nonisolated enum TissueCardMode: String, CaseIterable, Identifiable, Sendable {
    case sevenDays, sixWeeks

    var id: String { rawValue }
    var label: String { self == .sevenDays ? "7 days" : "6 weeks" }
}

struct TissueLoadCard: View {
    @Environment(\.dynamicTypeSize) private var typeSize

    @Binding var mode: TissueCardMode
    let model: TissueCardModel
    /// Nil until six weeks of history exist; the mode is then not offered.
    var chronic: TissueChronicModel?
    /// Every group's lanes, where there is room — replaces the 7-day rows.
    var grid: TissueGridModel?
    var onSelect: (TissueGroup) -> Void = { _ in }
    var onAskCoach: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            titleRow
                .padding(.bottom, Theme.Spacing.m + Theme.Spacing.xs)
            if mode == .sixWeeks, let chronic {
                chronicBody(chronic)
            } else if let grid {
                TissueGrid(days: grid.days, rows: grid.rows, isWide: true, onSelect: onSelect)
                TissueLegend()
                    .padding(.top, Theme.Spacing.m)
            } else {
                header
                ForEach(model.rows) { row in
                    Button { onSelect(row.group) } label: { rowBody(row) }
                        .buttonStyle(.plain)
                }
                closingRow
                    .padding(.top, Theme.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The rows and the 6-week view hold the same height so switching never
        // reflows the dashboard — except at accessibility sizes, where growing is
        // the point.
        .frame(minHeight: typeSize.isAccessibilitySize ? nil : TissueMetrics.cardContent,
               alignment: .top)
        .cardSurface()
    }

    // MARK: 6-week mode

    @ViewBuilder private func chronicBody(_ chronic: TissueChronicModel) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            if !typeSize.isAccessibilitySize {
                Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
            }
            HStack(spacing: TissueMetrics.weekGap) {
                ForEach(Array(chronic.monthLabels.enumerated()), id: \.offset) { _, label in
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        // Wider than its week column; it runs on over the unlabeled weeks after it.
                        .fixedSize()
                        .frame(width: TissueMetrics.weekCell.width, alignment: .leading)
                }
            }
            if typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            Text("vs target")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: TissueMetrics.statusColumn, alignment: .trailing)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityHidden(true)

        ForEach(chronic.rows) { row in
            Button { onSelect(row.group) } label: { chronicRow(row) }
                .buttonStyle(.plain)
        }

        if let action = chronic.action, let prompt = chronic.coachPrompt {
            Button { onAskCoach(prompt) } label: {
                HStack(spacing: Theme.Spacing.s) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Theme.Palette.Tissue.underStrong)
                        .frame(width: 12, height: 12)
                    Text(action)
                        .font(.footnote.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Theme.Spacing.s)
                .frame(minHeight: 40)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.appTertiaryBackground,
                            in: .rect(cornerRadius: Theme.Radius.s, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, Theme.Spacing.xs)
        }
    }

    private func chronicRow(_ row: TissueChronicRow) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Spacing.xs))
            : AnyLayout(HStackLayout(spacing: Theme.Spacing.s))
        return layout {
            Text(row.group.label)
                .font(.footnote.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Theme.Spacing.s) {
                HStack(spacing: TissueMetrics.weekGap) {
                    ForEach(Array(row.weeks.enumerated()), id: \.offset) { _, week in
                        deviationCell(week.deviation)
                    }
                }
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                if typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                VStack(alignment: .trailing, spacing: 2) {
                    Text(row.status.word)
                        .font(.footnote.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(row.statusDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minWidth: TissueMetrics.statusColumn, alignment: .trailing)
            }
        }
        .frame(minHeight: TissueMetrics.rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.group.label), \(row.status.word) target, \(row.statusDetail)")
    }

    /// One week against the target band: under grows down in the fitness blue, over
    /// grows up in the load ramp. On target shows the band alone.
    private func deviationCell(_ deviation: Int) -> some View {
        let band = TissueMetrics.targetBand
        let height = CGFloat(abs(deviation)) * TissueMetrics.deviationStep
        let color: Color = switch deviation {
        case ...(-2): Theme.Palette.Tissue.underStrong
        case -1: Theme.Palette.Tissue.under
        case 1: Theme.Palette.Tissue.load(.moderate)
        default: Theme.Palette.Tissue.load(.loaded)
        }
        return ZStack {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Theme.Palette.Tissue.targetBand)
                .frame(width: TissueMetrics.weekCell.width, height: band)
            if deviation != 0 {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color)
                    .frame(width: TissueMetrics.weekCell.width, height: height)
                    .offset(y: (band / 2 + height / 2) * (deviation < 0 ? 1 : -1))
            }
        }
        .frame(width: TissueMetrics.weekCell.width, height: TissueMetrics.weekCell.height)
        .accessibilityHidden(true)
    }

    // MARK: Title row

    /// The mode's lead sentence as the card's title, the window switch beside it.
    private var titleRow: some View {
        HStack(spacing: Theme.Spacing.s) {
            Group {
                if mode == .sixWeeks, let chronic {
                    Text(chronic.lead)
                } else {
                    HStack(spacing: Theme.Spacing.xs) {
                        switch model.lead.glyph {
                        case .conflict:
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.Palette.Tissue.conflict)
                        case .taper:
                            Image(systemName: "flag.fill")
                        case nil:
                            EmptyView()
                        }
                        Text(model.lead.text)
                    }
                }
            }
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if chronic != nil {
                SegmentedPicker("Window", selection: $mode, options: TissueCardMode.allCases, label: \.label)
            }
            Chevron()
        }
        .padding(.top, -Theme.Spacing.titleTuck)
    }

    // MARK: Day header

    private var header: some View {
        HStack(spacing: Theme.Spacing.s) {
            // The rows stack at accessibility sizes, so the lanes move to the leading
            // edge and the header follows them — an indented header would label nothing.
            if !typeSize.isAccessibilitySize {
                Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
            }
            HStack(spacing: TissueMetrics.dayGap) {
                ForEach(model.days) { day in
                    VStack(spacing: 2) {
                        Text(day.letter)
                            .font(day.isToday ? .caption2.weight(.bold) : .caption2)
                            .foregroundStyle(day.isToday ? Color.primary : .secondary)
                        dayMarker(day)
                    }
                    .frame(width: TissueMetrics.dayColumn)
                }
            }
            if typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            Text("Clear by")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: TissueMetrics.forecastColumn, alignment: .trailing)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func dayMarker(_ day: TissueCardDay) -> some View {
        if day.isRace {
            Image(systemName: "flag.fill")
                .font(.caption2)
                .frame(height: TissueMetrics.keyRing)
        } else if let sport = day.sport {
            Circle()
                .fill(Theme.Palette.sport(sport))
                .frame(width: TissueMetrics.sportDot, height: TissueMetrics.sportDot)
                .frame(width: TissueMetrics.keyRing, height: TissueMetrics.keyRing)
                // A key session wears a ring, with the card showing through the gap.
                .overlay {
                    if day.isKey {
                        Circle().strokeBorder(Color.primary, lineWidth: TissueMetrics.keyRingWidth)
                    }
                }
        } else {
            Color.clear.frame(height: TissueMetrics.keyRing)
        }
    }

    // MARK: Row

    private func rowBody(_ row: TissueCardRow) -> some View {
        // At accessibility sizes the name and the evidence stack instead of competing
        // for one line — the card grows, nothing is cut.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Spacing.xs))
            : AnyLayout(HStackLayout(spacing: Theme.Spacing.s))
        return layout {
            VStack(alignment: .leading, spacing: 2) {
                // The triangle trails the name, so every row's name starts on one edge.
                HStack(spacing: Theme.Spacing.xs) {
                    Text(row.group.label)
                        .font(.footnote.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if row.conflictDay != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.Palette.Tissue.conflict)
                    }
                }
                HStack(spacing: Theme.Spacing.xs) {
                    captionGlyph(row)
                    Text(row.caption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: Theme.Spacing.s) {
                lanes(row)
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                if typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                VStack(alignment: .trailing, spacing: 2) {
                    Text(row.clearLabel)
                        .font(.footnote.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let caption = row.conflictCaption {
                        Text(caption)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(minWidth: TissueMetrics.forecastColumn, alignment: .trailing)
            }
        }
        .frame(minHeight: TissueMetrics.rowHeight)
        // The tint reaches out past the row instead of pushing its content in, so a
        // conflict row's columns stay on the header's and the other rows' lines.
        .background {
            if row.conflictDay != nil {
                RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                    .fill(Theme.Palette.Tissue.conflictFill)
                    .padding(.horizontal, -Theme.Spacing.s)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(row))
    }

    @ViewBuilder private func captionGlyph(_ row: TissueCardRow) -> some View {
        let level = row.days.first.map { row.captionKind == .tendon ? ($0.tendon ?? $0.muscle) : $0.muscle } ?? .fresh
        if row.captionKind == .tendon {
            TendonMark(level: level, side: 6)
        } else {
            MuscleMark(level: level, size: CGSize(width: 10, height: 4))
        }
    }

    private func lanes(_ row: TissueCardRow) -> some View {
        HStack(spacing: TissueMetrics.dayGap) {
            ForEach(Array(row.days.enumerated()), id: \.offset) { index, day in
                VStack(spacing: Theme.Spacing.xs) {
                    MuscleMark(level: day.muscle)
                    if let tendon = day.tendon {
                        TendonMark(level: tendon)
                    } else {
                        Color.clear.frame(height: TissueMetrics.tendonDiamondBox)
                    }
                }
                .frame(width: TissueMetrics.dayColumn)
                .overlay {
                    if index == row.conflictDay {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(Theme.Palette.Tissue.conflict,
                                          lineWidth: TissueMetrics.conflictOutline)
                            // As much room under the diamond as beside it.
                            .padding(EdgeInsets(top: -1, leading: -1,
                                                bottom: -1 - (TissueMetrics.dayColumn - TissueMetrics.tendonDiamondBox) / 2,
                                                trailing: -1))
                    }
                }
            }
        }
        .frame(width: TissueMetrics.laneBlock)
    }

    private func accessibilityLabel(_ row: TissueCardRow) -> String {
        var parts = ["\(row.group.label), \(row.caption) governs, clear \(row.clearLabel)"]
        if let caption = row.conflictCaption { parts.append("conflicts with \(caption)") }
        return parts.joined(separator: ", ")
    }

    // MARK: Closing row

    private var closingRow: some View {
        Button { onAskCoach(model.closing.coachPrompt) } label: {
            HStack(spacing: Theme.Spacing.s) {
                VStack(spacing: 2) {
                    MuscleMark(level: .fresh, size: CGSize(width: 14, height: 5))
                    TendonMark(level: .fresh, side: 6)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.closing.title)
                        .font(.footnote.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(model.closing.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Text("Plan")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, Theme.Spacing.s)
            .frame(minHeight: 40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appTertiaryBackground,
                        in: .rect(cornerRadius: Theme.Radius.s, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
