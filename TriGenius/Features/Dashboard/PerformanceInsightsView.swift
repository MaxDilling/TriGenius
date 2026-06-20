import SwiftUI
import Charts

// MARK: - Performance Insights (PMC detail)
//
// The screen behind the dashboard's "Details" link. Shows the CTL / ATL / TSB
// summary plus the full Performance Management Chart over a selectable range:
// CTL (Fitness) and ATL (Fatigue) as lines, TSB (Form) as signed bars
// (green = positive/fresh, orange = negative/fatigued).

struct PerformanceInsightsView: View {
    let result: PMCResult

    @State private var range: PMCRange = .ninety

    private var points: [PMCPoint] {
        guard let last = result.points.last else { return [] }
        let cal = Calendar.current
        guard let cutoff = cal.date(byAdding: .day, value: -range.days, to: last.date) else {
            return result.points
        }
        return result.points.filter { $0.date >= cutoff }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let s = result.snapshot {
                    HStack(spacing: 10) {
                        statCard("Fitness", dot: .blue, value: Int(s.ctl.rounded()),
                                 delta: delta { $0.ctl })
                        statCard("Fatigue", dot: .pink, value: Int(s.atl.rounded()),
                                 delta: delta { $0.atl })
                        statCard("Form", dot: .orange, value: Int(s.tsb.rounded()),
                                 delta: delta { $0.tsb })
                    }
                }

                chartCard
            }
            .padding()
        }
        .navigationTitle("Performance Insights")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: Chart

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("PMC Chart").font(.headline)
                Spacer()
                Picker("Range", selection: $range) {
                    ForEach(PMCRange.allCases) { r in Text(r.label).tag(r) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }

            Chart {
                ForEach(points) { p in
                    BarMark(
                        x: .value("Date", p.date),
                        y: .value("Form", p.tsb)
                    )
                    .foregroundStyle(p.tsb >= 0 ? Color.green.opacity(0.6) : Color.orange.opacity(0.6))
                }
                ForEach(points) { p in
                    LineMark(
                        x: .value("Date", p.date),
                        y: .value("Fitness", p.ctl),
                        series: .value("Series", "Fitness")
                    )
                    .foregroundStyle(.blue)
                    LineMark(
                        x: .value("Date", p.date),
                        y: .value("Fatigue", p.atl),
                        series: .value("Series", "Fatigue")
                    )
                    .foregroundStyle(.pink)
                }
            }
            .frame(height: 260)
            .chartLegend(.hidden)

            HStack(spacing: 16) {
                legend(.blue, "Fitness (CTL)")
                legend(.pink, "Fatigue (ATL)")
                legend(.green, "Form (TSB)")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.05)))
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
        }
    }

    private func statCard(_ title: String, dot: Color, value: Int, delta: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(value)").font(.title.bold())
                if delta != 0 {
                    HStack(spacing: 1) {
                        Image(systemName: delta > 0 ? "arrow.up" : "arrow.down")
                        Text("\(abs(delta))")
                    }
                    .font(.caption2).foregroundStyle(dot)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.05)))
    }

    private func delta(_ metric: (PMCPoint) -> Double) -> Int {
        guard let now = result.points.last.map(metric),
              let then = result.value(daysAgo: 7, metric) else { return 0 }
        return Int((now - then).rounded())
    }
}

// MARK: - Range

enum PMCRange: String, CaseIterable, Identifiable {
    case thirty
    case ninety
    case year

    var id: String { rawValue }
    var label: String {
        switch self {
        case .thirty: return "30D"
        case .ninety: return "90D"
        case .year:   return "1Y"
        }
    }
    var days: Int {
        switch self {
        case .thirty: return 30
        case .ninety: return 90
        case .year:   return 365
        }
    }
}
