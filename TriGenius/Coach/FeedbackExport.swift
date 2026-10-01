import Foundation

// MARK: - Feedback Export
//
// Everything the athlete has given as feedback, bundled into one JSON file for
// the share sheet. Nothing here leaves the device on its own.

@MainActor
enum FeedbackExport {
    /// Writes the export to a temporary file; nil when it could not be written.
    static func file(athleteName: String?) -> URL? {
        var export: [String: Any] = [
            "exported_at": Date().timeIntervalSince1970,
            "app_version": SettingsView.appVersion,
            "reply_ratings": ReplyRatingStore.shared.all(),
            "workout_feedback": TrainingDataStore.shared.workoutFeedback(),
            "pain_reports": PainReportStore.shared.exportRows,
        ]
        export["athlete_name"] = athleteName
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trigenius-feedback.json")
        guard let data = try? JSONSerialization.data(withJSONObject: export, options: [.prettyPrinted, .sortedKeys]),
              (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }
}
