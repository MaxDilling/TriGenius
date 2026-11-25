import SwiftUI
import SwiftData

// MARK: - Workout library
//
// The athlete's templates by sport, shown as the calendar's inspector — a
// column beside the calendar on a wide layout, a sheet on iPhone. Tapping one
// opens the editor prefilled on `date`; on a wide layout a row can also be
// dragged straight onto a calendar day (`CalendarViewModel.move`).

struct TemplateLibraryView: View {
    let date: Date
    @Binding var isPresented: Bool

    @Query(sort: \WorkoutTemplate.name) private var templates: [WorkoutTemplate]
    @State private var editor: WorkoutEditorContext?

    private var groups: [(family: SportFamily, templates: [WorkoutTemplate])] {
        Dictionary(grouping: templates, by: \.family)
            .map { (family: $0.key, templates: $0.value) }
            .sorted { $0.family.displayName < $1.family.displayName }
    }

    // The header is the view's own, not a navigation toolbar: on the Mac an
    // inspector's toolbar items join the window's toolbar, and its dismiss
    // action closes the window.
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.m) {
                Text("Library").font(.headline)
                Spacer()
                Button("New Template", systemImage: "plus") { editor = .template(nil) }
                Button("Close", systemImage: "xmark") { isPresented = false }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.m)
            List {
                ForEach(groups, id: \.family) { group in
                    // A heading row, not a `Section` header: a Mac list rules its
                    // section headers heavier than its row separators.
                    Text(group.family.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden, edges: .top)
                    ForEach(group.templates) { row($0) }
                }
            }
            .overlay {
                if templates.isEmpty {
                    ContentUnavailableView("No Templates", systemImage: "square.stack",
                                           description: Text("Create one here, or save a workout as a template from its editor."))
                }
            }
        }
        .sheet(item: $editor) { WorkoutEditorSheet(context: $0) }
    }

    /// Tap plans it, drag drops it on a day — a tap gesture, not a `Button`,
    /// which would swallow the drag.
    private func row(_ template: WorkoutTemplate) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: template.family.icon)
                .foregroundStyle(Theme.Palette.sport(template.family))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(template.name)
                Text(Self.detail(template.workoutData)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Chevron()
        }
        .contentShape(Rectangle())
        .onTapGesture { editor = .fromTemplate(template, date: date) }
        .draggable(template.dragID)
        .contextMenu {
            Button("Edit Template", systemImage: "pencil") { editor = .template(template) }
            Button("Delete", systemImage: "trash", role: .destructive) { TrainingDataStore.shared.deleteTemplate(template) }
        }
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) { TrainingDataStore.shared.deleteTemplate(template) }
            Button("Edit", systemImage: "pencil") { editor = .template(template) }
        }
    }

    /// "6 exercises", else the planned duration ("45 min").
    private static func detail(_ data: [String: Any]) -> String {
        let exercises = StrengthSets.exerciseCount(data["steps"] as? [[String: Any]] ?? [])
        if exercises > 0 { return "\(exercises) exercise\(exercises == 1 ? "" : "s")" }
        return Coerce.int(data["duration_minutes"]).map { "\($0) min" } ?? ""
    }
}
