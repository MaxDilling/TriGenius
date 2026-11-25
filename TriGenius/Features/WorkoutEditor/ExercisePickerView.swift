import SwiftUI

// MARK: - Exercise picker
//
// One search field over the whole library: typing narrows it, and a name the
// library lacks is offered at the top as a custom exercise, unmapped to any
// tissue group. Empty, it shows the athlete's recent exercises, then every
// category, what their `StrengthProfile` allows first. With `multiple`, taps
// collect exercises in the order they will be done and one confirm adds them all.

/// A picked exercise: from the library, or a name the athlete typed.
enum ExerciseChoice: Hashable {
    case library(Exercise)
    case custom(String)
}

struct ExercisePickerView: View {
    let multiple: Bool
    let onPick: ([ExerciseChoice]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissSearch) private var dismissSearch
    @State private var query: String
    @State private var selection: [ExerciseChoice] = []
    @State private var recent: [Exercise] = []
    private let profile = StrengthProfile.stored

    init(multiple: Bool, query: String = "", onPick: @escaping ([ExerciseChoice]) -> Void) {
        self.multiple = multiple
        self.onPick = onPick
        _query = State(initialValue: query)
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    private var matches: [Exercise] {
        profile.ranked(ExerciseLibrary.all.filter { $0.name.localizedCaseInsensitiveContains(trimmed) })
    }

    private var categories: [(category: Exercise.Category, exercises: [Exercise])] {
        Dictionary(grouping: ExerciseLibrary.all, by: \.category)
            .map { (category: $0.key, exercises: profile.ranked($0.value)) }
            .sorted { $0.category.label < $1.category.label }
    }

    private var custom: ExerciseChoice? {
        guard !trimmed.isEmpty,
              !ExerciseLibrary.all.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return nil }
        return .custom(trimmed)
    }

    var body: some View {
        List {
            Group {
                if let custom {
                    Section { row(custom) }
                }
                if trimmed.isEmpty {
                    if multiple, !selection.isEmpty {
                        Section("Selected") { ForEach(selection, id: \.self, content: row) }
                    }
                    if !recent.isEmpty {
                        Section("Recent") { ForEach(recent) { row(.library($0)) } }
                    }
                    ForEach(categories, id: \.category) { group in
                        Section(group.category.label) { ForEach(group.exercises) { row(.library($0)) } }
                    }
                } else {
                    Section { ForEach(matches) { row(.library($0)) } }
                }
            }
            .listSectionSeparator(.hidden)
        }
        .exerciseSearch($query, prompt: "Search or add") {
            if matches.count == 1 { pick(.library(matches[0])) } else if let custom { pick(custom) }
        }
        .navigationTitle(multiple ? "Add Exercises" : "Exercise")
        .pickerTitleDisplay()
        .toolbar {
            if multiple {
                ToolbarItem(placement: .confirmationAction) {
                    Button(selection.isEmpty ? "Add" : "Add \(selection.count)") { finish(selection) }
                        .disabled(selection.isEmpty)
                }
            }
        }
        .task { recent = TrainingDataStore.shared.recentExercises() }
    }

    private func row(_ choice: ExerciseChoice) -> some View {
        ExerciseChoiceRow(choice: choice, selected: selection.contains(choice)) { pick(choice) }
    }

    private func pick(_ choice: ExerciseChoice) {
        guard multiple else { return finish([choice]) }
        if let index = selection.firstIndex(of: choice) { selection.remove(at: index) } else { selection.append(choice) }
        if case .custom = choice { query = "" }
    }

    /// Ends the search's keyboard session before dismissing: popping this view
    /// while the field still holds the keyboard orphans UIKit's
    /// `_UIRemoteKeyboardPlaceholderView`, and the next field to focus crashes in
    /// CoreAutoLayout ("no common ancestor").
    private func finish(_ choices: [ExerciseChoice]) {
        dismissSearch()
        onPick(choices)
        dismiss()
    }
}

/// One exercise to choose: its animation (a "+" for a custom name), name and
/// detail, and a checkmark when chosen.
struct ExerciseChoiceRow: View {
    let choice: ExerciseChoice
    /// Overrides the equipment (or "Custom exercise") line.
    var detail: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.m) {
                switch choice {
                case .library(let exercise):
                    ExerciseThumbnail(exercise: exercise)
                case .custom:
                    Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(.tint).frame(width: 48, height: 36)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail ?? defaultDetail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var title: String {
        switch choice {
        case .library(let exercise): return exercise.name
        case .custom(let name): return "Add “\(name)”"
        }
    }

    private var defaultDetail: String {
        if case .library(let exercise) = choice { return exercise.equipment.label }
        return "Custom exercise"
    }
}

extension View {
    /// An exercise sheet's search: the system field on iOS; on the Mac a field
    /// atop the list, since a sheet's toolbar gives the field a row of its own,
    /// set apart from the content.
    @ViewBuilder
    func exerciseSearch(_ text: Binding<String>, prompt: String, onSubmit: @escaping () -> Void = {}) -> some View {
        #if os(iOS)
        searchable(text: text, prompt: prompt).onSubmit(of: .search, onSubmit)
        #else
        safeAreaInset(edge: .top, spacing: 0) { MacSearchField(text: text, prompt: prompt, onSubmit: onSubmit) }
        #endif
    }

    /// A picker sheet's title: inline on iOS. Removed on the Mac, where a sheet
    /// sets the title on its own row — the search prompt and the confirm button
    /// say what the sheet is for.
    func pickerTitleDisplay() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        toolbar(removing: .title)
        #endif
    }

    /// Presents `ExercisePickerView` the one way each platform survives.
    @ViewBuilder
    func exercisePicker(isPresented: Binding<Bool>, multiple: Bool, query: String = "",
                        onPick: @escaping ([ExerciseChoice]) -> Void) -> some View {
        let picker = ExercisePickerView(multiple: multiple, query: query, onPick: onPick)
        #if os(macOS)
        // macOS: a sheet, because a further push from a binding-through-binding
        // chain trips an AppKit "Update Constraints in Window" crash on open.
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

#if os(macOS)
private struct MacSearchField: View {
    @Binding var text: String
    let prompt: String
    let onSubmit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
        .background(Color.appTertiaryBackground, in: Capsule())
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.s)
        .onAppear { focused = true }
    }
}
#endif
