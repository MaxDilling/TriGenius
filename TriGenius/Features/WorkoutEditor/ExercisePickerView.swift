import SwiftUI

// MARK: - Exercise picker
//
// Search/browse the library the athlete's `StrengthProfile` allows, grouped by
// category; a "Custom" row lets the athlete type a name for anything not in the
// library — allowed per the Tissue Load handoff's D8, unmapped to any tissue
// group until the athlete (or a future curation pass) gives it one.

struct ExercisePickerView: View {
    let onSelectLibrary: (Exercise) -> Void
    let onSelectCustom: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissSearch) private var dismissSearch
    @FocusState private var customFocused: Bool
    @State private var query = ""
    @State private var customName = ""
    private let profile = StrengthProfile.stored

    private var filtered: [Exercise] {
        ExerciseLibrary.all.filter { profile.allows($0) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
    }

    private var grouped: [(category: Exercise.Category, exercises: [Exercise])] {
        Dictionary(grouping: filtered, by: \.category)
            .map { (category: $0.key, exercises: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.category.label < $1.category.label }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Exercise name", text: $customName)
                        .focused($customFocused)
                    Button("Add") {
                        let trimmed = customName.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        onSelectCustom(trimmed)
                        close()
                    }
                    .disabled(customName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Custom")
            } footer: {
                if let summary = profile.summary {
                    Text("Library filtered to your strength profile (\(summary)). Change it in Settings → Strength profile.")
                }
            }
            ForEach(grouped, id: \.category) { group in
                Section(group.category.label) {
                    ForEach(group.exercises) { exercise in
                        Button {
                            onSelectLibrary(exercise)
                            close()
                        } label: {
                            HStack {
                                Text(exercise.name)
                                Spacer()
                                Text(exercise.equipment.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Search exercises")
        .navigationTitle("Exercise")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// Ends every keyboard session before dismissing: popping this view while
    /// the search or custom field still holds the keyboard orphans UIKit's
    /// `_UIRemoteKeyboardPlaceholderView`, and the next field to focus (the
    /// weight field) crashes in CoreAutoLayout ("no common ancestor").
    private func close() {
        customFocused = false
        dismissSearch()
        dismiss()
    }
}

extension View {
    /// Presents `ExercisePickerView` the one way each platform survives.
    @ViewBuilder
    func exercisePicker(isPresented: Binding<Bool>,
                        onSelectLibrary: @escaping (Exercise) -> Void,
                        onSelectCustom: @escaping (String) -> Void) -> some View {
        let picker = ExercisePickerView(onSelectLibrary: onSelectLibrary, onSelectCustom: onSelectCustom)
        #if os(macOS)
        // macOS: a sheet, because a further push from a binding-through-binding
        // chain (circuit → exercise child) trips an AppKit "Update Constraints in
        // Window" crash on open.
        sheet(isPresented: isPresented) {
            NavigationStack {
                picker
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { isPresented.wrappedValue = false }
                        }
                    }
            }
            .frame(minWidth: 420, minHeight: 480)
        }
        #else
        // iOS/iPadOS: a push, NOT a sheet. A third presentation level (detail →
        // editor sheet → picker sheet) orphans UIKit's
        // `_UIRemoteKeyboardPlaceholderView`, and the weight field then crashes
        // in CoreAutoLayout ("no common ancestor") when it gains or loses focus.
        navigationDestination(isPresented: isPresented) { picker }
        #endif
    }
}
