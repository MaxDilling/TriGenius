import SwiftUI

// MARK: - Plan cards
//
// Where the athlete stands against the plan — fitness vs the ATP's planned CTL, and
// this week's per-discipline rings. Shown in the dashboard's Pinned section, on
// Statistics and (fitness vs plan) in the coach chat; both lead to the Plan tab.

struct FitnessVsPlanCard: View {
    static let title = "Planned vs. Actual Fitness"

    let model: CTLTrendModel

    @Environment(CoachRouter.self) private var router

    var body: some View {
        Button { router.selectedTab = .plan } label: {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                CardHeader(title: Self.title, color: Theme.Palette.fitness)
                CTLTrendChart(model: model)
            }
            .contentCard()
        }
        .buttonStyle(.plain)
    }
}

struct WeeklyTargetCard: View {
    let week: WeekTargets

    @Environment(CoachRouter.self) private var router
    @State private var metric: VolumeMetric = .tss
    private var wide = WideLayout()

    init(week: WeekTargets) { self.week = week }

    var body: some View {
        HStack(alignment: wide.isWide ? .center : .top, spacing: wide.isWide ? Theme.Spacing.l : Theme.Spacing.s) {
            ForEach(week.visibleFamilies) { family in
                VolumeRing(family: family, metric: metric, horizontal: wide.isWide,
                           goal: week.target(for: family), projection: week.projection(for: family))
            }
            Chevron()
        }
        .cardTitle("Weekly Target") {
            SegmentedPicker("Metric", selection: $metric, options: VolumeMetric.allCases, label: \.label)
        }
        .contentCard()
        // A tap gesture, not a Button: the picker in the title has to keep its taps.
        .contentShape(Rectangle())
        .onTapGesture { router.selectedTab = .plan }
    }
}

// MARK: Volume metric (TSS vs. distance)

/// Which metric the Weekly Target rings fill against and show on top. The other
/// metric drops to the secondary line below.
private enum VolumeMetric: CaseIterable {
    case tss, distance

    var label: String { self == .tss ? "TSS" : "km" }
}

// MARK: Volume ring

private struct VolumeRing: View {
    let family: SportFamily
    let metric: VolumeMetric
    /// Wide layouts put the numbers beside the ring instead of under it, so three
    /// tiles fill the row rather than floating in it.
    var horizontal = false
    let goal: WeeklyTarget
    /// Actual comes from the projection (its own weekly sum), so the solid arc and
    /// the faded projection arc past it share one number; cross-training credit is
    /// a mid-opacity segment between the two.
    let projection: WeeklyProjection

    private var actual: Double { metric == .tss ? projection.actualTSS : projection.actualKm }
    private var target: Double { metric == .tss ? goal.tss : goal.distanceKm }
    private var projected: Double { max(metric == .tss ? projection.projectedTSS : projection.projectedKm, actual) }
    // Credit is TSS-only — distance doesn't transfer across sports.
    private var credited: Double { metric == .tss ? projection.creditedTSS : 0 }
    private var projectedCredit: Double { metric == .tss ? projection.projectedCreditTSS : 0 }

    private func fraction(_ value: Double) -> Double { target > 0 ? min(value / target, 1) : 0 }
    /// Solid fill: what the athlete actually did in this discipline.
    private var realTop: Double { fraction(actual) }
    /// End of the borrowed-credit segment (real + credit).
    private var creditTop: Double { fraction(actual + credited) }
    /// End of the projection arc (projected close + its credit).
    private var projTop: Double { fraction(projected + projectedCredit) }

    /// True once even the credited projected close falls short of the target — the
    /// visible gap that signals an at-risk week.
    private var fallsShort: Bool { target > 0 && projTop < 0.99 }

    var body: some View {
        let layout = horizontal ? AnyLayout(HStackLayout(spacing: Theme.Spacing.m))
                                : AnyLayout(VStackLayout(spacing: 8))
        layout {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.10), lineWidth: 7)
                // Projection: the still-planned continuation beyond the completed
                // (solid) arc, up to the weekly target. Same 7pt radius as the
                // solid arc but dashed + lighter so it reads as "planned, not yet
                // done" rather than "done".
                if projTop > creditTop {
                    Circle()
                        .trim(from: creditTop, to: projTop)
                        .stroke(family.color.opacity(0.65),
                                style: StrokeStyle(lineWidth: 7, lineCap: .butt, dash: [2, 2]))
                        .rotationEffect(.degrees(-90))
                }
                // Cross-training credit: mid-opacity solid segment past the real
                // fill, so borrowed load reads as borrowed rather than done.
                if creditTop > realTop {
                    Circle()
                        .trim(from: realTop, to: creditTop)
                        .stroke(family.color.opacity(0.80),
                                style: StrokeStyle(lineWidth: 7, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
                Circle()
                    .trim(from: 0, to: realTop)
                    .stroke(family.color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: family.icon).font(.title3).foregroundStyle(family.color)
            }
            .frame(width: 60, height: 60)

            VStack(alignment: horizontal ? .leading : .center, spacing: 1) {
                Text(label(metric, actual)).font(.subheadline.weight(.semibold))
                if target > 0 {
                    Text("/ \(label(metric, target))").font(.caption2).foregroundStyle(.secondary)
                }
                if projected > actual {
                    // The expected close given what is still planned this week —
                    // tertiary (lighter) when on track, amber only when at risk.
                    Text("→ \(label(metric, projected))")
                        .font(.caption2)
                        .foregroundStyle(fallsShort ? Theme.Palette.warning : Color.secondary.opacity(0.6))
                        .padding(.top, 1)
                }
                
                Text(label(secondaryMetric, secondaryActual))
                    .font(.caption.weight(.semibold)).foregroundStyle(family.color)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: horizontal ? .leading : .center)
    }

    private var secondaryMetric: VolumeMetric { metric == .tss ? .distance : .tss }
    private var secondaryActual: Double { metric == .tss ? projection.actualKm : projection.actualTSS }

    private func label(_ m: VolumeMetric, _ value: Double) -> String {
        switch m {
        case .tss:
            return "\(Int(value.rounded())) TSS"
        case .distance:
            return value >= 10
                ? "\(Int(value.rounded())) km"
                : String(format: "%.1f km", value)
        }
    }
}

