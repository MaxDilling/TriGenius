import SwiftUI

// MARK: - Statistics
//
// The analysis screen behind the dashboard's Fitness & Form section, grouped by
// the question it answers: Fitness & Form (am I fit and fresh), Training Mix (is
// my training balanced), Power Curve and Performance / Recovery (am I actually
// faster). One range control in the navigation bar governs every card below it. All charts
// render shared `Shared/Charts/` components from plain value models; missing data
// shows as absence, never a fabricated distribution.
//
// Layering follows the dashboard: a `SectionHeading` over title-less `glassCard`s,
// each naming itself with a small secondary caption where its siblings make that
// ambiguous.

struct StatisticsView: View {
    @State private var viewModel = StatisticsViewModel()

    var body: some View {
        ScrollView {
            // One GlassEffectContainer so the PMC panes and cards blend as a
            // single glass system instead of stacking independent glass layers.
            GlassEffectContainer(spacing: Theme.Spacing.l) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    if let pmc = viewModel.pmc {
                        section("Fitness & Form") {
                            PMCInsightsSection(result: pmc, days: viewModel.range.days)
                            rampCard
                        }
                    }

                    section("Training Mix") {
                        shareCard
                        zonesCard
                    }

                    section("Power Curve") { powerCurveCard }

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
        .toolbar {
            // The segmented control brings its own capsule; without this the toolbar
            // wraps it in a second one and the glass stacks.
            ToolbarItem(placement: .primaryAction) { rangePicker }
                .sharedBackgroundVisibility(.hidden)
        }
        .task { viewModel.load() }
        .onReceive(NotificationCenter.default.publisher(for: .trainingDataDidChange)) { _ in
            viewModel.load()
        }
    }

    /// The screen-wide range, in the navigation bar beside the title: it governs
    /// every card below, and those run far enough that a control scrolling out of
    /// reach is friction.
    private var rangePicker: some View {
        Picker("Range", selection: $viewModel.range) {
            ForEach(StatisticsViewModel.StatsRange.allCases) { range in
                Text(range.rawValue).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeading(title)
            content()
        }
    }

    /// A card's own name, for sections holding more than one — deliberately a
    /// small secondary line, never a second headline competing with the section.
    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    // MARK: Fitness ramp rate

    private var rampCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            caption("Ramp rate")
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
        .glassCard()
    }

    private func rampTint(_ delta: Double) -> Color {
        if RampRate.safeBand.contains(delta) { return Theme.Palette.success }
        return delta > RampRate.safeBand.upperBound ? Theme.Palette.warning : .secondary
    }

    // MARK: Sport share

    private var shareCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack {
                caption("Sport share")
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
        .glassCard()
    }

    // MARK: Time in zone

    private var zonesCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            caption("Time in zone")
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
        .glassCard()
    }

    // MARK: Power curve

    private var powerCurveCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            if viewModel.powerCurve.isEmpty {
                Text("No cycling power data in this range.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                PowerCurveChart(model: PowerCurveModel(points: viewModel.powerCurve))
            }
        }
        .glassCard()
    }
}
