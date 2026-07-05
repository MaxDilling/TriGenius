import SwiftUI

// MARK: - Statistics
//
// The analysis screen behind the dashboard's Statistics card: the PMC (stat
// cards + chart), fitness ramp rate, sport share, time in zone, and the
// physiological-marker grid. All charts render shared `Shared/Charts/`
// components from plain value models; missing data shows as absence, never a
// fabricated distribution.

struct StatisticsView: View {
    @State private var viewModel = StatisticsViewModel()

    var body: some View {
        ScrollView {
            // One GlassEffectContainer so the PMC panes and cards blend as a
            // single glass system instead of stacking independent glass layers.
            GlassEffectContainer(spacing: Theme.Spacing.l) {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    if let pmc = viewModel.pmc {
                        PMCInsightsSection(result: pmc)
                    }

                    Picker("Range", selection: $viewModel.range) {
                        ForEach(StatisticsViewModel.StatsRange.allCases) { range in
                            Text(range.rawValue).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    rampCard
                    shareCard
                    zonesCard
                    powerCurveCard

                    PerformanceMetricsSection()
                }
            }
            .padding(Theme.Spacing.l)
        }
        .background(Color.appBackground)
        .navigationTitle("Statistics")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { viewModel.load() }
        .onReceive(NotificationCenter.default.publisher(for: .trainingDataDidChange)) { _ in
            viewModel.load()
        }
    }

    // MARK: Fitness ramp rate

    private var rampCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text("Fitness Ramp Rate").font(.headline)
            if viewModel.ramp.isEmpty {
                Text("Not enough training history for a ramp rate.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                if let delta = viewModel.currentRampDelta {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                        Text(delta, format: .number.precision(.fractionLength(1)).sign(strategy: .always()))
                            .font(.title2.bold().monospacedDigit())
                            .foregroundStyle(rampTint(delta))
                        Text("CTL/wk this week").font(.caption).foregroundStyle(.secondary)
                    }
                }
                RampRateChart(model: RampRateModel(weeks: viewModel.ramp, safeBand: RampRate.safeBand))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.l)
        .glassSurface(cornerRadius: Theme.Radius.l)
    }

    private func rampTint(_ delta: Double) -> Color {
        if RampRate.safeBand.contains(delta) { return Theme.Palette.success }
        return delta > RampRate.safeBand.upperBound ? Theme.Palette.warning : .secondary
    }

    // MARK: Sport share

    private var shareCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack {
                Text("Sport Share").font(.headline)
                Spacer()
                Picker("Metric", selection: $viewModel.shareMetric) {
                    ForEach(SportShareModel.Metric.allCases, id: \.self) { metric in
                        Text(metric.label).tag(metric)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if viewModel.share.weeks.allSatisfy(\.slices.isEmpty) {
                Text("No completed workouts in this range.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                SportShareChart(model: viewModel.share)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.l)
        .glassSurface(cornerRadius: Theme.Radius.l)
    }

    // MARK: Time in zone

    private var zonesCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text("Time in Zone").font(.headline)
            Picker("Sport", selection: $viewModel.zoneSport) {
                ForEach(SportFamily.triathlon) { family in
                    Text(family.displayName).tag(family)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if viewModel.zoneHR.isEmpty && viewModel.zonePower.isEmpty {
                Text("No heart-rate or power zone data recorded in this range.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                if !viewModel.zoneHR.isEmpty {
                    ZoneDistributionBar(model: ZoneDistributionModel(title: "Heart rate", seconds: viewModel.zoneHR))
                }
                if !viewModel.zonePower.isEmpty {
                    ZoneDistributionBar(model: ZoneDistributionModel(title: "Power", seconds: viewModel.zonePower))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.l)
        .glassSurface(cornerRadius: Theme.Radius.l)
    }

    // MARK: Power curve

    private var powerCurveCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text("Power Curve").font(.headline)
            if viewModel.powerCurve.isEmpty {
                Text("No cycling power data in this range.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                PowerCurveChart(model: PowerCurveModel(points: viewModel.powerCurve))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.l)
        .glassSurface(cornerRadius: Theme.Radius.l)
    }
}
