import SwiftUI
import Charts

// MARK: - Dashboard View
//
// GOAL.md: visual weekly dashboard — PMC (CTL/ATL/TSB), per-discipline volume
// (TSS + distance, this week + 6-week trend), and the recent-workout list
// (tappable into a detail view). Reads from the local DB via DashboardViewModel.

struct DashboardView: View {
    let dataSource: DataSource
    @State private var viewModel = DashboardViewModel()
    @State private var volumeMetric: VolumeMetric = .tss

    var body: some View {
        List {
            if viewModel.isLoading && viewModel.recentWorkouts.isEmpty {
                Section {
                    HStack { Spacer(); ProgressView("Loading…"); Spacer() }
                        .padding()
                }
            } else {
                pmcSection
                volumeSection
                workoutsSection
                healthSection
            }
        }
        .navigationTitle("Dashboard")
        .refreshable { await viewModel.refresh(dataSource: dataSource) }
        .task { await viewModel.loadInitialIfNeeded(dataSource: dataSource) }
    }

    // MARK: PMC

    @ViewBuilder
    private var pmcSection: some View {
        if let snapshot = viewModel.pmc?.snapshot {
            Section("Fitness & Form (PMC)") {
                HStack(spacing: 12) {
                    pmcStat("Fitness", value: snapshot.ctl, caption: "CTL", color: .blue)
                    pmcStat("Fatigue", value: snapshot.atl, caption: "ATL", color: .orange)
                    pmcStat("Form", value: snapshot.tsb, caption: "TSB", color: snapshot.tsb < 0 ? .red : .green)
                }
                .padding(.vertical, 4)

                if let points = viewModel.pmc?.points, points.count > 1 {
                    Chart {
                        ForEach(points) { p in
                            LineMark(x: .value("Date", p.date), y: .value("CTL", p.ctl), series: .value("Series", "Fitness"))
                                .foregroundStyle(Color.blue)
                            LineMark(x: .value("Date", p.date), y: .value("ATL", p.atl), series: .value("Series", "Fatigue"))
                                .foregroundStyle(Color.orange)
                        }
                    }
                    .chartForegroundStyleScale(["Fitness": Color.blue, "Fatigue": Color.orange])
                    .chartYScale(domain: .automatic(includesZero: true))
                    .frame(height: 160)
                    .padding(.top, 4)
                }
            }
        }
    }

    private func pmcStat(_ title: String, value: Double, caption: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(Int(value.rounded()))")
                .font(.title2).fontWeight(.semibold)
                .foregroundStyle(color)
            Text(title).font(.caption)
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Volume per discipline

    private var volumeSection: some View {
        Section {
            Picker("Metric", selection: $volumeMetric) {
                ForEach(VolumeMetric.allCases) { m in Text(m.label).tag(m) }
            }
            .pickerStyle(.segmented)

            // This-week summary per discipline.
            if let week = viewModel.currentWeek {
                ForEach(SportFamily.triathlon) { family in
                    let t = week.totals(for: family)
                    HStack {
                        Label(family.displayName, systemImage: family.icon)
                            .foregroundStyle(family.color)
                        Spacer()
                        Text(volumeMetric.format(t))
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // 6-week trend, grouped bars per discipline.
            if viewModel.weeklyBuckets.contains(where: { !$0.totals.isEmpty }) {
                Chart {
                    ForEach(viewModel.weeklyBuckets) { bucket in
                        ForEach(SportFamily.triathlon) { family in
                            BarMark(
                                x: .value("Week", bucket.weekStart, unit: .weekOfYear),
                                y: .value(volumeMetric.label, volumeMetric.value(bucket.totals(for: family)))
                            )
                            .foregroundStyle(by: .value("Sport", family.displayName))
                            .position(by: .value("Sport", family.displayName))
                        }
                    }
                }
                .chartForegroundStyleScale([
                    SportFamily.swim.displayName: SportFamily.swim.color,
                    SportFamily.bike.displayName: SportFamily.bike.color,
                    SportFamily.run.displayName: SportFamily.run.color
                ])
                .frame(height: 180)
                .padding(.top, 4)
            }
        } header: {
            Text("Volume per discipline")
        } footer: {
            Text("This week and the previous 5 weeks. TSS is currently sourced from Garmin; HealthKit activities have no TSS.")
        }
    }

    // MARK: Recent workouts

    @ViewBuilder
    private var workoutsSection: some View {
        if !viewModel.recentWorkouts.isEmpty {
            Section("Recent workouts") {
                ForEach(viewModel.recentWorkouts) { record in
                    NavigationLink {
                        TrainingDetailView(record: record)
                    } label: {
                        ActivityRow(record: record)
                    }
                }
            }
        }
    }

    // MARK: HealthKit recovery metrics (optional)

    @ViewBuilder
    private var healthSection: some View {
        if let metrics = viewModel.healthMetrics {
            Section("Recovery (last 7 days)") {
                metricRow("Steps (daily avg)", value: "\(Int(metrics.dailySteps))", icon: "figure.walk", color: .green)
                if let hr = metrics.averageHRbpm {
                    metricRow("Heart rate (avg)", value: "\(Int(hr)) bpm", icon: "heart", color: .red)
                }
                if let hrv = metrics.latestHRVms {
                    metricRow("HRV (latest)", value: "\(Int(hrv)) ms", icon: "waveform.path.ecg", color: .blue)
                }
                metricRow("Sleep (daily avg)", value: String(format: "%.1f h", metrics.avgSleepHours), icon: "moon.fill", color: .indigo)
                metricRow("Active energy (daily avg)", value: "\(Int(metrics.avgActiveEnergyKcal)) kcal", icon: "flame.fill", color: .orange)
            }
        }
    }

    private func metricRow(_ label: String, value: String, icon: String, color: Color) -> some View {
        HStack {
            Label(label, systemImage: icon).foregroundStyle(color)
            Spacer()
            Text(value).foregroundStyle(.secondary).fontWeight(.medium)
        }
    }
}

// MARK: - Volume Metric

enum VolumeMetric: String, CaseIterable, Identifiable {
    case tss
    case distance

    var id: String { rawValue }
    var label: String { self == .tss ? "TSS" : "Distance" }

    func value(_ totals: VolumeTotals) -> Double {
        self == .tss ? totals.tss : totals.distanceKm
    }

    func format(_ totals: VolumeTotals) -> String {
        switch self {
        case .tss:
            return totals.tss > 0 ? "\(Int(totals.tss.rounded())) TSS" : "—"
        case .distance:
            return totals.distanceKm > 0 ? String(format: "%.1f km", totals.distanceKm) : "—"
        }
    }
}

// MARK: - Activity Row

private struct ActivityRow: View {
    let record: ActivityRecord

    var body: some View {
        let family = SportFamily(sportKey: record.sport)
        HStack(spacing: 12) {
            Image(systemName: family.icon)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(family.color.gradient)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(record.name).font(.headline).lineLimit(1)
                Text(record.date, style: .date)
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(record.durationMinutes)) min")
                    .font(.subheadline).fontWeight(.medium)
                if let tss = record.tss {
                    Text("\(Int(tss.rounded())) TSS")
                        .font(.caption).foregroundStyle(.secondary)
                } else if record.distanceKm > 0 {
                    Text(String(format: "%.1f km", record.distanceKm))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - SportFamily presentation

extension SportFamily {
    var icon: String {
        switch self {
        case .swim: return "figure.pool.swim"
        case .bike: return "figure.outdoor.cycle"
        case .run: return "figure.run"
        case .strength: return "dumbbell"
        case .other: return "figure.mixed.cardio"
        }
    }

    var color: Color {
        switch self {
        case .swim: return .cyan
        case .bike: return .blue
        case .run: return .orange
        case .strength: return .gray
        case .other: return .green
        }
    }
}
