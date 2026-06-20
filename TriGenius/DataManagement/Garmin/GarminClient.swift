import Foundation

// MARK: - Garmin Connect API Client
//
// Low-level connectapi layer (bearer auth + endpoint helpers), mirroring the
// subset of the Python `garminconnect.Garmin` methods used by the service.

actor GarminClient {

    static let shared = GarminClient()

    private let host = "https://connectapi.garmin.com"
    private let auth = GarminAuth.shared
    private let session = URLSession(configuration: .default)

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
        let pageSize = 20
        while true {
            let page = try await connectapi(
                "/activitylist-service/activities/search/activities",
                query: [("startDate", start), ("endDate", end), ("start", String(offset)), ("limit", String(pageSize))]
            ) as? [[String: Any]] ?? []
            if page.isEmpty { break }
            activities.append(contentsOf: page)
            offset += pageSize
            if page.count < pageSize { break }
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

    // MARK: - Health / recovery

    func getHrvData(date: String) async throws -> [String: Any]? {
        try await connectapi("/hrv-service/hrv/\(date)") as? [String: Any]
    }

    func getBodyBattery(date: String) async throws -> [[String: Any]] {
        let result = try await connectapi(
            "/wellness-service/wellness/bodyBattery/reports/daily",
            query: [("startDate", date), ("endDate", date)]
        )
        return result as? [[String: Any]] ?? []
    }

    func getSleepData(date: String) async throws -> [String: Any]? {
        let name = try await displayName()
        return try await connectapi(
            "/wellness-service/wellness/dailySleepData/\(name)",
            query: [("date", date), ("nonSleepBufferMinutes", "60")]
        ) as? [String: Any]
    }

    func getTrainingStatus(date: String) async throws -> [String: Any] {
        let result = try await connectapi("/metrics-service/metrics/trainingstatus/aggregated/\(date)")
        return result as? [String: Any] ?? [:]
    }

    // MARK: - Settings

    func getCyclingFtp() async throws -> Any? {
        try await connectapi("/biometric-service/biometric/latestFunctionalThresholdPower/CYCLING")
    }

    /// Best-effort port of get_lactate_threshold(latest=True): returns the
    /// combined speed/heart-rate and power dictionaries the service expects.
    func getLactateThreshold() async throws -> [String: Any]? {
        let speedHR = try await connectapi("/biometric-service/biometric/latestLactateThreshold")
        var heartRate: Int?
        if let entries = speedHR as? [[String: Any]] {
            for entry in entries {
                if let hr = (entry["heartRate"] as? NSNumber)?.intValue { heartRate = hr }
            }
        } else if let dict = speedHR as? [String: Any] {
            heartRate = (dict["heartRate"] as? NSNumber)?.intValue
        }
        guard heartRate != nil else { return nil }
        return ["speed_and_heart_rate": ["heartRate": heartRate as Any], "power": [:]]
    }

    func getUserProfile() async throws -> [String: Any]? {
        try await connectapi("/userprofile-service/userprofile/user-settings") as? [String: Any]
    }

    // MARK: - Workouts

    func uploadWorkout(_ json: [String: Any]) async throws -> [String: Any]? {
        try await connectapi("/workout-service/workout", method: "POST", jsonBody: json) as? [String: Any]
    }

    func scheduleWorkout(workoutId: String, date: String) async throws {
        _ = try await connectapi("/workout-service/schedule/\(workoutId)", method: "POST", jsonBody: ["date": date])
    }

    func deleteWorkout(workoutId: String) async throws {
        _ = try await connectapi("/workout-service/workout/\(workoutId)", method: "DELETE")
    }

    func getWorkoutDetails(workoutId: String) async throws -> [String: Any]? {
        try await connectapi("/workout-service/workout/\(workoutId)") as? [String: Any]
    }

    func getAdaptiveTrainingPlan(id: Int) async throws -> [String: Any]? {
        try await connectapi("/trainingplan-service/trainingplan/\(id)") as? [String: Any]
    }
}
