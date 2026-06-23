import Foundation
import Combine

// MARK: - Report Store
//
// User-initiated bug/feedback reports filed from the chat ("Report" button).
// Each report is a snapshot of the conversation transcript plus an optional
// free-text note and a little context (active backend / data source / app
// version) so the developer can diagnose what the coach did.
//
// Persisted as its own JSON file in Application Support — deliberately NOT part
// of coach_memory.json, so a memory import (CoachMemory.importJSON, a full
// replace) can't wipe filed reports, and the store can offer its own
// copy/reset in Settings, mirroring the coach_memory.json storage screen.

/// One filed report.
struct Report: Identifiable {
    /// One line of the captured conversation.
    struct Line {
        let author: String   // "user" | "coach" | "tool"
        let text: String
        let timestamp: Date

        init(author: String, text: String, timestamp: Date) {
            self.author = author
            self.text = text
            self.timestamp = timestamp
        }

        init?(from d: [String: Any]) {
            guard let author = d["author"] as? String,
                  let text = d["text"] as? String else { return nil }
            self.author = author
            self.text = text
            self.timestamp = (d["timestamp"] as? TimeInterval).map(Date.init(timeIntervalSince1970:)) ?? Date()
        }

        func toDict() -> [String: Any] {
            ["author": author, "text": text, "timestamp": timestamp.timeIntervalSince1970]
        }
    }

    let id: String
    let timestamp: Date
    /// Optional description the athlete typed when filing the report.
    let note: String
    /// Active LLM backend at capture time (raw token, e.g. "gemini").
    let backend: String
    /// Active data source at capture time (raw token, e.g. "garmin").
    let dataSource: String
    let appVersion: String
    /// The conversation transcript at the moment the report was filed.
    let transcript: [Line]

    init(id: String = UUID().uuidString,
         timestamp: Date = Date(),
         note: String,
         backend: String,
         dataSource: String,
         appVersion: String,
         transcript: [Line]) {
        self.id = id
        self.timestamp = timestamp
        self.note = note
        self.backend = backend
        self.dataSource = dataSource
        self.appVersion = appVersion
        self.transcript = transcript
    }

    init?(from d: [String: Any]) {
        guard let id = d["id"] as? String else { return nil }
        self.id = id
        self.timestamp = (d["timestamp"] as? TimeInterval).map(Date.init(timeIntervalSince1970:)) ?? Date()
        self.note = d["note"] as? String ?? ""
        self.backend = d["backend"] as? String ?? ""
        self.dataSource = d["data_source"] as? String ?? ""
        self.appVersion = d["app_version"] as? String ?? ""
        self.transcript = (d["transcript"] as? [[String: Any]])?.compactMap(Line.init(from:)) ?? []
    }

    func toDict() -> [String: Any] {
        [
            "id": id,
            "timestamp": timestamp.timeIntervalSince1970,
            "note": note,
            "backend": backend,
            "data_source": dataSource,
            "app_version": appVersion,
            "transcript": transcript.map { $0.toDict() }
        ]
    }
}

@MainActor
final class ReportStore: ObservableObject {
    static let shared = ReportStore()

    @Published private(set) var reports: [Report]

    private let storageURL: URL

    /// Keep the file bounded so reports can't grow without limit.
    private let maxReports = 100

    // MARK: - Init / persistence

    init(filename: String = "reports.json") {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storageURL = dir.appendingPathComponent(filename)
        reports = []
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = raw["reports"] as? [[String: Any]] else { return }
        reports = arr.compactMap(Report.init(from:))
    }

    private func save() {
        let dict: [String: Any] = ["reports": reports.map { $0.toDict() }]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { return }
        let url = storageURL
        DispatchQueue.global(qos: .utility).async {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Mutation

    /// File a new report. Backend / data source / app version are read from the
    /// current environment so the call site only needs the note + transcript.
    func add(note: String, transcript: [Report.Line]) {
        let report = Report(
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            backend: UserDefaults.standard.string(forKey: "selected_backend") ?? "",
            dataSource: UserDefaults.standard.string(forKey: "data_source") ?? "",
            appVersion: Self.appVersionString,
            transcript: transcript
        )
        reports.insert(report, at: 0)   // newest first
        if reports.count > maxReports {
            reports.removeLast(reports.count - maxReports)
        }
        save()
    }

    /// Wipe all filed reports (the "reset" in Settings).
    func clear() {
        reports.removeAll()
        save()
    }

    var isEmpty: Bool { reports.isEmpty }

    var storageFilePath: String { storageURL.path }

    // MARK: - Export

    private static var appVersionString: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static let lineStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Pretty-printed JSON of every report (for the "Copy" button, mirroring
    /// `CoachMemory.prettyPrintedJSON`).
    var prettyPrintedJSON: String {
        let dict: [String: Any] = ["reports": reports.map { $0.toDict() }]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    /// Human-readable rendering of all reports, for on-screen display.
    var exportText: String {
        guard !reports.isEmpty else { return "No reports filed." }
        return reports.map { report in
            var out = "── Report \(Self.stamp.string(from: report.timestamp)) ──\n"
            out += "backend: \(report.backend)   data: \(report.dataSource)   app: \(report.appVersion)\n"
            if !report.note.isEmpty {
                out += "note: \(report.note)\n"
            }
            out += "\nConversation:\n"
            if report.transcript.isEmpty {
                out += "(empty)\n"
            } else {
                for line in report.transcript {
                    out += "[\(Self.lineStamp.string(from: line.timestamp))] \(line.author): \(line.text)\n"
                }
            }
            return out
        }.joined(separator: "\n\n")
    }
}
