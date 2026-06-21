import SwiftUI

// MARK: - Widget Ring
//
// A self-contained ring for the widget, adapted from the dashboard's `VolumeRing`
// (Features/Dashboard/DashboardView.swift): background track + a faded dashed
// projection arc continuing past the solid "actual" fill, up to the weekly
// target, with the discipline's SF Symbol centered. The widget extension can't
// reuse the app's `VolumeRing` (different target, and it depends on app-only
// design tokens), so this is the extension's own copy of that geometry.

struct WidgetRing: View {
    let entry: WeeklyTargetSnapshot.Entry
    /// Ring diameter — the medium widget uses a larger ring than the small one.
    var diameter: CGFloat = 54
    var lineWidth: CGFloat = 6
    var showLabels: Bool = true

    // Rings fill against TSS (the dashboard's default metric).
    private var actual: Double { entry.actualTSS }
    private var target: Double { entry.targetTSS }
    private var projected: Double { max(entry.projectedTSS, actual) }

    private var fraction: Double { target > 0 ? min(actual / target, 1) : 0 }
    private var projectedFraction: Double { target > 0 ? min(projected / target, 1) : 0 }
    /// At-risk: the expected close still falls short of the weekly target.
    private var fallsShort: Bool { target > 0 && projectedFraction < 0.999 }

    private var color: Color { WidgetRing.sportColor(entry.sport) }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: lineWidth)
                if projectedFraction > fraction {
                    Circle()
                        .trim(from: fraction, to: projectedFraction)
                        .stroke(color.opacity(0.40),
                                style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt, dash: [4, 4]))
                        .rotationEffect(.degrees(-90))
                }
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: entry.iconSystemName)
                    .font(.subheadline)
                    .foregroundStyle(color)
            }
            .frame(width: diameter, height: diameter)

            if showLabels {
                VStack(spacing: 1) {
                    Text("\(Int(actual.rounded())) TSS")
                        .font(.caption2.weight(.semibold))
                    if target > 0 {
                        Text("/ \(Int(target.rounded()))")
                            .font(.caption2)
                            .foregroundStyle(fallsShort ? .orange : .secondary)
                    }
                }
            }
        }
    }

    /// Maps a `SportFamily` raw value to its accent color — the extension's own
    /// 3-case presentation map, matching `SportFamily.color` in the app
    /// (DashboardView.swift).
    static func sportColor(_ sport: String) -> Color {
        switch sport {
        case "swim": return .cyan
        case "bike": return .purple
        case "run":  return .orange
        default:     return .green
        }
    }
}
