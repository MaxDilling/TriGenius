import SwiftUI

// MARK: - Live session summary
//
// What the ended session recorded, per unit, with the optional session RPE.
// Save links it to its plan as the completed session; Discard drops it and
// leaves the plan untouched.

struct LiveSummaryView: View {
    let session: StrengthSession

    private let live = LiveStrengthController.shared
    @State private var confirmDiscard = false

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("\(SportFamily.strength.displayName) · \(session.startedAt.formatted(date: .long, time: .omitted))")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text("Workout complete").font(.largeTitle.bold())
                    }
                    HStack(spacing: Theme.Spacing.m) {
                        tile(LiveFormat.clock(session.elapsed(at: .now)), "Duration")
                        tile("\(session.doneSets)/\(session.totalSets)", "Sets")
                    }
                    exercises
                    rpeCard
                }
                .padding()
            }
            VStack(spacing: Theme.Spacing.s) {
                Button { live.save() } label: {
                    Text("Save workout").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
                .disabled(session.log.isEmpty)
                Button("Discard", role: .destructive) { confirmDiscard = true }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
            .padding(.horizontal)
        }
        .padding(.bottom, Theme.Spacing.s)
        .background(Color.appBackground)
        .alert("Discard this workout?", isPresented: $confirmDiscard) {
            Button("Discard", role: .destructive) { live.close() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nothing is recorded and the plan stays as it is.")
        }
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(spacing: Theme.Spacing.xs) {
            Text(value).font(.title2.bold()).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .cardSurface(cornerRadius: Theme.Radius.l, padding: Theme.Spacing.l)
    }

    private var exercises: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(session.units.enumerated()), id: \.element.id) { index, unit in
                if index > 0 { Divider() }
                HStack(spacing: Theme.Spacing.m) {
                    Image(systemName: unit.isFinished ? "checkmark.circle" : unit.done > 0 ? "circle.lefthalf.filled" : "circle")
                        .font(.title2)
                        .foregroundStyle(unit.isFinished ? Theme.Palette.success : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(unit.title).font(.headline)
                        Text(line(unit)).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, Theme.Spacing.s)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: Theme.Radius.l, padding: Theme.Spacing.l)
    }

    /// What was logged per exercise, and which planned exercise a swap replaced:
    /// "3 × 12 · BW · swapped for Single-leg calf raise".
    private func line(_ unit: StrengthSession.Unit) -> String {
        let logged = session.log.filter { $0.unit == unit.id }.map(\.set)
        guard !logged.isEmpty else { return "Not done" }
        let titles = logged.reduce(into: [String]()) { if !$0.contains($1.title) { $0.append($1.title) } }
        return titles.map { title in
            let sets = logged.filter { $0.title == title }
            var text = ExerciseSetsCard.volume(sets)
            if titles.count > 1 { text = "\(title) \(text)" }
            if let original = unit.replaced[title] { text += " · swapped for \(original)" }
            return text
        }
        .joined(separator: " · ")
    }

    private var rpeCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack {
                Text("How hard was the session?").font(.headline)
                Spacer()
                Text(session.rpe.map(String.init) ?? "–").font(.title2.bold()).monospacedDigit()
            }
            Slider(value: Binding(get: { Double(session.rpe ?? 5) },
                                  set: { value in live.update { s, _ in s.rpe = Int(value.rounded()) } }),
                   in: 1...10, step: 1)
            HStack {
                Text("1 · Very easy")
                Spacer()
                Text("10 · Max")
            }
            .font(.caption).foregroundStyle(.secondary)
            if session.rpe != nil {
                Button("Clear rating") { live.update { s, _ in s.rpe = nil } }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
            }
        }
        .cardSurface(cornerRadius: Theme.Radius.l, padding: Theme.Spacing.l)
    }
}
