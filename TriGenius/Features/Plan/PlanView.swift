//  PlanView.swift
//  The training overview ("Trainingsübersicht") reached by tapping the phase
//  banner on the Dashboard. Shows the goal event and the periodized phase
//  timeline, and lets the athlete edit the event and each phase's dates, focus
//  and per-sport weekly targets. The coach can also build the whole plan via the
//  `set_training_plan` tool — this screen is the manual counterpart.

import SwiftUI

/// The canonical sports a phase can carry targets for (keys match the memory /
/// Python format; `family` drives icon + color).
private let planSports: [(key: String, family: SportFamily)] = [
    ("swimming", .swim),
    ("cycling", .bike),
    ("running", .run),
    ("strength", .strength)
]

struct PlanView: View {
    @ObservedObject var memory: CoachMemory

    @State private var editingEvent = false
    @State private var editingPhase: Phase?
    @State private var showAddPhase = false

    private var plan: TrainingPlan { memory.trainingPlan }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                goalCard
                phasesSection
            }
            .padding()
        }
        .navigationTitle("Training Plan")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $editingEvent) {
            EventEditView(plan: plan) { name, date in
                memory.updateTrainingPlan {
                    $0.targetEvent = name.isEmpty ? nil : name
                    $0.eventDate = date
                }
            }
        }
        .sheet(item: $editingPhase) { phase in
            PhaseEditView(phase: phase) { updated in
                upsert(updated)
            } onDelete: {
                delete(phase)
            }
        }
        .sheet(isPresented: $showAddPhase) {
            PhaseEditView(phase: newPhase(), isNew: true) { created in
                upsert(created)
            } onDelete: {}
        }
    }

    // MARK: - Goal / event

    private var goalCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Goal", systemImage: "flag.checkered")
                    .font(.headline)
                Spacer()
                Button("Edit") { editingEvent = true }
                    .font(.subheadline)
            }

            if let event = plan.targetEvent {
                Text(event).font(.title3.bold())
                HStack(spacing: 12) {
                    if let date = plan.eventDate {
                        Label(prettyDate(date), systemImage: "calendar")
                    }
                    if let days = plan.daysUntilEvent(), days >= 0 {
                        Label("\(days) days", systemImage: "timer")
                    }
                }
                .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("No goal event set yet.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Set goal event") { editingEvent = true }
                    .font(.subheadline)
            }
        }
        .dashCard()
    }

    // MARK: - Phases

    private var phasesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Phases").font(.headline)
                if let total = plan.totalWeeks {
                    Text("• \(total) weeks").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showAddPhase = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .font(.subheadline)
            }

            if plan.phases.isEmpty {
                Text("No phases yet. Add base / build / peak / taper blocks, or ask the coach to build a plan for your goal.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .dashCard()
            } else {
                ForEach(plan.phases) { phase in
                    Button {
                        editingPhase = phase
                    } label: {
                        PhaseCard(phase: phase, isCurrent: plan.phase()?.id == phase.id)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Mutation

    private func upsert(_ phase: Phase) {
        memory.updateTrainingPlan { plan in
            if let idx = plan.phases.firstIndex(where: { $0.id == phase.id }) {
                plan.phases[idx] = phase
            } else {
                plan.phases.append(phase)
            }
            plan.phases.sort { ($0.start() ?? .distantPast) < ($1.start() ?? .distantPast) }
        }
    }

    private func delete(_ phase: Phase) {
        memory.updateTrainingPlan { plan in
            plan.phases.removeAll { $0.id == phase.id }
        }
    }

    /// A sensible starting point for a new phase: begins where the last one ends.
    private func newPhase() -> Phase {
        let start = plan.phases.compactMap { $0.end() }.max() ?? Date()
        let end = Calendar.current.date(byAdding: .day, value: 28, to: start) ?? start
        return Phase(name: .base,
                     startDate: TrainingPlan.isoFormatter.string(from: start),
                     endDate: TrainingPlan.isoFormatter.string(from: end))
    }
}

// MARK: - Phase card (read-only row)

private struct PhaseCard: View {
    let phase: Phase
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(phase.name.color)
                .frame(width: 5)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: phase.name.icon).foregroundStyle(phase.name.color)
                    Text(phase.name.displayName).font(.headline)
                    if isCurrent {
                        Text("NOW")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(phase.name.color.opacity(0.2)))
                            .foregroundStyle(phase.name.color)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }

                Text("\(prettyDate(phase.startDate)) – \(prettyDate(phase.endDate))")
                    .font(.subheadline).foregroundStyle(.secondary)

                if let focus = phase.focus, !focus.isEmpty {
                    Text(focus).font(.subheadline)
                }

                let targets = orderedTargets(phase)
                if !targets.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(targets, id: \.0) { sport, target in
                            PhaseTargetTile(sport: sport, target: target)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 4)
        .dashCard()
    }

    private func orderedTargets(_ phase: Phase) -> [(String, SportTarget)] {
        planSports.compactMap { sport in
            guard let t = phase.sportTargets[sport.key], t.hasData else { return nil }
            return (sport.key, t)
        }
    }
}

// MARK: - Phase target tile

/// A single per-sport target in a phase card: the sport icon stacked above its
/// weekly values, no border. Strength carries no distance (only a TSS load).
private struct PhaseTargetTile: View {
    let sport: String
    let target: SportTarget

    private var family: SportFamily { SportFamily(sportKey: sport) }
    private var showsDistance: Bool { family != .strength }

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: family.icon)
                .font(.subheadline)
                .foregroundStyle(family.color)
            if showsDistance, let km = target.weeklyDistanceKm {
                Text("\(formatKm(km)) km")
                    .font(.caption.weight(.medium))
            }
            if let tss = target.weeklyTSS {
                Text("\(tss) TSS")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private func formatKm(_ km: Double) -> String {
    km == km.rounded() ? String(Int(km)) : String(format: "%.1f", km)
}

private func prettyDate(_ iso: String) -> String {
    guard let d = TrainingPlan.isoDate(iso) else { return iso }
    return d.formatted(.dateTime.day().month(.abbreviated).year())
}

// MARK: - Event editor

private struct EventEditView: View {
    let plan: TrainingPlan
    let onSave: (_ name: String, _ isoDate: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var date: Date

    init(plan: TrainingPlan, onSave: @escaping (String, String) -> Void) {
        self.plan = plan
        self.onSave = onSave
        _name = State(initialValue: plan.targetEvent ?? "")
        _date = State(initialValue: TrainingPlan.isoDate(plan.eventDate) ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Goal event") {
                    TextField("Event name", text: $name)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }
            }
            .navigationTitle("Edit Goal")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(name.trimmingCharacters(in: .whitespaces),
                               TrainingPlan.isoFormatter.string(from: date))
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Phase editor

private struct PhaseEditView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name: PhaseName
    @State private var start: Date
    @State private var end: Date
    @State private var focus: String
    @State private var targets: [String: SportTarget]

    private let original: Phase
    private let isNew: Bool
    private let onSave: (Phase) -> Void
    private let onDelete: () -> Void

    init(phase: Phase, isNew: Bool = false,
         onSave: @escaping (Phase) -> Void, onDelete: @escaping () -> Void) {
        original = phase
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
        _name = State(initialValue: phase.name)
        _start = State(initialValue: phase.start() ?? Date())
        _end = State(initialValue: phase.end() ?? Date())
        _focus = State(initialValue: phase.focus ?? "")
        _targets = State(initialValue: phase.sportTargets)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Phase") {
                    Picker("Type", selection: $name) {
                        ForEach(PhaseName.allCases) { phase in
                            Text(phase.displayName).tag(phase)
                        }
                    }
                    DatePicker("Start", selection: $start, displayedComponents: .date)
                    DatePicker("End", selection: $end, in: start..., displayedComponents: .date)
                    TextField("Focus (optional)", text: $focus, axis: .vertical)
                }

                Section("Weekly targets per sport") {
                    ForEach(planSports, id: \.key) { sport in
                        sportTargetRow(sport.key, family: sport.family)
                    }
                }

                if !isNew {
                    Section {
                        Button("Delete phase", role: .destructive) {
                            onDelete()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "Add Phase" : "Edit Phase")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
    }

    @ViewBuilder private func sportTargetRow(_ key: String, family: SportFamily) -> some View {
        let binding = targetBinding(key)
        VStack(alignment: .leading, spacing: 6) {
            Label(family.displayName, systemImage: family.icon)
                .font(.subheadline.weight(.medium))
            HStack {
                Text("km/wk").font(.caption).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                TextField("—", value: binding.weeklyDistanceKm, format: .number)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                Divider()
                Text("TSS/wk").font(.caption).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                TextField("—", value: binding.weeklyTSS, format: .number)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
            }
        }
        .padding(.vertical, 2)
    }

    /// A binding into the `targets` map that creates/removes the entry on demand.
    private func targetBinding(_ key: String) -> Binding<SportTarget> {
        Binding(
            get: { targets[key] ?? SportTarget() },
            set: { newValue in
                if newValue.hasData { targets[key] = newValue }
                else { targets[key] = nil }
            }
        )
    }

    private func save() {
        var phase = original
        phase.name = name
        phase.startDate = TrainingPlan.isoFormatter.string(from: start)
        phase.endDate = TrainingPlan.isoFormatter.string(from: end)
        phase.focus = focus.trimmingCharacters(in: .whitespaces).isEmpty ? nil : focus
        phase.sportTargets = targets.filter { $0.value.hasData }
        onSave(phase)
        dismiss()
    }
}
