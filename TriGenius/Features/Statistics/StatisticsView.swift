import SwiftUI

// MARK: - Statistics
//
// The analysis screen behind the dashboard's "All Stats" link, grouped by the
// question it answers: Fitness & Form (am I fit and fresh), Plan (am I on plan),
// Training Mix (is my training balanced), Power Curve and Performance / Recovery
// (am I actually faster). One range control in the navigation bar governs every card below it and
// opens each detail page at the same window. All charts render shared
// `Shared/Charts/` components from plain value models; missing data shows as
// absence, never a fabricated distribution.

struct StatisticsView: View {
    @State private var viewModel: StatisticsViewModel
    private var wide = WideLayout()

    init(weeklyStructure: WeeklyStructure) {
        _viewModel = State(initialValue: StatisticsViewModel(weeklyStructure: weeklyStructure))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                if let pmc = viewModel.pmc {
                    section("Fitness & Form") {
                        LazyVGrid(columns: SummaryTile.columns(wide: wide.isWide, fill: 4), spacing: Theme.Spacing.m) {
                            PMCStatTiles(result: pmc, range: viewModel.range)
                        }
                    }
                }

                let week = viewModel.week.flatMap { $0.visibleFamilies.isEmpty ? nil : $0 }
                if !viewModel.ctlTrend.actual.isEmpty || week != nil {
                    section("Plan") {
                        if !viewModel.ctlTrend.actual.isEmpty {
                            FitnessVsPlanCard(model: viewModel.ctlTrend)
                        }
                        if let week { WeeklyTargetCard(week: week) }
                    }
                }

                section("Training Mix") {
                    shareCard
                    zonesCard
                }

                powerCurveCard

                PerformanceMetricsSection(range: viewModel.range)
            }
            .padding(Theme.Spacing.l)
        }
        .background(Color.appBackground)
        .navigationTitle("Statistics")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .rangeToolbar($viewModel.range)
        .task { viewModel.load() }
        .onReceive(NotificationCenter.default.publisher(for: .trainingDataDidChange)) { _ in
            viewModel.load()
        }
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeading(title)
            content()
        }
    }

    // MARK: Sport share

    private var shareCard: some View {
        Group {
            if viewModel.share.weeks.allSatisfy(\.slices.isEmpty) {
                Text("No completed workouts in this range.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                SportShareChart(model: viewModel.share)
            }
        }
        .cardTitle("Sport share") {
            SegmentedPicker("Metric", selection: $viewModel.shareMetric,
                            options: SportShareModel.Metric.allCases, label: \.label)
        }
        .contentCard()
    }

    // MARK: Time in zone

    private var zonesCard: some View {
        Group {
            if ZoneDistributionStack.isEmpty(viewModel.zones) {
                Text("No zone data recorded in this range.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ZoneDistributionStack(seconds: viewModel.zones, bounds: viewModel.zoneBounds,
                                      boundsNote: "current thresholds")
            }
        }
        .cardTitle("Time in zone") {
            SegmentedPicker("Sport", selection: $viewModel.zoneSport,
                            options: SportFamily.triathlon, label: \.displayName)
        }
        .contentCard()
    }

    // MARK: Power curve

    private var powerCurveCard: some View {
        Group {
            if viewModel.powerCurve.isEmpty {
                Text("No cycling power data in this range.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                PowerCurveChart(model: PowerCurveModel(points: viewModel.powerCurve))
            }
        }
        .cardTitle("Power curve")
        .contentCard()
    }
}
