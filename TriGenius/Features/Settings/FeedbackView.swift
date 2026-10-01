import SwiftUI

// MARK: - Feedback
//
// The athlete's reply ratings from the chat and pain check-ins: what was given,
// the export of all feedback, and the delete of the chat ratings. Workout ratings
// live on the workouts and are only part of the export.

struct FeedbackView: View {
    let athleteName: String?

    @State private var ratings: [[String: Any]] = []
    @State private var exportFile: ExportFile?
    @State private var showDeleteConfirm = false
    private var pain: PainReportStore { .shared }

    var body: some View {
        Form {
            Section {
                Button {
                    exportFile = FeedbackExport.file(athleteName: athleteName).map(ExportFile.init)
                } label: {
                    Label("Export my feedback", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete all chat ratings", systemImage: "trash")
                }
                .disabled(ratings.isEmpty)
            } footer: {
                Text("The export holds your name, your reply ratings — with the conversations, the coach's instructions and the training data it looked up — your workout ratings and your pain reports. It stays on this device until you share it. Deleting removes the chat ratings only; workout ratings stay on their workouts.")
            }

            Section("Chat ratings") {
                if ratings.isEmpty {
                    Text("No ratings yet. Use the thumbs under a coach reply.")
                        .foregroundStyle(.secondary)
                }
                ForEach(ratings.indices, id: \.self) { row(ratings[$0]) }
            }

            Section("Pain reports") {
                if pain.reports.isEmpty {
                    Text("No pain reports yet. Add one from the Tissue Load screen.")
                        .foregroundStyle(.secondary)
                }
                ForEach(pain.reports) { report in
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(report.severities.sorted { $0.key.anatomicalRank < $1.key.anatomicalRank }
                            .map { "\($0.key.label) \($0.value)/10" }.joined(separator: " · "))
                            .font(.subheadline)
                        Text(report.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .onDelete { offsets in pain.delete(ids: Set(offsets.map { pain.reports[$0].id })) }
            }
        }
        .navigationTitle("Feedback")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { ratings = ReplyRatingStore.shared.all() }
        .sheet(item: $exportFile) { file in ShareSheet(items: [file.url]) }
        .alert("Delete all chat ratings?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                ReplyRatingStore.shared.deleteAll()
                ratings = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes every reply rating and its saved conversation from this device. This cannot be undone.")
        }
    }

    private func row(_ rating: [String: Any]) -> some View {
        let reply = (rating["messages"] as? [[String: Any]])?.last { $0["role"] as? String == "assistant" }?["text"] as? String
        let notes = (rating["reasons"] as? [String] ?? []).map { $0.replacingOccurrences(of: "_", with: " ") }
            + [rating["comment"] as? String ?? ""].filter { !$0.isEmpty }
        let date = Date(timeIntervalSince1970: rating["timestamp"] as? Double ?? 0)
        return HStack(alignment: .top, spacing: Theme.Spacing.m) {
            Image(systemName: rating["rating"] as? String == "up" ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(reply ?? "").font(.subheadline).lineLimit(2)
                if !notes.isEmpty {
                    Text(notes.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
                Text(([date.formatted(date: .abbreviated, time: .shortened)] + [rating["model"] as? String].compactMap { $0 })
                    .joined(separator: " · "))
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}
