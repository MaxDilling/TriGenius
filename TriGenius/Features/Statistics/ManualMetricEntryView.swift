import SwiftUI

// MARK: - Manual performance-value entry
//
// FEATURES.md "Manuelles Hizufügen von Leistungswerten": add / edit a hand-entered
// performance marker (FTP, CSS, VO₂max, thresholds, weight) at a chosen date. Writes
// through `TrainingDataStore.setManualMetric`, so the value joins the same time series
// the sync path feeds (charts, snapshot, coach, TSS).

/// Add or edit a hand-entered performance value. In edit mode the metric and date are
/// fixed (they key the record) — only the value changes; add mode picks both freely.
struct ManualMetricEntryView: View {
    /// The metric+date+value being edited; nil starts a fresh add.
    struct Editing { let metric: PerformanceMetric; let date: Date; let value: Double }

    private let editing: Editing?

    @Environment(\.dismiss) private var dismiss
    @State private var metricKey: String
    @State private var date: Date
    @State private var text: String

    /// - Parameter defaultKey: metric to pre-select in add mode (e.g. the card the
    ///   user opened); ignored in edit mode.
    init(editing: Editing? = nil, defaultKey: String? = nil) {
        self.editing = editing
        if let editing {
            _metricKey = State(initialValue: editing.metric.key)
            _date = State(initialValue: editing.date)
            _text = State(initialValue: editing.metric.format(editing.value))
        } else {
            _metricKey = State(initialValue: defaultKey ?? PerformanceMetric.editable[0].key)
            _date = State(initialValue: Date())
            _text = State(initialValue: "")
        }
    }

    private var metric: PerformanceMetric {
        PerformanceMetric.metric(for: metricKey) ?? PerformanceMetric.editable[0]
    }
    private var isPace: Bool { metric.storageUnit == "m_per_s" }
    private var parsed: Double? { metric.parse(text.trimmingCharacters(in: .whitespaces)) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if editing != nil {
                        LabeledContent("Metric", value: metric.title)
                        LabeledContent("Date", value: date.formatted(date: .abbreviated, time: .omitted))
                    } else {
                        Picker("Metric", selection: $metricKey) {
                            ForEach(PerformanceMetric.editable) { Text($0.title).tag($0.key) }
                        }
                        DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: .date)
                    }
                }

                Section {
                    HStack {
                        TextField(isPace ? "m:ss" : "Value", text: $text)
                            #if !os(macOS)
                            .keyboardType(isPace ? .numbersAndPunctuation : .decimalPad)
                            #endif
                        if !metric.unit.isEmpty {
                            Text(metric.unit).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    if isPace { Text("Enter pace as m:ss (e.g. 1:45).") }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(editing != nil ? "Edit Value" : "Add Value")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(parsed == nil)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 300)
        #endif
    }

    private func save() {
        guard let value = parsed else { return }
        TrainingDataStore.shared.setManualMetric(
            key: metric.key, value: value, unit: metric.storageUnit, date: date
        )
        dismiss()
    }
}
