import SwiftUI

// MARK: - Automatically calculated thresholds

/// What the app can work out for itself, what it currently shows instead, and how much
/// each answer is worth.
///
/// The screen has to separate two things that look identical once they are numbers: a
/// value the watch reported and a value calculated here. Only the second carries a
/// confidence, and only the second changes when a switch is flipped — so each row says
/// where its number came from before it says anything else.
struct AutomaticCalculationView: View {
    @ObservedObject var settings: AppSettings
    @State private var snapshot = PerformanceSnapshot()
    /// Whether the stored training load still carries the thresholds from before the
    /// last switch was flipped. Read alongside the snapshot, since the same change
    /// moves both.
    @State private var historyStale = false
    /// The slider's own value while it is being dragged, and whether it is — a sync
    /// landing mid-drag must not yank the thumb back. See the slider itself.
    @State private var fractionDraft = 0.0
    @State private var isDragging = false

    private struct Row: Identifiable {
        /// The stored marker this value belongs to, so the row can open its chart.
        let metricKey: String
        let title: String
        let value: String?
        let calculatedHere: Bool
        /// The opt-in itself, so "Current values" and "What to calculate" are two
        /// renderings of one list and cannot fall into different orders.
        let calculation: Binding<Bool>
        let confidence: EstimateConfidence?
        let method: String
        let needs: String

        var calculationOn: Bool { calculation.wrappedValue }
        var id: String { metricKey }
    }

    /// The markers in the order both sections show them: by discipline, and inside a
    /// discipline from the aerobic ceiling down to what it is spent at.
    private var rows: [Row] { cyclingRows + runningRows }

    private var cyclingRows: [Row] {
        [
            Row(metricKey: "vo2max_cycling", title: "Cycling VO₂max",
                value: snapshot.vo2maxCycling.map { String(format: "%.1f ml/kg/min", $0) },
                calculatedHere: snapshot.vo2maxCyclingIsEstimated,
                calculation: $settings.estimateVO2maxFromRides,
                confidence: nil,
                method: "Reconstructed from ordinary rides: each sustained effort's oxygen cost, scaled up by the heart-rate reserve you left unused. No maximal test needed.",
                needs: "max HR, resting HR, weight, rides with power"),
            Row(metricKey: "cycling_ftp", title: "Cycling FTP",
                value: snapshot.cyclingFTP.map { "\($0) W" },
                calculatedHere: snapshot.cyclingFTPIsEstimated,
                calculation: $settings.estimateFTPFromVO2max,
                confidence: nil,
                method: "Your aerobic ceiling times the share of it held at threshold, converted to watts at a trained cyclist's efficiency.",
                needs: "cycling VO₂max, weight"),
            Row(metricKey: "lactate_threshold_hr_cycling", title: "Cycling threshold HR",
                value: snapshot.cyclingLactateThrHR.map { "\($0) bpm" },
                calculatedHere: snapshot.cyclingLactateThrHRIsEstimated,
                calculation: $settings.estimateCyclingLTHRFromRides,
                confidence: snapshot.cyclingLactateThrHRIsEstimated
                    ? snapshot.cyclingLactateThrHRConfidence : nil,
                method: "The heart rate you hold in rides near your own best 20-minute power. Gated on watts, not on heart rate — on a bike the intensity is measured, so a high heart rate at low power is a bad strap, not a threshold.",
                needs: "max HR, rides with power"),
        ]
    }

    private var runningRows: [Row] {
        [
            Row(metricKey: "vo2max_running", title: "Running VO₂max",
                value: snapshot.vo2maxRunning.map { String(format: "%.1f ml/kg/min", $0) },
                calculatedHere: snapshot.vo2maxRunningIsEstimated,
                calculation: $settings.estimateRunningVO2maxFromRuns,
                confidence: snapshot.vo2maxRunningIsEstimated
                    ? snapshot.vo2maxRunningConfidence : nil,
                method: "The same aerobic ceiling behind your threshold pace, read as oxygen uptake instead of as speed. One reconstruction, two units — they cannot disagree.",
                needs: "max HR, resting HR, runs"),
            Row(metricKey: "lactate_threshold_hr", title: "Running threshold HR",
                value: snapshot.lactateThrHR.map { "\($0) bpm" },
                calculatedHere: snapshot.lactateThrHRIsEstimated,
                calculation: $settings.estimateLTHRFromHRMax,
                confidence: snapshot.lactateThrHRIsEstimated ? snapshot.lactateThrHRConfidence : nil,
                method: "The heart rate you actually hold in your hardest steady running, weighted toward recent efforts. It is also the value your heart-rate zones are drawn against for every discipline that has none of its own.",
                needs: "max HR, steady 20-minute runs"),
            Row(metricKey: "lactate_threshold_speed", title: "Threshold pace",
                value: snapshot.lactateThrPaceFormatted.map { "\($0)/km" },
                calculatedHere: snapshot.lactateThrPaceIsEstimated,
                calculation: $settings.estimateLTPaceFromRuns,
                confidence: snapshot.lactateThrPaceIsEstimated
                    ? snapshot.lactateThrPaceConfidence : nil,
                method: "Your aerobic ceiling reconstructed from ordinary runs, then the share of it you hold at threshold.",
                needs: "max HR, resting HR, threshold HR, runs"),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                Text("Older and lower-cost watches don't measure FTP or a threshold, but they do report the inputs to work them out. Each calculation **replaces** the synced value while switched on — turn one on when that value is missing, stale or a placeholder. A value you entered by hand is never replaced.")
                    .font(.subheadline).foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    SectionHeading("Current values")
                    ForEach(rows) { card($0) }
                }

                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    SectionHeading("What to calculate")
                    VStack(spacing: Theme.Spacing.s) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { Divider() }
                            Toggle(row.title, isOn: row.calculation)
                        }
                    }
                    .contentCard()
                    storedHistory
                }

                runningFactor
            }
            .padding(Theme.Spacing.l)
        }
        .navigationTitle("Automatic calculation")
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .trainingDataDidChange)) { _ in
            reload()
        }
    }

    private func reload() {
        snapshot = TrainingDataStore.shared.latestSnapshot()
        historyStale = TrainingDataStore.historyNeedsRescore
        if !isDragging { fractionDraft = settings.ltPaceFractionOfMAS }
    }

    /// The values above are resolved on read and are already right; what is not is the
    /// training load every stored activity was scored with. Saying so here, next to the
    /// switch that caused it, is the whole point — the alternative is a number and a
    /// load that quietly disagree.
    @ViewBuilder private var storedHistory: some View {
        if historyStale {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Label("Training load still uses the old thresholds", systemImage: "clock.badge.exclamationmark")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.orange)
                Text("The values above already reflect your change. Training load and time in zone for everything already stored were scored against the thresholds in force at the time — recompute to bring them in line.")
                    .font(.footnote).foregroundStyle(.secondary)
                RecomputeHistoryButton()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentCard()
        } else {
            Text("A change applies to newly synced activities right away. Training load and time in zone for everything already stored keep the thresholds they were scored with until you recompute.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    // MARK: Rows

    private func card(_ row: Row) -> some View {
        NavigationLink {
            chart(for: row)
        } label: {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.title).font(.headline)
                    Spacer()
                    Text(row.value.map { row.calculatedHere ? "~\($0)" : $0 } ?? "—")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(row.value == nil ? .tertiary : .primary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                source(row)
                Text(row.method).font(.caption).foregroundStyle(.secondary)
                Text("Needs: \(row.needs)").font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentCard()
        }
        .buttonStyle(.plain)
    }

    /// Where the number above actually came from — the distinction the "~" alone cannot
    /// carry, since a row shows a value whether or not its calculation is running.
    @ViewBuilder private func source(_ row: Row) -> some View {
        if row.calculatedHere {
            Label(["Calculated here", row.confidence.map(confidenceText)]
                    .compactMap { $0 }.joined(separator: " · "),
                  systemImage: "wand.and.sparkles")
                .font(.caption)
                .foregroundStyle(row.confidence == nil || row.confidence == .anchored
                                 ? Color.accentColor : Color.orange)
        } else if row.value != nil {
            Label("From \(settings.metricsSource.displayName)"
                  + (row.calculationOn ? " — not enough data to calculate it yet" : ""),
                  systemImage: "arrow.down.circle")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Label(row.calculationOn ? "Not enough data yet" : "Calculation switched off",
                  systemImage: "minus.circle")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private func chart(for row: Row) -> some View {
        if let metric = PerformanceMetric.all.first(where: { $0.key == row.metricKey }) {
            MetricChart(metric: metric)
        }
    }

    private func confidenceText(_ c: EstimateConfidence) -> String {
        switch c {
        case .anchored: "backed by several recent efforts"
        case .thin: "rests on one or two efforts, so a single session moves it"
        case .stale: "not enough recent runs — carrying an older value forward"
        case .rough: "no qualifying effort yet — a share of your max HR, not a reading"
        }
    }

    // MARK: Running threshold factor

    private var runningFactor: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeading("Running threshold factor")
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Toggle("Set it myself", isOn: Binding(
                    get: { settings.ltPaceFractionOfMAS > 0 },
                    // Starts from the derived value rather than a slider endpoint, so
                    // switching this on does not silently move the answer.
                    set: {
                        settings.ltPaceFractionOfMAS = $0 ? (derivedFraction ?? 0.80) : 0
                        fractionDraft = settings.ltPaceFractionOfMAS
                    }))
                Divider()
                HStack {
                    Text(settings.ltPaceFractionOfMAS > 0 ? "Your value"
                                                          : "Derived from your threshold HR")
                        .foregroundStyle(.secondary)
                    Spacer()
                    // The draft, so the number tracks the thumb rather than the last
                    // committed value.
                    Text((settings.ltPaceFractionOfMAS > 0 ? fractionDraft : derivedFraction)
                            .map { String(format: "%.3f", $0) } ?? "—")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(resolvedFraction == nil ? .tertiary : .primary)
                }
                if settings.ltPaceFractionOfMAS > 0 {
                    // Dragged against a local draft and committed on release. The
                    // setting is a read-time input to every threshold, so writing it
                    // re-resolves the whole history — 200 times across one drag, on the
                    // main actor, which is a drag the slider cannot survive. Intermediate
                    // positions are not decisions.
                    Slider(value: $fractionDraft, in: 0.70 ... 0.90, step: 0.001) { editing in
                        isDragging = editing
                        if !editing { settings.ltPaceFractionOfMAS = fractionDraft }
                    }
                }
            }
            .contentCard()
            Text("How much of your aerobic ceiling you hold at threshold. This one really is personal — athletes differ enough here to move threshold pace by several seconds per kilometre — so it is derived from your own threshold heart rate rather than assumed. Set it by hand only if you have run a 30-minute threshold test: take the share of your heart-rate reserve you held and divide by 1.035.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// What the resolver derived, and the starting point for a manual value.
    private var derivedFraction: Double? { snapshot.ltPaceFractionUsed }

    /// What is actually in force — nil while neither a setting nor the inputs exist.
    private var resolvedFraction: Double? {
        settings.ltPaceFractionOfMAS > 0 ? settings.ltPaceFractionOfMAS : derivedFraction
    }
}

// MARK: - Lazily resolved chart

/// One metric's progression, resolved when the row is opened.
///
/// `NavigationLink` builds its destination eagerly, so resolving the series inline
/// re-derives it on every body pass — once per frame while the factor slider moves,
/// each pass a store fetch plus a hundred-odd re-resolutions per estimated metric.
private struct MetricChart: View {
    let metric: PerformanceMetric
    @State private var points: [MetricPoint] = []

    var body: some View {
        MetricDetailView(metric: metric, points: points)
            .task { points = await TrainingDataStore.shared.metricHistory(metric.key) }
    }
}

// MARK: - Recompute history

/// "Recompute history" with its progress, offered both here and in the Performance
/// section. One view rather than two copies: the action is the same, and the progress
/// state belongs to whoever is showing it.
struct RecomputeHistoryButton: View {
    @State private var progress: (done: Int, total: Int)?

    var body: some View {
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
