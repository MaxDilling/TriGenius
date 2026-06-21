import Foundation
import UserNotifications

// MARK: - Notification Center Service
//
// Local-notification sink for the ProactiveCoach. Local notifications need no
// special entitlement — only the user's authorization. Posts the highest-
// severity proactive signal as a notification, deduped to at most one per day so
// the athlete isn't spammed by the same concern across repeated background runs.
//
// FEATURES.md "Background execution + push notifications".

@MainActor
final class NotificationCenterService {
    static let shared = NotificationCenterService()

    private let center = UNUserNotificationCenter.current()
    private init() {}

    /// Day-granularity watermark of the last posted notification, so repeated
    /// background runs on the same day don't re-notify the same concern.
    private let lastPostedDayKey = "trigenius.notify.lastPostedDay"

    // MARK: - Authorization

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    var isAuthorized: Bool {
        get async {
            let settings = await center.notificationSettings()
            return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        }
    }

    // MARK: - Posting

    /// Post the most important proactive signal as a notification, at most once
    /// per calendar day. No-op when not authorized, there are no signals, or one
    /// was already posted today. Returns whether a notification was scheduled.
    @discardableResult
    func postDailyDigest(_ signals: [ProactiveSignal], now: Date = Date()) async -> Bool {
        guard await isAuthorized else { return false }
        // Prefer warnings; fall back to the first info signal.
        guard let signal = signals.first(where: { $0.severity == .warning }) ?? signals.first else { return false }

        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        if let last = lastPostedDay(), cal.isDate(last, inSameDayAs: today) { return false }

        let content = UNMutableNotificationContent()
        content.title = signal.severity == .warning ? "TriGenius — heads up" : "TriGenius"
        content.body = signal.message
        content.sound = .default

        // Deliver immediately (nil trigger) — callers invoke this from a
        // background refresh, where "now" is the right time to surface it.
        let request = UNNotificationRequest(
            identifier: "trigenius.proactive.\(today.timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            setLastPostedDay(today)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Watermark

    private func lastPostedDay() -> Date? {
        let t = UserDefaults.standard.double(forKey: lastPostedDayKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    private func setLastPostedDay(_ day: Date) {
        UserDefaults.standard.set(day.timeIntervalSince1970, forKey: lastPostedDayKey)
    }
}
