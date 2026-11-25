import SwiftUI

// MARK: - Step editor
//
// Edits one endurance `StepDraft` in place via binding — a leaf's
// type/extent/target, or a repeat block's count + child steps (children are
// leaves only, matching the display layer and the Garmin builder). All values
// edit the raw stored units; only durations and pace show as "m:ss" text (an
// exact, display-only conversion). Strength exercises are edited in place
// instead (`ExerciseEditorRow`).

struct StepEditorView: View {
    @Binding var step: StepDraft
    let sport: EditorSport

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
                mmssField("Fast (m:ss \(unit))", seconds: $step.targetLow)
                mmssField("Slow (m:ss \(unit))", seconds: $step.targetHigh)
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
                    StepEditorView(step: $child, sport: sport)
                } label: {
                    Text(child.summary(sport: sport)).lineLimit(2)
                }
                .reorderable(child.id, in: $step.children)
                // macOS has no swipe-to-delete; a right-click here deletes without
                // ever touching navigation/dismiss state — unlike a delete button
                // inside the pushed detail view, which crashed AppKit's window
                // layout on open (see git history).
                .contextMenu {
                    Button("Delete", role: .destructive) {
                        step.children.removeAll { $0.id == child.id }
                    }
                }
            }
            .onDelete { step.children.remove(atOffsets: $0) }
            Button("Add step") { step.children.append(StepDraft(kind: .interval)) }
        }
    }
}
