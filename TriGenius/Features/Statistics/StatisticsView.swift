import SwiftUI

// MARK: - Statistics
//
// The analysis screen behind the dashboard's "All Stats" link, grouped by the
// question it answers: Fitness & Form (am I fit and fresh), Plan (am I on plan),
// Training Mix (is my training balanced), Power Curve and Performance / Recovery
// (am I actually faster) — every card a `StatCard`. One range control beneath the
// navigation bar governs every card below it and opens each detail page at the
// same window. All charts render shared
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
                if viewModel.pmc != nil {
                    section("Fitness & Form") {
                        LazyVGrid(columns: SummaryTile.columns(wide: wide.isWide, fill: 4), spacing: Theme.Spacing.m) {
                            ForEach(StatCard.pmcTiles) { card($0) }
                        }
                    }
                }

                if !viewModel.ctlTrend.actual.isEmpty || viewModel.week?.visibleFamilies.isEmpty == false {
                    section("Plan") {
                        card(.fitnessPlan)
                        card(.weeklyTarget)
                    }
                }

                section("Training Mix") {
                    card(.sportShare)
                    card(.timeInZone)
                }

                card(.powerCurve)
                card(.routes)

                PerformanceMetricsSection(stats: viewModel)
            }
            .padding(Theme.Spacing.l)
        }
        .background(Color.appBackground)
        .navigationTitle("Statistics")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .rangeBar($viewModel.range)
        .task {
            viewModel.load()
            await viewModel.loadMetrics()
        }
        .onReceive(NotificationCenter.default.publisher(for: .trainingDataDidChange)) { _ in
            viewModel.load()
            Task { await viewModel.loadMetrics() }
        }
    }

    private func card(_ card: StatCard) -> some View {
        StatCardView(card: card, stats: viewModel)
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeading(title)
            content()
        }
    }
}
