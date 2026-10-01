import SwiftUI

// MARK: - Stat card
//
// One card of the Statistics screen, by a stable id. Statistics shows them all; the
// dashboard's Pinned section shows the athlete's ordered pick
// (`AppSettings.pinnedCards`). Both render through `StatCardView` from a
// `StatisticsViewModel`, so a card reads the same on either screen.

struct StatCard: Hashable, Identifiable {
    let id: String

    static let ctl = StatCard(id: "ctl")
    static let atl = StatCard(id: "atl")
    static let tsb = StatCard(id: "tsb")
    static let ramp = StatCard(id: "ramp")
    static let fitnessPlan = StatCard(id: "fitness_plan")
    static let weeklyTarget = StatCard(id: "weekly_target")
    static let sportShare = StatCard(id: "sport_share")
    static let timeInZone = StatCard(id: "time_in_zone")
    static let powerCurve = StatCard(id: "power_curve")
    static let routes = StatCard(id: "routes")
    static func metric(_ metric: PerformanceMetric) -> StatCard { StatCard(id: metricPrefix + metric.key) }

    private static let metricPrefix = "metric:"
    private static let fixedTitles: [StatCard: String] = [
        .ctl: "Fitness (CTL)", .atl: "Fatigue (ATL)", .tsb: "Form (TSB)", .ramp: "Ramp rate",
        .fitnessPlan: FitnessVsPlanCard.title, .weeklyTarget: "Weekly Target",
        .sportShare: "Sport share", .timeInZone: "Time in zone", .powerCurve: "Power curve",
        .routes: "Route heatmap",
    ]

    static let pmcTiles: [StatCard] = [.ctl, .atl, .tsb, .ramp]
    /// The cards built from the range's workouts, which the others never fetch.
    static let workoutCards: [StatCard] = [.sportShare, .timeInZone, .powerCurve]
    static let defaultPinned = pmcTiles + [.fitnessPlan, .weeklyTarget]

    /// Every card, as the layout editor lists them.
    static let groups: [(title: String, cards: [StatCard])] = [
        ("Fitness & Form", pmcTiles),
        ("Plan", [.fitnessPlan, .weeklyTarget]),
        ("Training Mix", workoutCards + [.routes]),
        ("Performance", PerformanceMetric.all.filter { $0.group == .performance }.map { .metric($0) }),
        ("Recovery", PerformanceMetric.all.filter { $0.group == .recovery }.map { .metric($0) }),
    ]

    /// A stored id; nil when this build has no such card.
    init?(stored id: String) {
        self.id = id
        guard Self.fixedTitles[self] != nil || metric != nil else { return nil }
    }

    private init(id: String) { self.id = id }

    var metric: PerformanceMetric? {
        id.hasPrefix(Self.metricPrefix) ? PerformanceMetric.metric(for: String(id.dropFirst(Self.metricPrefix.count))) : nil
    }

    var title: String { Self.fixedTitles[self] ?? metric?.title ?? id }

    /// A `SummaryTile`, which flows in a grid; the rest span the full width.
    var isTile: Bool { metric != nil || Self.pmcTiles.contains(self) }

    /// The cards as laid out: consecutive tiles share one grid, a full-width card
    /// stands alone.
    static func rows(_ cards: [StatCard]) -> [[StatCard]] {
        cards.reduce(into: []) { rows, card in
            if card.isTile, rows.last?.last?.isTile == true {
                rows[rows.count - 1].append(card)
            } else {
                rows.append([card])
            }
        }
    }
}

// MARK: - View

/// Any `StatCard` from the view model's state; nothing while the card has no data to
/// show. A long press (right click) pins it to the dashboard or unpins it.
struct StatCardView: View {
    let card: StatCard
    @Bindable var stats: StatisticsViewModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        content
            #if os(iOS)
            .contentShape(.contextMenuPreview, .rect(cornerRadius: Theme.Radius.l, style: .continuous))
            #endif
            .contextMenu {
                let pinned = settings.pinnedCards.contains(card)
                Button(pinned ? "Unpin from Dashboard" : "Pin to Dashboard",
                       systemImage: pinned ? "pin.slash" : "pin") { settings.togglePin(card) }
            }
    }

    @ViewBuilder private var content: some View {
        switch card {
        case .ctl, .atl, .tsb, .ramp:
            if let pmc = stats.pmc {
                PMCTile(card: card, result: pmc, range: stats.range, maxRampRate: stats.plan?.maxRampRate)
            }
        case .fitnessPlan:
            if !stats.ctlTrend.actual.isEmpty { FitnessVsPlanCard(model: stats.ctlTrend) }
        case .weeklyTarget:
            if let week = stats.week, !week.visibleFamilies.isEmpty { WeeklyTargetCard(week: week) }
        case .sportShare: shareCard
        case .timeInZone: zonesCard
        case .powerCurve: powerCurveCard
        case .routes: routesCard
        default:
            if let metric = card.metric, let points = stats.histories[metric.key] {
                MetricCard(metric: metric, points: points, range: stats.range)
            }
        }
    }

    private var shareCard: some View {
        Group {
            if stats.share.weeks.allSatisfy(\.slices.isEmpty) {
                Text("No completed workouts in this range.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                SportShareChart(model: stats.share)
            }
        }
        .cardTitle(card.title) {
            SegmentedPicker("Metric", selection: $stats.shareMetric,
                            options: SportShareModel.Metric.allCases, label: \.label)
        }
        .contentCard()
    }

    private var zonesCard: some View {
        Group {
            if ZoneDistributionStack.isEmpty(stats.zones) {
                Text("No zone data recorded in this range.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ZoneDistributionStack(seconds: stats.zones, bounds: stats.zoneBounds,
                                      boundsNote: "current thresholds")
            }
        }
        .cardTitle(card.title) {
            SegmentedPicker("Sport", selection: $stats.zoneSport,
                            options: SportFamily.triathlon, label: \.displayName)
        }
        .contentCard()
    }

    private var powerCurveCard: some View {
        Group {
            if stats.powerCurve.isEmpty {
                Text("No cycling power data in this range.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                PowerCurveChart(model: PowerCurveModel(points: stats.powerCurve))
            }
        }
        .cardTitle(card.title)
        .contentCard()
    }

    private var routesCard: some View {
        NavigationLink { RouteHeatDetailView(range: stats.range) } label: {
            Group {
                if let routes = stats.routes, routes.isEmpty {
                    Text("No GPS routes in this range.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ZStack {
                        if let routes = stats.routes { RouteHeatMap(lines: routes) } else { ProgressView() }
                    }
                    .frame(maxWidth: .infinity, minHeight: 240, maxHeight: 240)
                    .clipShape(.rect(cornerRadius: Theme.Radius.m, style: .continuous))
                }
            }
            .cardTitle(card.title) { Chevron() }
            .contentCard()
        }
        .buttonStyle(.plain)
    }
}
