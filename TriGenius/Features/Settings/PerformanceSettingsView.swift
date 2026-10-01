import SwiftUI

// MARK: - Performance page

/// Settings → Performance: every physiological marker at its current value, one row
/// each, marked with where the number comes from. A row opens the marker's detail
/// page, which carries its history, its manual entries and — where the app can work
/// the value out itself — the calculation switch (`MetricCalculationSection`).
struct PerformanceSettingsView: View {
    @ObservedObject var settings: AppSettings

    @State private var histories: [String: [MetricPoint]] = [:]
    @State private var handEntered: Set<String> = []
    @State private var historyStale = TrainingDataStore.historyNeedsRescore

    /// By discipline, each led by the value its zones and training load are scored against.
    private static let groups: [(title: String, keys: [String])] = [
        ("Cycling", ["cycling_ftp", "critical_power", "w_prime", "vo2max_cycling", "lactate_threshold_hr_cycling"]),
        ("Running", ["lactate_threshold_speed", "lactate_threshold_hr", "vo2max_running", "running_ftp"]),
        ("Swimming", ["swim_css_speed"]),
        ("General", ["max_hr", "weight_kg"]),
    ]

    var body: some View {
        List {
            if historyStale { recompute }
            ForEach(Self.groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.keys.compactMap(PerformanceMetric.metric(for:))) { row($0) }
                }
            }
            Section {} footer: {
                Text("\(Image(systemName: MetricSource.calculated(nil).icon)) calculated from your training · \(Image(systemName: MetricSource.synced.icon)) synced from \(settings.metricsSource.displayName) · \(Image(systemName: MetricSource.entered.icon)) entered by you. Open a value to see its history, enter one yourself, or switch its calculation on — a calculated value replaces the synced one.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !historyStale { recompute }
        }
        .navigationTitle("Performance")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .trainingDataDidChange)) { _ in
            Task { await load() }
        }
    }

    /// Leads the page while the stored load disagrees with the values below it.
    private var recompute: some View {
        Section { HistoryRecompute(isStale: historyStale) }
    }

    private func row(_ metric: PerformanceMetric) -> some View {
        let points = histories[metric.key] ?? []
        return NavigationLink {
            MetricDetailView(metric: metric, points: points)
        } label: {
            LabeledContent(metric.title) {
                HStack(spacing: Theme.Spacing.s) {
                    Text(points.last.map { "\(metric.display($0)) \(metric.unit)" } ?? "—").monospacedDigit()
                    if let source = MetricSource(latest: points.last, handEntered: handEntered.contains(metric.key)) {
                        Image(systemName: source.icon).font(.footnote).foregroundStyle(source.tint)
                    }
                }
                .lineLimit(1)
            }
        }
    }

    private func load() async {
        let store = TrainingDataStore.shared
        handEntered = store.latestSnapshot().handEnteredKeys
        historyStale = TrainingDataStore.historyNeedsRescore
        for key in Self.groups.flatMap(\.keys) { histories[key] = await store.metricHistory(key) }
    }
}

// MARK: - Value source

/// Where a marker's current value comes from — the distinction the "~" alone cannot
/// carry, since a marker shows a value whether or not its calculation is running.
enum MetricSource {
    case calculated(EstimateConfidence?), entered, synced

    init?(latest: MetricPoint?, handEntered: Bool) {
        guard let latest else { return nil }
        self = latest.isEstimated ? .calculated(latest.confidence) : handEntered ? .entered : .synced
    }

    var icon: String {
        switch self {
        case .calculated: "wand.and.sparkles"
        case .entered: "hand.point.up.left"
        case .synced: "arrow.down.circle"
        }
    }

    /// A calculation resting on thin or old evidence stands out from an anchored one.
    var tint: Color {
        switch self {
        case .calculated(let confidence): confidence == nil || confidence == .anchored ? .accentColor : Theme.Palette.warning
        case .entered, .synced: .secondary
        }
    }
}

// MARK: - Calculations

/// One marker the app can work out itself: its opt-in, and what the result rests on.
struct MetricCalculation {
    let setting: ReferenceWritableKeyPath<AppSettings, Bool>
    let method: String
    let needs: String
    /// The 80 % range around the value, where the estimate reports one.
    var range: KeyPath<PerformanceSnapshot, ClosedRange<Double>?>?

    static func calculation(for metricKey: String) -> MetricCalculation? { all[metricKey] }

    private static let ridesWithPower = "max HR, resting HR, weight, rides with power"

    private static let all: [String: MetricCalculation] = [
        "vo2max_cycling": .init(
            setting: \.estimateVO2maxFromRides,
            method: "From your ordinary rides: the power you hold in sustained efforts is converted to oxygen uptake and scaled up by how far your heart rate stayed below its maximum. The result is smoothed across rides, so one hot day or one bad heart-rate reading barely moves it. No all-out test needed.",
            needs: ridesWithPower),
        "critical_power": .init(
            setting: \.estimateCPFromRides,
            method: "Starts from the power your aerobic system can sustain: the app works out your cycling VO₂max from your rides, takes 82.1 % of that oxygen uptake and converts it to watts (22 % cycling efficiency). It is raised whenever a ride shows you held more. Calculated together with W′, so the two always fit the same rides.",
            needs: ridesWithPower, range: \.criticalPowerRange),
        "w_prime": .init(
            setting: \.estimateCPFromRides,
            method: "The most work above critical power any of your rides shows you spent in one go. Calculated together with critical power, so the two always fit the same rides.",
            needs: ridesWithPower, range: \.wPrimeRange),
        "cycling_ftp": .init(
            setting: \.estimateFTPFromCP,
            method: "Your critical power × 0.93. FTP is calculated from critical power alone, so the two always fit each other.",
            needs: ridesWithPower),
        "lactate_threshold_hr_cycling": .init(
            setting: \.estimateCyclingLTHRFromRides,
            method: "Your steady 20-minute heart rate in rides near your best 20-minute power. Rides are picked by power, not by heart rate, so a faulty heart-rate reading on an easy ride cannot count as a threshold effort.",
            needs: "max HR, rides with power"),
        "vo2max_running": .init(
            setting: \.estimateRunningVO2maxFromRuns,
            method: "Your maximal aerobic speed, worked out from heart rate and pace on ordinary runs, converted to oxygen uptake. Threshold pace uses the same speed, so the two always fit each other.",
            needs: "max HR, resting HR, runs"),
        "lactate_threshold_hr": .init(
            setting: \.estimateLTHRFromHRMax,
            method: "Your steady 20-minute heart rate in your hardest runs, with recent runs counting more.",
            needs: "max HR, steady 20-minute runs"),
        "lactate_threshold_speed": .init(
            setting: \.estimateLTPaceFromRuns,
            method: "Your maximal aerobic speed, worked out from heart rate and pace on ordinary runs, times the share of it you hold at threshold (the running threshold factor below).",
            needs: "max HR, resting HR, threshold HR, runs"),
    ]
}

/// The detail page's block for a marker the app can calculate: the switch, where the
/// current value comes from and what the calculation rests on. Renders nothing for a
/// marker that only ever holds readings.
struct MetricCalculationSection: View {
    let metric: PerformanceMetric
    let latest: MetricPoint?

    @EnvironmentObject private var settings: AppSettings
    @State private var snapshot = PerformanceSnapshot()
    @State private var historyStale = TrainingDataStore.historyNeedsRescore

    var body: some View {
        if let calculation = MetricCalculation.calculation(for: metric.key) {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                SectionHeading("How it's calculated")
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    Toggle("Calculate automatically", isOn: $settings[dynamicMember: calculation.setting])
                    Divider()
                    source(calculationOn: settings[keyPath: calculation.setting])
                    Text(calculation.method).font(.caption).foregroundStyle(.secondary)
                    if latest?.isEstimated == true, let range = calculation.range.flatMap({ snapshot[keyPath: $0] }) {
                        Text("80 % range: \(metric.format(range.lowerBound))–\(metric.format(range.upperBound)) \(metric.unit)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Needs: \(calculation.needs)").font(.caption2).foregroundStyle(.tertiary)
                }
                .contentCard()
                if historyStale {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) { HistoryRecompute(isStale: true) }
                        .contentCard()
                }
                if metric.key == "lactate_threshold_speed" {
                    RunningThresholdFactor(derived: snapshot.ltPaceFractionUsed)
                }
            }
            .task { reload() }
            .onReceive(NotificationCenter.default.publisher(for: .trainingDataDidChange)) { _ in reload() }
        }
    }

    private func reload() {
        snapshot = TrainingDataStore.shared.latestSnapshot()
        historyStale = TrainingDataStore.historyNeedsRescore
    }

    @ViewBuilder private func source(calculationOn: Bool) -> some View {
        let source = MetricSource(latest: latest, handEntered: snapshot.handEnteredKeys.contains(metric.key))
        let text: String? = switch source {
        case .calculated(let confidence):
            ["Calculated here", confidence.map(confidenceText)].compactMap { $0 }.joined(separator: " · ")
        case .entered:
            "Entered by you" + (calculationOn ? " — until newer training gives a calculated value" : "")
        case .synced:
            "From \(settings.metricsSource.displayName)" + (calculationOn ? " — not enough data to calculate it yet" : "")
        case nil:
            calculationOn ? "Not enough data yet" : nil
        }
        if let text {
            Label(text, systemImage: source?.icon ?? "minus.circle")
                .font(.caption).foregroundStyle(source?.tint ?? .secondary)
        }
    }

    private func confidenceText(_ c: EstimateConfidence) -> String {
        switch c {
        case .anchored: "backed by several recent efforts"
        case .thin: "based on few efforts so far, so one session can still move it"
        case .stale: "based on older efforts — no recent session qualified"
        case .rough: "no qualifying effort yet — based on a typical value, not on your own data"
        }
    }
}

// MARK: - Running threshold factor

private struct RunningThresholdFactor: View {
    /// What the resolver derived, and the starting point for a manual value.
    let derived: Double?

    @EnvironmentObject private var settings: AppSettings
    /// The factor slider's working value. The slider is bound to this, not to the
    /// setting: the setting is committed on release, and a store notification
    /// landing mid-drag must not yank the thumb back.
    @State private var draft = 0.0
    @State private var isDragging = false

    private var isManual: Bool { settings.ltPaceFractionOfMAS > 0 }

    var body: some View {
        SectionHeading("Running threshold factor")
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Toggle("Set it myself", isOn: Binding(
                get: { isManual },
                // Starts from the derived value rather than a slider endpoint, so
                // switching this on does not silently move the answer.
                set: { settings.ltPaceFractionOfMAS = $0 ? (derived ?? 0.80) : 0 }))
            Divider()
            HStack {
                Text(isManual ? "Your value" : "Derived from your threshold HR")
                    .foregroundStyle(.secondary)
                Spacer()
                // The draft, so the number tracks the thumb rather than the last
                // committed value.
                Text((isManual ? draft : derived).map { String(format: "%.3f", $0) } ?? "—")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(isManual || derived != nil ? .primary : .tertiary)
            }
            if isManual {
                // Dragged against a local draft and committed on release. The
                // setting is a read-time input to every threshold, so writing it
                // re-resolves the whole history — 200 times across one drag, on the
                // main actor, which is a drag the slider cannot survive. Intermediate
                // positions are not decisions.
                Slider(value: $draft, in: 0.70 ... 0.90, step: 0.001) { editing in
                    isDragging = editing
                    if !editing { settings.ltPaceFractionOfMAS = draft }
                }
            }
        }
        .contentCard()
        .onChange(of: settings.ltPaceFractionOfMAS, initial: true) { _, value in
            if !isDragging { draft = value }
        }
        Text("The share of your maximal aerobic speed you hold at threshold. It differs between athletes by enough to shift threshold pace several seconds per kilometre, so the app derives it from your threshold heart rate. Set it yourself only after a 30-minute threshold test: use the share of your heart-rate reserve you held over its last 20 minutes.")
            .font(.footnote).foregroundStyle(.secondary)
    }
}

// MARK: - Recompute history

/// "Recompute history" with its progress and, while the stored load still rests on
/// thresholds that have since changed, the notice saying so — next to the switch
/// that caused it, or the alternative is a number and a load that quietly disagree.
struct HistoryRecompute: View {
    let isStale: Bool
    @State private var progress: (done: Int, total: Int)?

    var body: some View {
        if isStale {
            Label("Training load still uses the old thresholds", systemImage: "clock.badge.exclamationmark")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.Palette.warning)
        }
        Text("Stored workouts keep the training load and zones they were scored with. Recompute to apply your current thresholds — safe to run at any time.")
            .font(.footnote).foregroundStyle(.secondary)
        if let progress {
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))) {
                Text("Recomputing \(progress.done) of \(progress.total)…")
            }
        } else {
            Button {
                Task {
                    progress = (0, 0)
                    await TrainingDataStore.shared.rescoreAllActivities { progress = ($0, $1) }
                    progress = nil
                }
            } label: {
                Label("Recompute history", systemImage: "arrow.triangle.2.circlepath")
            }
        }
    }
}
