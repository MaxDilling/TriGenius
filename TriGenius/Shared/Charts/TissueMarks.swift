import SwiftUI

// MARK: - Tissue Load marks
//
// The primitives every Tissue Load surface is built from. Each tissue gets its own
// shape, not just its own colour, so they stay distinguishable in greyscale: muscle is
// a bar, tendon a diamond.
//
// The marks carry no text and are hidden from VoiceOver — the row that owns them
// speaks the whole state in one label.

nonisolated enum TissueMetrics {
    // Card geometry at the 375 pt floor. Only the graphics are fixed: the name column
    // flexes, so a longer localized label or a larger Dynamic Type size grows the row
    // instead of truncating it.
    static let dayColumn: CGFloat = 12
    static let dayGap: CGFloat = 2
    /// Days shown before today — what put the load there — and from today on.
    static let pastDays = 3
    static let aheadDays = 7
    /// Every lane and grid row: the past days, today, and the days after it.
    static let dayCount = pastDays + aheadDays
    static let laneBlock = CGFloat(dayCount) * dayColumn + CGFloat(dayCount - 1) * dayGap
    static let forecastColumn: CGFloat = 69
    static let rowHeight: CGFloat = 44
    static let sportDot: CGFloat = 6
    static let keyRing: CGFloat = 11
    static let keyRingWidth: CGFloat = 1.25
    static let conflictOutline: CGFloat = 1.5
    // Grid (tap-through and wide)
    static let gridCellPhone = CGSize(width: 13, height: 14)
    /// Minimum widths — the cells share whatever the grid has; a larger minimum pushes
    /// ten days past the edge of a window that only just counts as wide.
    static let gridCellWide = CGSize(width: 24, height: 16)
    static let gridRow: CGFloat = 20
    /// The read-only locator figure in the group detail's header.
    static let detailFigure: CGFloat = 44

    /// Shared content height, so switching the card's mode never reflows the dashboard.
    static let cardContent: CGFloat = 214

    // 6-week mode
    static let weekCell = CGSize(width: 20, height: 26)
    static let weekGap: CGFloat = 4
    static let statusColumn: CGFloat = 61
    static let targetBand: CGFloat = 4
    static let deviationStep: CGFloat = 5

    static let muscleBar = CGSize(width: 12, height: 6)
    static let muscleBarRadius: CGFloat = 2
    static let tendonDiamond: CGFloat = 7
    /// The rotated diamond's layout box — its diagonal, so an outline around it clears it.
    static var tendonDiamondBox: CGFloat { tendonDiamond * 2.squareRoot() }
    static let tendonDiamondRadius: CGFloat = 1.5
    static let tendonClearStroke: CGFloat = 1.5
}

/// Muscle load: a filled bar.
struct MuscleMark: View {
    var level: LoadLevel
    var size = TissueMetrics.muscleBar
    /// The detail view's lanes stretch the bar across the whole day column.
    var fillsWidth = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: TissueMetrics.muscleBarRadius, style: .continuous)
    }

    var body: some View {
        shape
            .fill(Theme.Palette.Tissue.load(level))
            .frame(width: fillsWidth ? nil : size.width, height: size.height)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .accessibilityHidden(true)
    }
}

/// Tendon load: a diamond. Clear draws as an outline, so a clear tendon still reads as
/// a tendon rather than disappearing into the row.
struct TendonMark: View {
    var level: LoadLevel
    var side = TissueMetrics.tendonDiamond

    var body: some View {
        RoundedRectangle(cornerRadius: TissueMetrics.tendonDiamondRadius, style: .continuous)
            .fill(level == .fresh ? Color.clear : Theme.Palette.Tissue.load(level))
            .overlay {
                if level == .fresh {
                    RoundedRectangle(cornerRadius: TissueMetrics.tendonDiamondRadius, style: .continuous)
                        .strokeBorder(Theme.Palette.Tissue.clearStroke, lineWidth: TissueMetrics.tendonClearStroke)
                }
            }
            .frame(width: side, height: side)
            .rotationEffect(.degrees(45))
            // Rotation doesn't resize the layout box; the diagonal does.
            .frame(width: side * 2.squareRoot(), height: side * 2.squareRoot())
            .accessibilityHidden(true)
    }
}

#Preview("Tissue marks") {
    VStack(alignment: .leading, spacing: Theme.Spacing.m) {
        ForEach(LoadLevel.allCases, id: \.self) { level in
            HStack(spacing: Theme.Spacing.s) {
                MuscleMark(level: level)
                TendonMark(level: level)
                Text(level.word)
                    .font(.caption)
            }
        }
    }
    .padding(Theme.Spacing.l)
    .cardSurface()
    .padding(Theme.Spacing.l)
}
