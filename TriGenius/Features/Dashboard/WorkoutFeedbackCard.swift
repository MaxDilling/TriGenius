import SwiftUI

/// The athlete's subjective read on a completed session — feel, RPE and a note,
/// each stored through `setWorkoutFeedback` the moment it is given. Tapping the
/// selected step again clears it.
struct WorkoutFeedbackCard: View {
    let record: WorkoutRecord

    @State private var noteInput = ""
    @FocusState private var noteFocused: Bool

    private static let feelLabels = ["Very Weak", "Weak", "Normal", "Strong", "Very Strong"]

    var body: some View {
        let details = (try? JSONSerialization.jsonObject(with: Data(record.detailsJSON.utf8))) as? [String: Any] ?? [:]
        let feel = Coerce.int(details["feel"])
        let rpe = Coerce.int(details["rpe"])
        let note = Coerce.string(details["notes"]) ?? ""
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            RatingScale(title: "Feel", value: feel, range: 1...5,
                        caption: feel.map { Self.feelLabels[min(max($0, 1), 5) - 1] }) {
                save(feel: $0, clearing: $0 == nil ? ["feel"] : [])
            }
            RatingScale(title: "RPE", value: rpe, range: 1...10, caption: rpe.map { "\($0) / 10" }) {
                save(rpe: $0, clearing: $0 == nil ? ["rpe"] : [])
            }
            TextField("Add a note", text: $noteInput, axis: .vertical)
                .font(.subheadline)
                .padding(Theme.Spacing.s)
                .background(.fill.tertiary, in: .rect(cornerRadius: Theme.Radius.s))
                .focused($noteFocused)
                .onSubmit { noteFocused = false }
                .onChange(of: noteFocused) { if !noteFocused { saveNote(replacing: note) } }
        }
        .cardTitle("How it felt", systemImage: "face.smiling")
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .task(id: note) { noteInput = note }
        .onDisappear { saveNote(replacing: note) }
    }

    private func save(feel: Int? = nil, rpe: Int? = nil, note: String? = nil, clearing: [String] = []) {
        _ = TrainingDataStore.shared.setWorkoutFeedback(activityId: record.id, feel: feel, rpe: rpe, note: note,
                                                        clearing: clearing)
    }

    private func saveNote(replacing note: String) {
        let trimmed = noteInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != note { save(note: trimmed) }
    }
}

/// The post-workout question while the app is open: one workout's feedback card
/// in a sheet.
struct WorkoutFeedbackPrompt: View {
    private let record: WorkoutRecord?
    @Environment(\.dismiss) private var dismiss

    init(id: String) { record = TrainingDataStore.shared.activity(id: id) }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let record { WorkoutFeedbackCard(record: record).padding() }
            }
            .background(Color.appBackground)
            .navigationTitle(record?.name ?? "")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 300)
        #endif
    }
}
