import SwiftUI

// MARK: - Power curve detail
//
// The range's best-power curve, on a log or linear duration axis, with the CP/W′
// model laid over it whenever both are known. The model reads today's CP and W′,
// whatever the range.

struct PowerCurveDetailView: View {
    @State var range: TimeRange
    @State private var points: [PowerCurve.Point] = []
    @State private var snapshot: PerformanceSnapshot?
    @State private var scale = PowerCurveChart.Scale.log

    private var cpModel: PowerCurve.Model? { snapshot.flatMap { PowerCurve.Model(snapshot: $0) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                if points.isEmpty {
                    Text("No cycling power data in this range.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    PowerCurveChart(model: PowerCurveModel(points: points, cpModel: cpModel),
                                    scale: scale, height: 260)
                }
                if let snapshot, let cpModel { modelLegend(cpModel, snapshot) }
                SectionHeading("About the power curve")
                Text("""
                    The power curve shows the highest average power you have reached for each duration, from a one-second sprint to several hours, across every ride with a power meter in the selected range. Each duration is its own best: your best 5 minutes and your best 20 minutes usually come from different rides. Move along the chart to see which ride set a value. The longer the effort, the less power you can sustain, so the curve always falls. The logarithmic scale gives short and long efforts the same room; the linear scale shows time to scale.

                    The CP/W′ model line is what your critical power (CP) and W′ predict you could hold in a single all-out effort, started fresh: CP plus your W′ reserve spread evenly over the effort. Over 5 minutes, for example, a CP of 250 W and a W′ of 18 kJ give 250 W + 18,000 J ÷ 300 s = 310 W. Where your curve sits clearly below the line, you have most likely not yet ridden that duration all-out — it is untested, not a weakness. Where your curve rises clearly above it, your CP or W′ is set too low.

                    The model is shown from 1:30 to 30 minutes, where it holds. In shorter efforts your top sprint power sets the limit, so the model would promise more than your legs can deliver. In longer efforts fatigue pushes your power below CP, so it would overestimate again. Unlike the curve, the model reflects your current CP and W′, not the selected range.
                    """)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .contentCard()
            }
            .padding(Theme.Spacing.l)
        }
        .background(Color.appBackground)
        .navigationTitle(StatCard.powerCurve.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .rangeBar($range)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SegmentedPicker("Scale", selection: $scale,
                                options: PowerCurveChart.Scale.allCases, label: \.label)
            }
        }
        .task(id: range) {
            snapshot = TrainingDataStore.shared.latestSnapshot()
            points = PowerCurve.aggregate(records: TrainingDataStore.shared.activities(
                from: range.start() ?? .distantPast, to: .now))
        }
    }

    private func modelLegend(_ model: PowerCurve.Model, _ snapshot: PerformanceSnapshot) -> some View {
        let estimated = snapshot.criticalPowerIsEstimated || snapshot.wPrimeIsEstimated
        return VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.s) {
                Path { $0.move(to: .zero); $0.addLine(to: CGPoint(x: 18, y: 0)) }
                    .stroke(PowerCurveChart.modelColor, style: PowerCurveChart.modelStroke)
                    .frame(width: 18, height: 2)
                Text("CP/W′ model")
            }
            Text("1:30 to 30 min, from CP \(Int(model.cp.rounded())) W and W′ "
                 + "\(model.wPrimeKJ.formatted(.number.precision(.fractionLength(1)))) kJ"
                 + (estimated ? " (estimated)" : ""))
                .font(.caption).foregroundStyle(.secondary)
        }
        .contentCard()
    }
}
