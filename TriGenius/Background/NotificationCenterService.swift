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

    /// `userInfo` key carrying the deterministic chat prompt to pre-fill (unsent)
    /// when the athlete taps a notification. `nonisolated` so the (nonisolated)
    /// notification-center delegate callbacks can read it.
    nonisolated static let followUpPromptKey = "follow_up_prompt"

    private let center = UNUserNotificationCenter.current()
    /// Retained so the center keeps a strong reference to it (the center's
    /// `delegate` property is weak). Handles both foreground presentation and taps.
    private lazy var delegate = NotificationDelegate(service: self)

    /// Invoked when the athlete taps a notification carrying a follow-up prompt.
    /// Set once at launch (see `TriGeniusApp.setupBrain`) to route into the chat.
    var onNotificationTap: ((String) -> Void)?

    private init() {}

    /// Day-granularity watermark of the last posted notification, so repeated
    /// background runs on the same day don't re-notify the same concern.
    private let lastPostedDayKey = "trigenius.notify.lastPostedDay"

    /// Install the foreground-presentation delegate. Without it, iOS silently
    /// suppresses banners/sound while the app is in the foreground, so test
    /// reminders fired from Settings would `add()` successfully yet never show.
    /// Call once at launch, before any notification is posted.
    func configure() {
        center.delegate = delegate
    }

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
        // Respect the athlete's quiet hours — don't surface the digest at bad times.
        if ReminderStore.shared.isWithinQuietHours(now) { return false }
        // Prefer warnings; fall back to the first info signal.
        guard let signal = signals.first(where: { $0.severity == .warning }) ?? signals.first else { return false }

        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        if let last = lastPostedDay(), cal.isDate(last, inSameDayAs: today) { return false }

        let content = UNMutableNotificationContent()
        content.title = signal.severity == .warning ? "TriGenius — heads up" : "TriGenius"
        content.body = signal.message
        content.sound = .default
        if let prompt = signal.followUpPrompt {
            content.userInfo[Self.followUpPromptKey] = prompt
        }

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

    /// Post an immediate notification with explicit content. Used for dynamic
    /// reminders whose body is composed at delivery time. Per-reminder dedup is
    /// the caller's responsibility (see `ReminderScheduler.dynamicDeliveredToday`).
    /// Returns whether the notification was scheduled.
    @discardableResult
    func post(title: String, body: String, identifier: String, followUpPrompt: String? = nil) async -> Bool {
        guard await isAuthorized else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let followUpPrompt {
            content.userInfo[Self.followUpPromptKey] = followUpPrompt
        }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Developer / testing

    /// Schedule a one-off test notification after a short delay, so the developer
    /// can background the app and confirm OS-side delivery works. Uses a time-
    /// interval trigger (a stand-in for the real calendar trigger). Returns whether
    /// it was scheduled.
    @discardableResult
    func scheduleTest(after seconds: TimeInterval) async -> Bool {
        guard await isAuthorized else { return false }
        let content = UNMutableNotificationContent()
        content.title = "TriGenius — test reminder"
        content.body = "This is a scheduled test reminder."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        let request = UNNotificationRequest(
            identifier: "trigenius.reminder.test.\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        do {
            try await center.add(request)
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

// MARK: - Notification delegate

/// Handles the two notification-center callbacks we care about:
///   • `willPresent` — lets notifications show as a banner (with sound/list) even
///     while the app is in the foreground. iOS suppresses foreground notifications
///     by default unless a delegate opts in here — exactly the case when a reminder
///     is fired from the in-app Test Reminders screen.
///   • `didReceive` — a tap. If the notification carries a follow-up prompt, route
///     it into the chat (pre-filled, unsent) via the service's `onNotificationTap`.
private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private weak var service: NotificationCenterService?

    init(service: NotificationCenterService) {
        self.service = service
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let prompt = userInfo[NotificationCenterService.followUpPromptKey] as? String
        Task { @MainActor in
            if let prompt { service?.onNotificationTap?(prompt) }
            completionHandler()
        }
    }
}
