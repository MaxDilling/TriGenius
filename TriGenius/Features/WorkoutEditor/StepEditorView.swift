import SwiftUI

// MARK: - Step editor
//
// Edits one `StepDraft` in place via binding — a leaf's type/extent/target, or a
// repeat block's count + child steps (child editors recurse with `allowRepeat`
// false, so repeats aren't nested — matching the display layer and the Garmin
// builder). All values edit the raw stored units; only durations and pace show
// as "m:ss" text (an exact, display-only conversion).

struct StepEditorView: View {
    @Binding var step: StepDraft
    let sport: EditorSport
    /// False inside a repeat block: child steps can't be repeats themselves.
    let allowRepeat: Bool

    var body: some View {
        Form {
            if step.isRepeat {
                repeatSection
                childrenSection
            } else {
                stepSection
                targetSection
            }
        }
        .formStyle(.grouped)
        .navigationTitle(step.isRepeat ? "Repeat" : "Step")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: Leaf

    private var stepSection: some View {
        Section("Step") {
            Picker("Type", selection: $step.kind) {
                ForEach(StepKind.allCases) { Text($0.label).tag($0) }
            }
            Picker("Ends by", selection: $step.end) {
                ForEach(StepEnd.allCases) { Text($0.label).tag($0) }
            }
            switch step.end {
            case .time, .fixedRest:
                mmssField("Duration", seconds: $step.durationSeconds)
            case .distance:
                numberField("Distance (m)", value: stepDistance, format: .number, prompt: "")
            case .lapButton:
                EmptyView()
            }
            if sport == .swimming {
                Picker("Stroke", selection: $step.stroke) {
                    Text("Default").tag(SwimStroke?.none)
                    ForEach(SwimStroke.allCases) { Text($0.label).tag(SwimStroke?.some($0)) }
                }
            }
        }
    }

    private var targetSection: some View {
        Section {
            Picker("Target", selection: $step.targetType) {
                ForEach(StepTargetType.allCases) { Text($0.label).tag($0) }
            }
            switch step.targetType {
            case .noTarget:
                EmptyView()
            case .pace:
                let unit = sport == .swimming ? "/100m" : "/km"
                paceField("Fast (m:ss \(unit))", value: $step.targetLow)
                paceField("Slow (m:ss \(unit))", value: $step.targetHigh)
            case .heartRate:
                numberField("Low (bpm)", value: $step.targetLow, format: .number)
                numberField("High (bpm)", value: $step.targetHigh, format: .number)
            case .power:
                numberField("Low (W)", value: $step.targetLow, format: .number)
                numberField("High (W)", value: $step.targetHigh, format: .number)
            case .speed:
                numberField("Low (km/h)", value: $step.targetLow, format: .number)
                numberField("High (km/h)", value: $step.targetHigh, format: .number)
            case .cadence:
                let unit = sport == .cycling ? "rpm" : "spm"
                numberField("Low (\(unit))", value: $step.targetLow, format: .number)
                numberField("High (\(unit))", value: $step.targetHigh, format: .number)
            }
        } header: {
            Text("Intensity target")
        } footer: {
            if step.targetType != .noTarget {
                Text("A single value is auto-widened into a band on save.")
            }
        }
    }

    /// `distanceMeters` is non-optional (the end condition guarantees a value);
    /// clearing the field just keeps the previous distance.
    private var stepDistance: Binding<Double?> {
        Binding(get: { step.distanceMeters },
                set: { if let v = $0, v > 0 { step.distanceMeters = v } })
    }

    // MARK: Repeat block

    private var repeatSection: some View {
        Section("Repeat") {
            Stepper("Repetitions: \(step.repeatCount)", value: $step.repeatCount, in: 2...50)
            Toggle("Skip last rest", isOn: $step.skipLastRest)
        }
    }

    private var childrenSection: some View {
        Section("Steps") {
            ForEach($step.children) { $child in
                NavigationLink {
                    StepEditorView(step: $child, sport: sport, allowRepeat: false)
                } label: {
                    Text(child.summary(sport: sport)).lineLimit(2)
                }
            }
            .onDelete { step.children.remove(atOffsets: $0) }
            .onMove { step.children.move(fromOffsets: $0, toOffset: $1) }
            Button("Add step") { step.children.append(StepDraft(kind: .interval)) }
        }
    }

    // MARK: m:ss fields (display-only conversion; stored value stays raw seconds)

    private func mmssField(_ label: String, seconds: Binding<Int>) -> some View {
        mmssTextField(label, text: Binding(
            get: { Self.mmss(seconds.wrappedValue) },
            set: { if let s = Self.seconds(from: $0) { seconds.wrappedValue = s } }
        ))
    }

    private func paceField(_ label: String, value: Binding<Double?>) -> some View {
        mmssTextField(label, text: Binding(
            get: { value.wrappedValue.map { Self.mmss(Int($0.rounded())) } ?? "" },
            set: { value.wrappedValue = Self.seconds(from: $0).map(Double.init) }
        ))
    }

    private func mmssTextField(_ label: String, text: Binding<String>) -> some View {
        TextField(label, text: text, prompt: Text("m:ss"))
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            #if os(iOS)
            .keyboardType(.numbersAndPunctuation)
            #endif
    }

    private static func mmss(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// "m:ss" → seconds; a bare number reads as whole minutes. Nil (keep the
    /// previous value / clear the target) for anything unparseable.
    private static func seconds(from text: String) -> Int? {
        let parts = text.split(separator: ":")
        if parts.count == 2, let m = Int(parts[0]), let s = Int(parts[1]), s < 60, m >= 0, s >= 0 {
            return m * 60 + s
        }
        if parts.count == 1, let m = Int(parts[0]), m >= 0 { return m * 60 }
        return nil
    }
}
