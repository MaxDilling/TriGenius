import Foundation

// MARK: - Garmin Connect API Client
//
// Low-level connectapi layer (bearer auth + endpoint helpers), mirroring the
// subset of the Python `garminconnect.Garmin` methods used by the service.

actor GarminClient {

    static let shared = GarminClient()

    private let host = "https://connectapi.garmin.com"
    private let auth = GarminAuth.shared
    // Live reads must always hit the network: the activity-list GET is a fixed
    // URL, so the default URLCache would serve a stale list within a running
    // process and a freshly-synced activity would only surface after a restart.
    // The store is our real cache; HTTP caching buys nothing here.
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private var cachedDisplayName: String?

    private init() {}

    // MARK: - Core request

    /// Perform a connectapi request, returning the decoded JSON (object/array) or nil.
    func connectapi(
        _ path: String,
        method: String = "GET",
        query: [(String, String)] = [],
        jsonBody: Any? = nil
    ) async throws -> Any? {
        let token = try await auth.validAccessToken()

        var urlString = host + path
        if !query.isEmpty {
            let qs = query.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
            urlString += (path.contains("?") ? "&" : "?") + qs
        }
        guard let url = URL(string: urlString) else { throw GarminAuthError.network("bad url: \(urlString)") }

        var request = URLRequest(url: url)
        request.httpMethod = method.uppercased()
        // Native Android-app headers (matches the DI Bearer auth scheme).
        for (k, v) in auth.nativeHeaders { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60

        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody, options: [])
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GarminAuthError.network("no response") }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GarminAuthError.network("HTTP \(http.statusCode) on \(path): \(body.prefix(160))")
        }
        if data.isEmpty { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }

    // MARK: - Profile / display name

    func displayName() async throws -> String {
        if let cached = cachedDisplayName { return cached }
        let profile = try await connectapi("/userprofile-service/socialProfile") as? [String: Any]
        let name = profile?["displayName"] as? String ?? profile?["userName"] as? String ?? ""
        cachedDisplayName = name
        return name
    }

    func fullName() async throws -> String? {
        let profile = try await connectapi("/userprofile-service/socialProfile") as? [String: Any]
        if let display = profile?["displayName"] as? String { cachedDisplayName = display }
        return profile?["fullName"] as? String
    }

    func clearProfileCache() { cachedDisplayName = nil }

    // MARK: - Activities

    func getActivities(start: Int = 0, limit: Int = 20) async throws -> [[String: Any]] {
        let result = try await connectapi(
            "/activitylist-service/activities/search/activities",
            query: [("start", String(start)), ("limit", String(limit))]
        )
        return result as? [[String: Any]] ?? []
    }

    func getActivitiesByDate(start: String, end: String) async throws -> [[String: Any]] {
        var activities: [[String: Any]] = []
        var offset = 0
        let pageSize = 50
        while true {
            let page = try await connectapi(
                "/activitylist-service/activities/search/activities",
                query: [("startDate", start), ("endDate", end), ("start", String(offset)), ("limit", String(pageSize))]
            ) as? [[String: Any]] ?? []
            if page.isEmpty { break }
            activities.append(contentsOf: page)
            // Advance by the requested window, not by `page.count`: Garmin can
            // return a *short* page mid-range when the date filter trims items
            // that the `limit` already counted, while older activities still
            // remain. Stopping on a short page (page.count < pageSize) would end
            // the backfill early — only an empty page means we're past the range.
            offset += pageSize
        }
        return activities
    }

    func getActivityDetails(id: String, maxChart: Int = 2000, maxPoly: Int = 4000) async throws -> [String: Any] {
        let result = try await connectapi(
            "/activity-service/activity/\(id)/details",
            query: [("maxChartSize", String(maxChart)), ("maxPolylineSize", String(maxPoly))]
        )
        return result as? [String: Any] ?? [:]
    }

    func getActivitySplits(id: String) async throws -> [String: Any] {
        let result = try await connectapi("/activity-service/activity/\(id)/splits")
        return result as? [String: Any] ?? [:]
    }

    // MARK: - Settings

    func getCyclingFtp() async throws -> Any? {
        try await connectapi("/biometric-service/biometric/latestFunctionalThresholdPower/CYCLING")
    }

    // MARK: - Workouts

    func uploadWorkout(_ json: [String: Any]) async throws -> [String: Any]? {
        try await connectapi("/workout-service/workout", method: "POST", jsonBody: json) as? [String: Any]
    }

    func scheduleWorkout(workoutId: String, date: String) async throws {
        _ = try await connectapi("/workout-service/schedule/\(workoutId)", method: "POST", jsonBody: ["date": date])
    }

    /// Remove a single scheduled occurrence by its schedule id (the calendar
    /// item's `id`, distinct from the workout template's `workoutId`). Scheduling
    /// is additive, so a true "move" must delete the old occurrence with this.
    func unscheduleWorkout(scheduleId: String) async throws {
        _ = try await connectapi("/workout-service/schedule/\(scheduleId)", method: "DELETE")
    }

    func deleteWorkout(workoutId: String) async throws {
        _ = try await connectapi("/workout-service/workout/\(workoutId)", method: "DELETE")
    }

    /// Update an existing workout template in place. Garmin expects the full
    /// workout DTO in the body, including the identity fields (`workoutId`,
    /// `ownerId`). The scheduled calendar occurrence keeps its id and date and
    /// automatically reflects the new content, so no reschedule is needed.
    func updateWorkout(workoutId: String, json: [String: Any]) async throws -> [String: Any]? {
        try await connectapi("/workout-service/workout/\(workoutId)", method: "PUT", jsonBody: json) as? [String: Any]
    }

    func getWorkoutDetails(workoutId: String) async throws -> [String: Any]? {
        try await connectapi("/workout-service/workout/\(workoutId)") as? [String: Any]
    }

    /// Fetch a scheduled occurrence by its schedule id. A superset of
    /// `getWorkoutDetails`: embeds the full `workout` object plus the
    /// `associatedActivityId` Garmin sets once the session is completed.
    func getScheduledWorkout(scheduleId: String) async throws -> [String: Any]? {
        try await connectapi("/workout-service/schedule/\(scheduleId)") as? [String: Any]
    }

    func getAdaptiveTrainingPlan(id: Int) async throws -> [String: Any]? {
        try await connectapi("/trainingplan-service/trainingplan/\(id)") as? [String: Any]
    }
}
