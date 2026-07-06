import SwiftUI

// MARK: - Chart chat cards
//
// The coach's token-requested stat cards. Each card loads its data in `.task`
// through exactly the builders the Dashboard/Statistics screens use, so a
// chart in chat can never disagree with the same chart elsewhere.

// MARK: Metric trend

struct MetricChatCard: View {
    let key: String
    let months: Int

    @State private var points: [MetricPoint] = []
    @State private var loaded = false

    var body: some View {
        if let metric = PerformanceMetric.metric(for: key) {
            Group {
                if !points.isEmpty || !loaded {
                    MetricCard(metric: metric, points: points, windowMonths: months)
                        .coachAccent(cornerRadius: Theme.Radius.l)
                } else {
                    ChartChatCard(title: metric.title) {
                        NoChartData(text: "No \(metric.title) data yet.")
                    }
                }
            }
            .task {
                points = TrainingDataStore.shared.metricHistory(key)
                loaded = true
            }
        }
    }
}

// MARK: CTL trend (fitness vs ATP plan)

struct CTLTrendChatCard: View {
    @State private var model: CTLTrendModel?

    var body: some View {
        ChartChatCard(title: "Fitness vs plan") {
            if let model, !(model.actual.isEmpty && model.planned.isEmpty) {
                CTLTrendChart(model: model)
            } else if model != nil {
                NoChartData(text: "No fitness data yet.")
            } else {
                ChartLoading()
            }
        }
        .task {
            model = CTLTrendModel.around(points: PMCEngine.current().points,
                                         planCurve: ATPEngine.current()?.planCurve ?? [])
        }
    }
}

// MARK: Ramp rate

struct RampRateChatCard: View {
    let weeks: Int

    @State private var model: RampRateModel?

    var body: some View {
        ChartChatCard(title: "Weekly fitness change") {
            if let model, !model.weeks.isEmpty {
                RampRateChart(model: model)
            } else if model != nil {
                NoChartData(text: "No fitness data yet.")
            } else {
                ChartLoading()
            }
        }
        .task {
            model = RampRateModel(
                weeks: RampRate.weeklySeries(points: PMCEngine.current().points, weeks: weeks),
                safeBand: RampRate.safeBand
            )
        }
    }
}

// MARK: Sport share

struct SportShareChatCard: View {
    let metric: SportShareModel.Metric
    let weeks: Int

    @State private var model: SportShareModel?

    var body: some View {
        ChartChatCard(title: "Sport distribution") {
            if let model, !model.totals.isEmpty {
                SportShareChart(model: model)
            } else if model != nil {
                NoChartData(text: "No workouts in this period.")
            } else {
                ChartLoading()
            }
        }
        .task {
            let now = Date()
            guard let start = TrainingVolume.recentWeekStarts(weeks: weeks, today: now).first else { return }
            model = SportShareModel.make(records: TrainingDataStore.shared.activities(from: start, to: now),
                                         weeks: weeks, metric: metric)
        }
    }
}

// MARK: Time in zone

struct ZonesChatCard: View {
    let sport: SportFamily
    let weeks: Int

    @State private var hr: [Double] = []
    @State private var power: [Double] = []
    @State private var loaded = false

    var body: some View {
        ChartChatCard(title: "\(sport.displayName) time in zone") {
            if hr.contains(where: { $0 > 0 }) {
                ZoneDistributionBar(model: ZoneDistributionModel(title: "Heart rate", seconds: hr))
            }
            if power.contains(where: { $0 > 0 }) {
                ZoneDistributionBar(model: ZoneDistributionModel(title: "Power", seconds: power))
            }
            if loaded && !hr.contains(where: { $0 > 0 }) && !power.contains(where: { $0 > 0 }) {
                NoChartData(text: "No zone data in this period.")
            }
        }
        .task {
            let now = Date()
            guard let start = TrainingVolume.recentWeekStarts(weeks: weeks, today: now).first else { return }
            let records = TrainingDataStore.shared.activities(from: start, to: now)
                .filter { SportFamily(sportKey: $0.sport) == sport }
            hr = ZoneDistribution.aggregate(records: records, source: .heartRate)
            power = ZoneDistribution.aggregate(records: records, source: .power)
            loaded = true
        }
    }
}

// MARK: Shared chrome

private struct ChartChatCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .coachAccent()
    }
}

private struct NoChartData: View {
    let text: String
    var body: some View {
        Text(text).font(.subheadline).foregroundStyle(.secondary)
    }
}

private struct ChartLoading: View {
    var body: some View {
        ProgressView().frame(maxWidth: .infinity, minHeight: 120)
    }
}
