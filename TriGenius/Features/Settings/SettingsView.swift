import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - Data Source (read) & Write Target

/// A *read* source: where athlete history is pulled from. Multiple can be active
/// at once (parallel read), merged into the local store.
enum DataSource: String, CaseIterable, Identifiable {
    case appleHealth = "Apple Health"
    case garmin = "Garmin"

    var id: String { rawValue }
    var displayName: String { rawValue }
    var icon: String {
        switch self {
        case .garmin: return "antenna.radiowaves.left.and.right"
        case .appleHealth: return "heart.text.square"
        }
    }

    /// The read source behind a stored record's `source` key.
    init?(storedSource: String) {
        switch storedSource {
        case "garmin": self = .garmin
        case "healthkit": self = .appleHealth
        default: return nil
        }
    }
}

/// A *write* target: where the coach's planned workouts are pushed. Exactly one is
/// active at a time; decoupled from the read sources so the athlete can read from
/// Garmin yet schedule onto the Apple Watch (and vice-versa). Extensible — new
/// providers implement `WorkoutSyncTarget` and add a case here.
enum WriteTarget: String, CaseIterable, Identifiable {
    case garmin = "Garmin"
    case appleWatch = "Apple Watch"

    var id: String { rawValue }
    var displayName: String { rawValue }
    /// The token used as the key in `WorkoutRecord.externalRefs`.
    var refKey: String {
        switch self {
        case .garmin: return "garmin"
        case .appleWatch: return "appleWatch"
        }
    }
    /// Apple Watch (WorkoutKit) is iOS/watchOS only.
    var isSupportedOnThisPlatform: Bool {
        switch self {
        case .garmin: return true
        case .appleWatch:
            #if os(iOS)
            return true
            #else
            return false
            #endif
        }
    }
}

// MARK: - Dashboard Layout

/// One configurable dashboard content section (the header is fixed). Declaration
/// order is the default display order.
enum DashboardSection: String, CaseIterable, Identifiable {
    case upNext = "up_next"
    case pinned = "pinned"
    case tissueLoad = "tissue_load"
    case aiInsight = "ai_insight"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .upNext: return "Up Next"
        case .pinned: return "Pinned"
        case .tissueLoad: return "Tissue Load"
        case .aiInsight: return "AI Summary"
        }
    }
    var icon: String {
        switch self {
        case .upNext: return "calendar.day.timeline.left"
        case .pinned: return "pin"
        case .tissueLoad: return "figure.strengthtraining.traditional"
        case .aiInsight: return "sparkles"
        }
    }
}

/// A section's slot in the athlete's dashboard layout: position (array order) +
/// visibility.
struct DashboardLayoutItem: Identifiable, Equatable {
    let section: DashboardSection
    var isVisible: Bool

    var id: DashboardSection { section }
}

// MARK: - App Settings

final class AppSettings: ObservableObject {
    @Published var selectedBackend: BackendType {
        didSet { UserDefaults.standard.set(selectedBackend.rawValue, forKey: "selected_backend") }
    }
    /// Route the Apple Intelligence backend through Private Cloud Compute (the
    /// stronger server model) instead of the on-device model.
    @Published var useAppleCloudCompute: Bool {
        didSet { UserDefaults.standard.set(useAppleCloudCompute, forKey: "use_apple_cloud_compute") }
    }
    /// Whether the athlete has explicitly consented to sending workout + health
    /// data to the third-party cloud AI (OpenRouter). Gates the OpenRouter backend:
    /// on-device Apple Intelligence needs no consent, the cloud path does. Persisted
    /// under `cloud_ai_consent`.
    @Published var cloudAIConsent: Bool {
        didSet { UserDefaults.standard.set(cloudAIConsent, forKey: "cloud_ai_consent") }
    }
    /// Stored in the Keychain (synchronizable via iCloud Keychain), never in
    /// UserDefaults — a secret shouldn't sit in plaintext or ride the CloudKit store.
    @Published var openRouterAPIKey: String {
        didSet { KeychainStore.set(openRouterAPIKey, for: KeychainStore.openRouterAPIKey) }
    }
    /// The OpenRouter model id (e.g. `deepseek/deepseek-v4-flash`).
    @Published var openRouterModel: String {
        didSet { UserDefaults.standard.set(openRouterModel, forKey: "openrouter_model") }
    }
    /// The OpenRouter model id for the dashboard AI summary.
    @Published var openRouterSummaryModel: String {
        didSet { UserDefaults.standard.set(openRouterSummaryModel, forKey: "openrouter_summary_model") }
    }
    /// Give the coach the `web_search` tool (a nested OpenRouter call with the
    /// `web` plugin, billed per search). Persisted under `openrouter_web_search`.
    @Published var openRouterWebSearch: Bool {
        didSet { UserDefaults.standard.set(openRouterWebSearch, forKey: "openrouter_web_search") }
    }
    /// Active read sources (parallel). Persisted as a CSV under `read_sources`.
    @Published var readSources: Set<DataSource> {
        didSet {
            UserDefaults.standard.set(Self.encode(readSources), forKey: "read_sources")
            // Keep the single metrics source pointing at an enabled read source.
            if !readSources.contains(metricsSource), let fallback = readSources.sorted(by: { $0.rawValue < $1.rawValue }).first {
                metricsSource = fallback
            }
        }
    }
    /// Which single provider supplies performance markers AND wellness signals
    /// (FTP, VO₂max, thresholds, weight, sleep/HRV/rHR). Avoids double-sourcing the
    /// same metrics from both providers. Persisted under `metrics_source`.
    @Published var metricsSource: DataSource {
        didSet { UserDefaults.standard.set(metricsSource.rawValue, forKey: "metrics_source") }
    }
    /// Where planned workouts are written. Persisted under `write_target`.
    @Published var writeTarget: WriteTarget {
        didSet { UserDefaults.standard.set(writeTarget.rawValue, forKey: "write_target") }
    }
    /// Part of the Garmin login, so it rides the synchronizable Keychain alongside
    /// the OAuth tokens rather than device-local UserDefaults.
    @Published var garminEmail: String {
        didSet { KeychainStore.set(garminEmail, for: KeychainStore.garminEmail) }
    }
    /// LM Studio server URL (OpenAI-compatible, must include the `/v1` suffix).
    @Published var lmStudioBaseURL: String {
        didSet { UserDefaults.standard.set(lmStudioBaseURL, forKey: "lmstudio_base_url") }
    }
    /// The model id loaded in LM Studio (shown in its "Local Server" panel).
    @Published var lmStudioModel: String {
        didSet { UserDefaults.standard.set(lmStudioModel, forKey: "lmstudio_model") }
    }
    /// Developer toggle: surface hidden tool calls in the chat and log prompts to
    /// the console. Read live by `CoachBrain.isDebugEnabled`.
    @Published var debugMode: Bool {
        didSet { UserDefaults.standard.set(debugMode, forKey: "debug_mode") }
    }
    /// Whether the athlete opted into proactive background notifications. Read by
    /// `BackgroundCoordinator` (which runs outside the SwiftUI environment) via
    /// `proactiveNotificationsKey`.
    @Published var proactiveNotifications: Bool {
        didSet { UserDefaults.standard.set(proactiveNotifications, forKey: Self.proactiveNotificationsKey) }
    }
    static let proactiveNotificationsKey = "proactive_notifications"
    /// Dashboard section order + visibility (`DashboardLayoutView`). Persisted as an
    /// order-preserving CSV under `dashboard_sections`, hidden sections prefixed `-`.
    /// Hiding the AI summary also skips its LLM call (the card is off by default — it
    /// costs a call per load).
    @Published var dashboardLayout: [DashboardLayoutItem] {
        didSet {
            UserDefaults.standard.set(Self.encode(dashboardLayout), forKey: Self.dashboardSectionsKey)
            AthleteSettingsSync.layoutDidChange()
        }
    }
    static let dashboardSectionsKey = "dashboard_sections"
    /// The cards of the dashboard's Pinned section, in order — a CSV of `StatCard` ids.
    @Published var pinnedCards: [StatCard] {
        didSet {
            UserDefaults.standard.set(pinnedCards.map(\.id).joined(separator: ","), forKey: Self.dashboardPinnedKey)
            AthleteSettingsSync.layoutDidChange()
        }
    }
    static let dashboardPinnedKey = "dashboard_pinned"
    /// How much of an over-delivered discipline's surplus TSS credits the other
    /// weekly rings (0 = strict per-discipline, 1 = fully fungible). Read by
    /// `BackgroundCoordinator` (outside SwiftUI) via `storedCreditFactor()`.
    @Published var crossTrainingCreditFactor: Double {
        didSet { UserDefaults.standard.set(crossTrainingCreditFactor, forKey: Self.crossTrainingCreditKey) }
    }
    static let crossTrainingCreditKey = "cross_training_credit"
    static let defaultCrossTrainingCredit = 0.5

    /// Derive cycling FTP from the critical-power estimate (`CriticalPowerEstimate.ftp`),
    /// for watches that never compute one. Off by default — it replaces the synced value,
    /// so the athlete opts in. Read by `TrainingDataStore` (outside SwiftUI) via
    /// `estimateFTPFromCPKey`.
    @Published var estimateFTPFromCP: Bool {
        didSet {
            UserDefaults.standard.set(estimateFTPFromCP, forKey: Self.estimateFTPFromCPKey)
            AthleteSettingsSync.didChange()
        }
    }
    static let estimateFTPFromCPKey = "estimate_ftp_from_cp"

    /// Estimate cycling critical power and W′ from rides (`CriticalPowerEstimate`). No
    /// source reports either, so the switch only decides whether they are shown. Read by
    /// `TrainingDataStore` via `estimateCPFromRidesKey`.
    @Published var estimateCPFromRides: Bool {
        didSet {
            UserDefaults.standard.set(estimateCPFromRides, forKey: Self.estimateCPFromRidesKey)
            AthleteSettingsSync.didChange()
        }
    }
    static let estimateCPFromRidesKey = "estimate_cp_from_rides"

    /// Reconstruct cycling VO₂max from submaximal rides (`VO2maxEstimate`). Separate
    /// from the FTP switch because the two are independently useful: a watch may report
    /// a VO₂max worth keeping while its FTP is a placeholder, or the reverse.
    @Published var estimateVO2maxFromRides: Bool {
        didSet {
            UserDefaults.standard.set(estimateVO2maxFromRides, forKey: Self.estimateVO2maxFromRidesKey)
            AthleteSettingsSync.didChange()
        }
    }
    static let estimateVO2maxFromRidesKey = "estimate_vo2max_from_rides"

    /// Derive LTHR from the athlete's max HR plus sustained efforts in their history
    /// (`LTHREstimate`), for watches that never detect one. Off by default; when on it
    /// *replaces* the source's LTHR, which is the point — the stored one is typically
    /// absent or a hand-entered placeholder. Read by `TrainingDataStore` via
    /// `estimateLTHRFromHRMaxKey`.
    @Published var estimateLTHRFromHRMax: Bool {
        didSet {
            UserDefaults.standard.set(estimateLTHRFromHRMax, forKey: Self.estimateLTHRFromHRMaxKey)
            AthleteSettingsSync.didChange()
        }
    }
    static let estimateLTHRFromHRMaxKey = "estimate_lthr_from_hrmax"

    /// Reconstruct the **cycling** threshold HR from power-gated rides (`LTHREstimate`
    /// with `Gate.power`). A separate value, not a variant of the running one: cycling
    /// LTHR runs 5–10 bpm lower in the same athlete, and no watch publishes it — Garmin's
    /// is Firstbeat's, detected while running. Read by `TrainingDataStore` via
    /// `estimateCyclingLTHRFromRidesKey`.
    @Published var estimateCyclingLTHRFromRides: Bool {
        didSet {
            UserDefaults.standard.set(estimateCyclingLTHRFromRides,
                                      forKey: Self.estimateCyclingLTHRFromRidesKey)
            AthleteSettingsSync.didChange()
        }
    }
    static let estimateCyclingLTHRFromRidesKey = "estimate_cycling_lthr_from_rides"

    /// Reconstruct the running threshold pace from ordinary runs (`LTPaceEstimate`),
    /// for watches that report none or a broken one. Off by default; when on it
    /// *replaces* the source's value. Needs max HR and resting HR. Read by
    /// `TrainingDataStore` via `estimateLTPaceFromRunsKey`.
    @Published var estimateLTPaceFromRuns: Bool {
        didSet {
            UserDefaults.standard.set(estimateLTPaceFromRuns, forKey: Self.estimateLTPaceFromRunsKey)
            AthleteSettingsSync.didChange()
        }
    }
    static let estimateLTPaceFromRunsKey = "estimate_lt_pace_from_runs"

    /// Reconstruct running VO2max from ordinary runs. The same MAS the threshold pace
    /// rests on, read through the ACSM running economy equation — one reconstruction in
    /// two units, so the two can never describe different athletes. Separate from the
    /// pace opt-in because a watch that reports a usable VO2max may still report no
    /// threshold pace, and vice versa.
    @Published var estimateRunningVO2maxFromRuns: Bool {
        didSet {
            UserDefaults.standard.set(estimateRunningVO2maxFromRuns,
                                      forKey: Self.estimateRunningVO2maxFromRunsKey)
            AthleteSettingsSync.didChange()
        }
    }
    static let estimateRunningVO2maxFromRunsKey = "estimate_running_vo2max_from_runs"

    /// The athlete's own LT speed as a fraction of reconstructed MAS. Unlike the
    /// cycling constant this is a property of the athlete — the two reference athletes
    /// differ by 8.4 %, worth 21 s/km — so it is an input rather than a constant.
    /// 0 means derive it from the resolved LTHR, which is what an athlete who has never
    /// run a threshold test should stay on.
    @Published var ltPaceFractionOfMAS: Double {
        didSet {
            UserDefaults.standard.set(ltPaceFractionOfMAS, forKey: Self.ltPaceFractionOfMASKey)
            AthleteSettingsSync.didChange()
        }
    }
    static let ltPaceFractionOfMASKey = "lt_pace_fraction_of_mas"

    /// Read straight from defaults for `TrainingDataStore`, which resolves thresholds
    /// off the main actor's settings object.
    static var storedLTPaceFraction: Double? {
        let v = UserDefaults.standard.double(forKey: ltPaceFractionOfMASKey)
        return v > 0 ? v : nil
    }

    typealias OpenRouterModel = (model: String, reasoningEffort: String)

    /// A curated shortlist of tool-capable OpenRouter model ids, each fixed to the
    /// `reasoning.effort` it always runs at. OpenRouter exposes hundreds; these
    /// are the ones worth defaulting to for the coach.
    static let availableOpenRouterModels: [OpenRouterModel] = [
        ("openrouter/auto", "medium"),
        ("z-ai/glm-5.3", "low"),
        ("google/gemini-3.8-flash", "medium"),
        ("openai/gpt-6-luna", "max"),
        ("z-ai/glm-5.3-flash", "medium"),
        ("xiaomi/mimo-v2.6-pro", "medium")
    ]

    /// The dashboard AI summary's models, same pairing; the first entry is the default.
    static let availableSummaryModels: [OpenRouterModel] = [
        ("z-ai/glm-5.3", "low"),
        ("z-ai/glm-5.3-flash", "low"),
        ("google/gemini-3.8-flash", "low"),
        ("openrouter/auto", "low")
    ]

    static func openRouterReasoningEffort(for model: String) -> String? {
        availableOpenRouterModels.first { $0.model == model }?.reasoningEffort
    }

    init() {
        openRouterAPIKey = KeychainStore.string(for: KeychainStore.openRouterAPIKey) ?? ""
        let savedBackend = UserDefaults.standard.string(forKey: "selected_backend") ?? ""
        // Default to the privacy-safe on-device backend; cloud AI is an explicit,
        // consented opt-in.
        selectedBackend = BackendType(rawValue: savedBackend) ?? .appleIntelligence
        useAppleCloudCompute = UserDefaults.standard.bool(forKey: "use_apple_cloud_compute")
        cloudAIConsent = UserDefaults.standard.bool(forKey: "cloud_ai_consent")
        openRouterModel = Self.storedOpenRouterModel()
        openRouterSummaryModel = UserDefaults.standard.string(forKey: "openrouter_summary_model") ?? Self.availableSummaryModels[0].model
        openRouterWebSearch = UserDefaults.standard.bool(forKey: "openrouter_web_search")
        estimateFTPFromCP = UserDefaults.standard.bool(forKey: Self.estimateFTPFromCPKey)
        estimateCPFromRides = UserDefaults.standard.bool(forKey: Self.estimateCPFromRidesKey)
        estimateVO2maxFromRides = UserDefaults.standard.bool(forKey: Self.estimateVO2maxFromRidesKey)
        estimateLTHRFromHRMax = UserDefaults.standard.bool(forKey: Self.estimateLTHRFromHRMaxKey)
        estimateCyclingLTHRFromRides = UserDefaults.standard.bool(forKey: Self.estimateCyclingLTHRFromRidesKey)
        estimateLTPaceFromRuns = UserDefaults.standard.bool(forKey: Self.estimateLTPaceFromRunsKey)
        estimateRunningVO2maxFromRuns = UserDefaults.standard.bool(forKey: Self.estimateRunningVO2maxFromRunsKey)
        ltPaceFractionOfMAS = UserDefaults.standard.double(forKey: Self.ltPaceFractionOfMASKey)
        readSources = Self.loadReadSources()
        metricsSource = Self.loadMetricsSource()
        writeTarget = Self.loadWriteTarget()
        garminEmail = KeychainStore.string(for: KeychainStore.garminEmail) ?? ""
        lmStudioBaseURL = UserDefaults.standard.string(forKey: "lmstudio_base_url") ?? "http://localhost:1234/v1"
        lmStudioModel = UserDefaults.standard.string(forKey: "lmstudio_model") ?? "local-model"
        debugMode = UserDefaults.standard.bool(forKey: "debug_mode")
        proactiveNotifications = UserDefaults.standard.bool(forKey: Self.proactiveNotificationsKey)
        dashboardLayout = Self.loadDashboardLayout()
        pinnedCards = Self.loadPinnedCards()
        crossTrainingCreditFactor = Self.loadCreditFactor()
    }

    /// Re-read the settings another device changed (`AthleteSettingsSync`). The
    /// setters below write straight back to the same defaults, which is idempotent —
    /// the values are already the ones being read.
    func reloadAthleteSettings() {
        estimateFTPFromCP = UserDefaults.standard.bool(forKey: Self.estimateFTPFromCPKey)
        estimateCPFromRides = UserDefaults.standard.bool(forKey: Self.estimateCPFromRidesKey)
        estimateVO2maxFromRides = UserDefaults.standard.bool(forKey: Self.estimateVO2maxFromRidesKey)
        estimateLTHRFromHRMax = UserDefaults.standard.bool(forKey: Self.estimateLTHRFromHRMaxKey)
        estimateCyclingLTHRFromRides = UserDefaults.standard.bool(forKey: Self.estimateCyclingLTHRFromRidesKey)
        estimateLTPaceFromRuns = UserDefaults.standard.bool(forKey: Self.estimateLTPaceFromRunsKey)
        estimateRunningVO2maxFromRuns = UserDefaults.standard.bool(forKey: Self.estimateRunningVO2maxFromRunsKey)
        ltPaceFractionOfMAS = UserDefaults.standard.double(forKey: Self.ltPaceFractionOfMASKey)
    }

    /// Re-read the dashboard layout another device changed (`AthleteSettingsSync`).
    func reloadDashboardLayout() {
        dashboardLayout = Self.loadDashboardLayout()
        pinnedCards = Self.loadPinnedCards()
    }

    func togglePin(_ card: StatCard) {
        if pinnedCards.contains(card) { pinnedCards.removeAll { $0 == card } } else { pinnedCards.append(card) }
    }

    /// Whether a dashboard section is currently shown.
    func isVisible(_ section: DashboardSection) -> Bool {
        dashboardLayout.first { $0.section == section }?.isVisible ?? false
    }

    /// The cross-training credit factor, defaulting to 0.5 when never set (a bare
    /// `double(forKey:)` returns 0, which would silently disable the feature).
    private static func loadCreditFactor() -> Double {
        UserDefaults.standard.object(forKey: crossTrainingCreditKey) as? Double ?? defaultCrossTrainingCredit
    }
    /// Credit factor as seen by non-SwiftUI callers (the background widget refresh).
    static func storedCreditFactor() -> Double { loadCreditFactor() }

    // MARK: - Dashboard-layout persistence

    private static func encode(_ layout: [DashboardLayoutItem]) -> String {
        layout.map { ($0.isVisible ? "" : "-") + $0.section.rawValue }.joined(separator: ",")
    }

    private static func loadDashboardLayout() -> [DashboardLayoutItem] {
        var items: [DashboardLayoutItem] = []
        if let csv = UserDefaults.standard.string(forKey: dashboardSectionsKey), !csv.isEmpty {
            for token in csv.split(separator: ",") {
                let hidden = token.hasPrefix("-")
                guard let section = DashboardSection(rawValue: String(hidden ? token.dropFirst() : token)) else { continue }
                items.append(DashboardLayoutItem(section: section, isVisible: !hidden))
            }
        } else {
            // First run: everything visible except the opt-in AI summary.
            items = DashboardSection.allCases.map { DashboardLayoutItem(section: $0, isVisible: $0 != .aiInsight) }
        }
        // Sections the app gained after the layout was stored surface at the end.
        let known = Set(items.map(\.section))
        items += DashboardSection.allCases.filter { !known.contains($0) }.map { DashboardLayoutItem(section: $0, isVisible: true) }
        return items
    }

    private static func loadPinnedCards() -> [StatCard] {
        guard let csv = UserDefaults.standard.string(forKey: dashboardPinnedKey) else { return StatCard.defaultPinned }
        return csv.split(separator: ",").compactMap { StatCard(stored: String($0)) }
    }

    // MARK: - Read-source / write-target persistence

    private static func encode(_ sources: Set<DataSource>) -> String {
        sources.map(\.rawValue).sorted().joined(separator: ",")
    }

    private static func loadReadSources() -> Set<DataSource> {
        if let csv = UserDefaults.standard.string(forKey: "read_sources"), !csv.isEmpty {
            return Set(csv.split(separator: ",").compactMap { DataSource(rawValue: String($0)) })
        }
        // First run after the read/write split: seed from the legacy single source.
        let legacy = UserDefaults.standard.string(forKey: "data_source") ?? ""
        return [DataSource(rawValue: legacy) ?? .appleHealth]
    }

    /// The single metrics provider, clamped to an enabled read source. Defaults to
    /// Garmin when it's enabled (richer metric history), else Apple Health.
    private static func loadMetricsSource() -> DataSource {
        let enabled = loadReadSources()
        if let raw = UserDefaults.standard.string(forKey: "metrics_source"),
           let s = DataSource(rawValue: raw), enabled.contains(s) {
            return s
        }
        if enabled.contains(.garmin) { return .garmin }
        return enabled.sorted(by: { $0.rawValue < $1.rawValue }).first ?? .appleHealth
    }

    private static func loadWriteTarget() -> WriteTarget {
        if let raw = UserDefaults.standard.string(forKey: "write_target"),
           let t = WriteTarget(rawValue: raw), t.isSupportedOnThisPlatform {
            return t
        }
        // Default: keep writing to Garmin if that was the legacy source and it's
        // available; otherwise prefer the Apple Watch where supported.
        let legacy = UserDefaults.standard.string(forKey: "data_source") ?? ""
        if legacy == DataSource.garmin.rawValue { return .garmin }
        return WriteTarget.appleWatch.isSupportedOnThisPlatform ? .appleWatch : .garmin
    }

    /// Read sources as seen by non-SwiftUI callers (background refresh, coordinator).
    static func storedReadSources() -> Set<DataSource> { loadReadSources() }
    /// The metrics provider as seen by non-SwiftUI callers (the sync coordinator).
    static func storedMetricsSource() -> DataSource { loadMetricsSource() }
    /// Write target as seen by non-SwiftUI callers.
    static func storedWriteTarget() -> WriteTarget { loadWriteTarget() }
    /// OpenRouter model id as seen by non-SwiftUI callers (the web_search tool —
    /// read at execute time, so a model change applies without re-registering).
    static func storedOpenRouterModel() -> String {
        UserDefaults.standard.string(forKey: "openrouter_model") ?? availableOpenRouterModels[0].model
    }

    var isConfigured: Bool {
        switch selectedBackend {
        case .openRouter: return cloudAIConsent && !openRouterAPIKey.isEmpty
        case .appleIntelligence: return true
        case .lmStudio: return !lmStudioBaseURL.isEmpty
        }
    }

    func makeBackend() -> LLMBackend {
        makeBackend(openRouterModel: openRouterModel, reasoningEffort: Self.openRouterReasoningEffort(for: openRouterModel))
    }

    /// The dashboard AI summary's backend: the active one, on its own model when that's OpenRouter.
    func makeSummaryBackend() -> LLMBackend {
        let effort = Self.availableSummaryModels.first { $0.model == openRouterSummaryModel }?.reasoningEffort
        return makeBackend(openRouterModel: openRouterSummaryModel, reasoningEffort: effort)
    }

    private func makeBackend(openRouterModel model: String, reasoningEffort: String?) -> LLMBackend {
        switch selectedBackend {
        case .openRouter:
            return OpenAICompatibleBackend(
                displayName: BackendType.openRouter.rawValue,
                baseURL: OpenAICompatibleBackend.openRouterBaseURL,
                apiKey: openRouterAPIKey,
                extraHeaders: OpenAICompatibleBackend.openRouterHeaders,
                model: model,
                reasoningEffort: reasoningEffort
            )
        case .appleIntelligence:
            return AppleFoundationModelBackend(useCloud: useAppleCloudCompute)
        case .lmStudio:
            return OpenAICompatibleBackend(
                displayName: BackendType.lmStudio.rawValue,
                baseURL: lmStudioBaseURL,
                model: lmStudioModel,
                timeout: 300
            )
        }
    }
}

// MARK: - Settings View

/// The settings hub: each row names a sub-page and shows that page's current state,
/// so nothing is configured on the root itself.
struct SettingsView: View {
    let brain: CoachBrain
    @ObservedObject var settings: AppSettings
    @ObservedObject var memory: CoachMemory
    let onBackendChanged: () -> Void

    @ObservedObject private var reminders = ReminderStore.shared
    @State private var garminConnected = true
    @State private var calendarAccess = CalendarService.shared.accessState
    @State private var showClearDataConfirm = false
    #if DEBUG
    @State private var showClearDBConfirm = false
    @State private var showDeletePerfConfirm = false
    @State private var showDeleteMaxHRConfirm = false
    @State private var plannedTSSRecomputeCount: Int?
    #endif

    var body: some View {
        List {
            Section("Connect") {
                row("Connections", icon: "arrow.triangle.2.circlepath",
                    value: garminMissing ? "Garmin not connected"
                        : settings.readSources.map(\.displayName).sorted().joined(separator: " · "),
                    warning: garminMissing) {
                    ConnectionsView(settings: settings, onBackendChanged: onBackendChanged)
                }
                row("Calendar", icon: "calendar", value: calendarValue, warning: calendarAccess == .denied) {
                    CalendarSettingsView()
                }
            }

            Section("Athlete") {
                row("Profile", icon: "person", value: memory.userProfile.name ?? "Not set") {
                    AthleteProfileView(memory: memory)
                }
                row("Performance", icon: "gauge.with.dots.needle.67percent") {
                    PerformanceSettingsView(settings: settings)
                }
                row("Weekly targets", icon: "chart.pie", value: sportSplitValue) {
                    WeeklyTargetsView(memory: memory, settings: settings)
                }
                row("Strength profile", icon: "dumbbell",
                    value: memory.sportProgress.progress(for: "strength").strengthProfile.place?.label ?? "Set up") {
                    StrengthProfileView(memory: memory)
                }
            }

            Section("Coach") {
                row("AI model", icon: "sparkles", value: aiModelIssue ?? settings.selectedBackend.displayName,
                    warning: aiModelIssue != nil) {
                    AIModelSettingsView(settings: settings, onBackendChanged: onBackendChanged)
                }
                row("Notifications", icon: "bell.badge", value: notificationsValue) {
                    NotificationSettingsView(settings: settings)
                }
            }

            Section("App") {
                row("Dashboard layout", icon: "rectangle.grid.1x2") {
                    DashboardLayoutView(settings: settings)
                }
            }

            // Privacy & Data — user-facing controls Apple review expects: the
            // privacy policy, a medical disclaimer, and full data deletion.
            Section {
                Link(destination: URL(string: Self.privacyPolicyURL)!) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
                row("Feedback", icon: "hand.thumbsup", value: feedbackValue) {
                    FeedbackView(athleteName: memory.userProfile.name)
                }
                Button(role: .destructive) {
                    showClearDataConfirm = true
                } label: {
                    Label("Delete all my data", systemImage: "trash")
                }
                .alert("Delete all my data?", isPresented: $showClearDataConfirm) {
                    Button("Delete everything", role: .destructive) {
                        Task { await deleteAllData() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Removes all synced workouts, performance metrics and scheduled workouts (locally and from your iCloud sync), resets your athlete profile, and signs out of Garmin. This cannot be undone.")
                }
            } header: {
                Text("Privacy & Data")
            } footer: {
                Text("TriGenius is not a medical device. Its coaching is informational only — always consult a doctor before making training or health decisions.")
            }

            #if DEBUG
            // Developer section — DEBUG builds only, never shipped.
            Section {
                Toggle(isOn: $settings.debugMode) {
                    Label("Debug Mode", systemImage: "ladybug")
                }
                if settings.debugMode {
                    NavigationLink {
                        ReminderTestView()
                    } label: {
                        Label("Test Reminders", systemImage: "bell.badge.waveform")
                    }
                    NavigationLink {
                        ToolDebugView(brain: brain)
                    } label: {
                        Label("Tool Runner", systemImage: "wrench.and.screwdriver")
                    }
                    NavigationLink {
                        SystemPromptDebugView(brain: brain)
                    } label: {
                        Label("System Prompt", systemImage: "text.alignleft")
                    }
                    NavigationLink {
                        DashboardInsightPromptDebugView(
                            context: DashboardContext(
                                readSources: settings.readSources,
                                weeklyStructure: memory.weeklyStructure,
                                makeBackend: settings.makeSummaryBackend,
                                aiInsightEnabled: settings.isVisible(.aiInsight)
                            )
                        )
                    } label: {
                        Label("Dashboard Insight Prompt", systemImage: "sparkles")
                    }
                    NavigationLink {
                        MemoryDebugView(memory: memory)
                    } label: {
                        Label("Storage (coach_memory.json)", systemImage: "curlybraces")
                    }
                    NavigationLink {
                        ReportsDebugView()
                    } label: {
                        Label("Reports", systemImage: "exclamationmark.bubble")
                    }
                }
                Button {
                    plannedTSSRecomputeCount = TrainingDataStore.shared.recomputePlannedTSS()
                } label: {
                    Label("Recompute planned TSS", systemImage: "arrow.triangle.2.circlepath")
                }
                .alert(
                    "Planned TSS recomputed",
                    isPresented: Binding(
                        get: { plannedTSSRecomputeCount != nil },
                        set: { if !$0 { plannedTSSRecomputeCount = nil } }
                    )
                ) {
                    Button("OK") { plannedTSSRecomputeCount = nil }
                } message: {
                    Text("\(plannedTSSRecomputeCount ?? 0) workout(s) updated against the current thresholds.")
                }
                Button(role: .destructive) {
                    showClearDBConfirm = true
                } label: {
                    Label("Clear local database", systemImage: "externaldrive.badge.xmark")
                }
                .alert("Clear local database?", isPresented: $showClearDBConfirm) {
                    Button("Clear", role: .destructive) {
                        TrainingDataStore.shared.deleteAllData()
                        DataSyncCoordinator.shared.resetSyncState()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Deletes all synced workouts, performance metrics and scheduled workouts from the local database and resets the sync state. Your profile and settings are kept; data re-syncs on next launch.")
                }
                Button(role: .destructive) {
                    showDeletePerfConfirm = true
                } label: {
                    Label("Delete historical performance data", systemImage: "chart.line.downtrend.xyaxis")
                }
                .alert("Delete historical performance data?", isPresented: $showDeletePerfConfirm) {
                    Button("Delete", role: .destructive) {
                        TrainingDataStore.shared.deletePerformanceMetrics()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Removes the stored performance history (FTP, VO₂max, thresholds, zones, weight). Daily wellness (sleep, resting HR, HRV) and your activities are kept; values re-sync from Garmin on the next sync or backfill.")
                }
                Button(role: .destructive) {
                    showDeleteMaxHRConfirm = true
                } label: {
                    Label("Delete max HR history", systemImage: "heart.slash")
                }
                .alert("Delete max HR history?", isPresented: $showDeleteMaxHRConfirm) {
                    Button("Delete", role: .destructive) {
                        TrainingDataStore.shared.deleteMetricSeries("max_hr")
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Removes every stored max-HR reading. Garmin sends max HR as a current setting with no date of its own, so a wrong value stays on the days it was synced and no resync rewrites it — clearing lets the next sync, or your own entry, stand alone. LTHR and threshold pace both depend on it.")
                }
            } header: {
                Text("Developer")
            } footer: {
                Text("Debug mode shows the coach's hidden tool calls as messages in the chat and logs the full prompt to the console.")
            }
            #endif

            Section("About") {
                LabeledContent("TriGenius", value: "AI Triathlon Coach")
                LabeledContent("Version", value: Self.appVersion)
            }
        }
        .navigationTitle("Settings")
        .task {
            calendarAccess = CalendarService.shared.accessState
            garminConnected = await GarminAuth.shared.isAuthenticated
        }
    }

    private func row<Destination: View>(_ title: String, icon: String, value: String? = nil, warning: Bool = false,
                                        @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            LabeledContent {
                Text(value ?? "").foregroundStyle(warning ? Theme.Palette.warning : Color.secondary)
            } label: {
                Label(title, systemImage: icon)
            }
        }
    }

    // MARK: - Row values

    private var feedbackValue: String {
        let count = ReplyRatingStore.shared.ids.count
        return count == 1 ? "1 rating" : "\(count) ratings"
    }

    private var garminMissing: Bool {
        !garminConnected && (settings.readSources.contains(.garmin) || settings.writeTarget == .garmin)
    }

    private var calendarValue: String {
        switch calendarAccess {
        case .authorized: "On"
        case .notDetermined: "Not set up"
        case .denied: "Access denied"
        }
    }

    private var sportSplitValue: String? {
        let ratio = WeeklyTargetsView.normalized(memory.weeklyStructure.sportRatio)
        guard !ratio.isEmpty else { return nil }
        return SportFamily.triathlon.map { String(Int(((ratio[$0] ?? 0) * 100).rounded())) }
            .joined(separator: " / ") + " %"
    }

    /// What still keeps the selected backend from answering, if anything.
    private var aiModelIssue: String? {
        switch settings.selectedBackend {
        case .openRouter where settings.openRouterAPIKey.isEmpty: "API key required"
        case .lmStudio where settings.lmStudioBaseURL.isEmpty: "Server URL required"
        default: nil
        }
    }

    private var notificationsValue: String {
        let count = reminders.rules.filter(\.enabled).count
        if count == 0 { return settings.proactiveNotifications ? "Form alerts" : "Off" }
        return count == 1 ? "1 reminder" : "\(count) reminders"
    }

    /// Full user-data erase for the Privacy & Data section (Guideline 5.1.1-v):
    /// every piece of personal data and every consent. Clears the local +
    /// CloudKit-mirrored training/ATP time series and coach memory, wipes the
    /// ignored-workout blacklist, signs out of Garmin, removes the OpenRouter key,
    /// and revokes cloud-AI consent (reverting the coach to on-device). Non-personal
    /// UI preferences in UserDefaults are kept.
    private func deleteAllData() async {
        TrainingDataStore.shared.deleteTrainingAndATP()
        DataSyncCoordinator.shared.resetSyncState()
        memory.reset()
        ReplyRatingStore.shared.deleteAll()
        PainReportStore.shared.deleteAll()
        IgnoredWorkouts.clearAll()
        await GarminAuth.shared.logout()
        settings.garminEmail = ""
        settings.openRouterAPIKey = ""
        settings.cloudAIConsent = false
        settings.selectedBackend = .appleIntelligence
        onBackendChanged()
    }

    static let privacyPolicyURL = "https://trigenius.narica.net/privacy"

    /// Marketing version + build, e.g. "0.0.3 (13)".
    static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }
}

// MARK: - Athlete Profile

/// What the coach knows the athlete by. Read-only: the coach keeps it from the chat.
struct AthleteProfileView: View {
    @ObservedObject var memory: CoachMemory
    @State private var showResetConfirm = false

    var body: some View {
        List {
            Section {
                LabeledContent("Name", value: memory.userProfile.name ?? "—")
                if !memory.userProfile.goals.isEmpty {
                    LabeledContent("Goals", value: memory.userProfile.goals.joined(separator: ", "))
                }
            } footer: {
                Text("Your coach fills this in from your conversations — tell it when something changes.")
            }

            Section {
                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    Label("Reset profile", systemImage: "trash")
                }
                .alert("Delete athlete profile?", isPresented: $showResetConfirm) {
                    Button("Delete", role: .destructive) {
                        memory.updateProfile { $0 = UserProfile() }
                        memory.updateWeeklyStructure { $0 = WeeklyStructure() }
                        memory.updatePreferences { $0 = AthletePreferences() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Deletes your profile, weekly structure and preferences. Your workouts are kept.")
                }
            }
        }
        .navigationTitle("Profile")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Garmin Login Section

struct GarminLoginSection: View {
    @ObservedObject var settings: AppSettings

    @State private var password = ""
    @State private var mfaCode = ""
    @State private var needsMFA = false
    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var isError = false
    @State private var isConnected = false

    var body: some View {
        Group {
            if isConnected {
                Label("Connected to Garmin", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.Palette.success)
                    .font(.caption)
                if !settings.garminEmail.isEmpty {
                    Text(settings.garminEmail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    Task { await logout() }
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } else {
                TextField("Garmin email", text: $settings.garminEmail)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    #endif
                    .textContentType(.username)
                    .disableAutocorrection(true)

                SecureField("Password", text: $password)
                    .textContentType(.password)

                if needsMFA {
                    TextField("MFA code (from email)", text: $mfaCode)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    Button {
                        Task { await submitMFA() }
                    } label: {
                        Label("Confirm code", systemImage: "key.fill")
                    }
                    .disabled(isWorking || mfaCode.isEmpty)
                } else {
                    Button {
                        Task { await login() }
                    } label: {
                        if isWorking {
                            ProgressView()
                        } else {
                            Label("Connect to Garmin", systemImage: "link")
                        }
                    }
                    .disabled(isWorking || settings.garminEmail.isEmpty || password.isEmpty)
                }
            }

            if let statusMessage {
                Label(statusMessage, systemImage: isError ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundStyle(isError ? .orange : .secondary)
                    .font(.caption)
            }
        }
        .task { isConnected = await GarminAuth.shared.isAuthenticated }
    }

    private func login() async {
        isWorking = true
        // Garmin's Cloudflare WAF forces a 5–20s delay between the sign-in page
        // load and the credential submit, so the login deliberately takes a while.
        statusMessage = "Connecting to Garmin… this takes about 5–20 seconds."
        isError = false
        defer { isWorking = false }
        do {
            try await GarminAuth.shared.login(email: settings.garminEmail, password: password)
            await finishConnected()
        } catch let error as GarminAuthError {
            if case .mfaRequired = error {
                needsMFA = true
                statusMessage = error.errorDescription
                isError = false
            } else {
                statusMessage = error.errorDescription
                isError = true
            }
        } catch {
            statusMessage = error.localizedDescription
            isError = true
        }
    }

    private func submitMFA() async {
        isWorking = true
        statusMessage = nil
        isError = false
        defer { isWorking = false }
        do {
            try await GarminAuth.shared.resumeLogin(code: mfaCode)
            await finishConnected()
        } catch {
            statusMessage = (error as? GarminAuthError)?.errorDescription ?? error.localizedDescription
            isError = true
        }
    }

    private func finishConnected() async {
        let name = (try? await GarminClient.shared.fullName()) ?? nil
        password = ""
        mfaCode = ""
        needsMFA = false
        isConnected = true
        isError = false
        statusMessage = name.map { "Connected as \($0)" } ?? "Successfully connected."
    }

    private func logout() async {
        await GarminAuth.shared.logout()
        isConnected = false
        statusMessage = "Signed out."
        isError = false
    }
}

// MARK: - Memory Debug View

struct MemoryDebugView: View {
    @ObservedObject var memory: CoachMemory
    @State private var didCopy = false
    @State private var showImporter = false
    @State private var importStatus: String?
    @State private var importFailed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("File path")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(memory.storageFilePath)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)

                if let importStatus {
                    Label(importStatus, systemImage: importFailed ? "exclamationmark.triangle.fill" : "checkmark.circle")
                        .foregroundStyle(importFailed ? .orange : .green)
                        .font(.caption)
                }

                Divider()

                Text(memory.prettyPrintedJSON)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .navigationTitle("coach_memory.json")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            Button {
                showImporter = true
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            Button {
                #if os(iOS)
                UIPasteboard.general.string = memory.prettyPrintedJSON
                #elseif os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(memory.prettyPrintedJSON, forType: .string)
                #endif
                didCopy = true
            } label: {
                Label(didCopy ? "Copied" : "Copy",
                      systemImage: didCopy ? "checkmark" : "doc.on.doc")
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            handleImport(result)
        }
    }

    /// Replace the whole profile from a picked `coach_memory.json`, then seed any
    /// performance scalars it carries (FTP, CSS, …) into the metric time series —
    /// `UserProfile.toDict()` no longer persists those, so they'd be lost otherwise.
    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                try memory.importJSON(data)
                let metrics = DataSyncCoordinator.metrics(fromProfile: memory.userProfile, date: Date())
                TrainingDataStore.shared.ingestMetrics(metrics)
                importFailed = false
                importStatus = "Imported \(url.lastPathComponent)."
            } catch {
                importFailed = true
                importStatus = error.localizedDescription
            }
        case .failure(let error):
            importFailed = true
            importStatus = error.localizedDescription
        }
    }
}

// MARK: - Reports Debug View

/// Lists the locally-filed chat reports with Copy (all reports as text) and a
/// Reset that wipes them — mirroring the coach_memory.json storage screen.
struct ReportsDebugView: View {
    @ObservedObject private var store = ReportStore.shared
    @State private var didCopy = false
    @State private var showResetConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("File path")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(store.storageFilePath)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)

                Divider()

                if store.isEmpty {
                    Text("No reports filed yet. Use the report button in the chat to capture a conversation.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(store.reports.count) report\(store.reports.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(store.exportText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .navigationTitle("Reports")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            Button(role: .destructive) {
                showResetConfirm = true
            } label: {
                Label("Reset", systemImage: "trash")
            }
            .disabled(store.isEmpty)
            Button {
                #if os(iOS)
                UIPasteboard.general.string = store.prettyPrintedJSON
                #elseif os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(store.prettyPrintedJSON, forType: .string)
                #endif
                didCopy = true
            } label: {
                Label(didCopy ? "Copied" : "Copy",
                      systemImage: didCopy ? "checkmark" : "doc.on.doc")
            }
            .disabled(store.isEmpty)
        }
        .alert("Delete all reports?", isPresented: $showResetConfirm) {
            Button("Delete", role: .destructive) { store.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All locally-filed reports will be permanently deleted.")
        }
    }
}

// MARK: - Calendar

struct CalendarSettingsView: View {
    var body: some View {
        List {
            Section {
                CalendarAccessSection()
            } footer: {
                Text("Lets the coach read your calendar's busy/free windows to plan workouts around busy days. Read-only — TriGenius never changes your events.")
            }
        }
        .navigationTitle("Calendar")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// Shows the device-calendar access state and a button to grant it. The coach's
/// `read_calendar_availability` tool also requests access on first use; this just
/// lets the athlete opt in up front.
struct CalendarAccessSection: View {
    @State private var state = CalendarService.shared.accessState
    @State private var isWorking = false

    var body: some View {
        Group {
            switch state {
            case .authorized:
                Label("Calendar access granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.Palette.success)
                    .font(.caption)
                CalendarSelectionList()
            case .notDetermined:
                Button {
                    Task {
                        isWorking = true
                        _ = await CalendarService.shared.requestAccess()
                        state = CalendarService.shared.accessState
                        isWorking = false
                    }
                } label: {
                    if isWorking { ProgressView() }
                    else { Label("Grant calendar access", systemImage: "calendar.badge.plus") }
                }
                .disabled(isWorking)
            case .denied:
                Label("Calendar access denied — enable it in the Settings app.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Palette.warning)
                    .font(.caption)
            }
        }
        .task { state = CalendarService.shared.accessState }
    }
}

// MARK: - Calendar Selection

/// Lets the athlete pick which device calendars the coach should consider.
/// Toggling a calendar off (e.g. a shared family calendar) writes its identifier
/// to `CalendarService.excludedCalendarIdentifiers`; calendars added later are
/// included by default.
private struct CalendarSelectionList: View {
    @State private var calendars: [CalendarInfo] = []
    @State private var excluded: Set<String> = CalendarService.shared.excludedCalendarIdentifiers

    var body: some View {
        Group {
            DisclosureGroup("Calendars considered (\(calendars.count - excluded.count)/\(calendars.count))") {
                ForEach(groupedSources, id: \.self) { source in
                    ForEach(calendars.filter { $0.sourceTitle == source }) { cal in
                        Toggle(isOn: binding(for: cal.id)) {
                            HStack(spacing: Theme.Spacing.s) {
                                Circle()
                                    .fill(Color(hex: cal.colorHex))
                                    .frame(width: 10, height: 10)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(cal.title)
                                    if cal.isSubscribed {
                                        Text("Shared")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .task { calendars = CalendarService.shared.availableCalendars() }
    }

    private var groupedSources: [String] {
        var seen = Set<String>()
        return calendars.compactMap { seen.insert($0.sourceTitle).inserted ? $0.sourceTitle : nil }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { !excluded.contains(id) },
            set: { include in
                if include { excluded.remove(id) } else { excluded.insert(id) }
                CalendarService.shared.excludedCalendarIdentifiers = excluded
            }
        )
    }
}

// MARK: - Re-sync Section

/// Per-source "Re-sync" row: forgets the source's watermark and re-pulls its
/// history, recomputing each activity in place. One instance per enabled read
/// source (Garmin / Apple Health), so the action reads as belonging to that source.
/// Garmin re-pulls `DataSyncCoordinator.deepHistoryDays`; Apple Health re-reads
/// every workout it can see.
struct ReadSourceSyncSection: View {
    let source: DataSource

    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var isError = false

    var body: some View {
        Group {
            Button {
                Task { await runResync() }
            } label: {
                if isWorking {
                    HStack { ProgressView(); Text("Re-syncing…") }
                } else {
                    Label("Re-sync \(source.displayName)", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .disabled(isWorking)

            if isWorking, let p = DataSyncCoordinator.shared.progress, p.total > 0 {
                ProgressView(value: Double(p.done), total: Double(p.total)) {
                    Text("Activity \(p.done) of \(p.total)…")
                }
            }

            if let statusMessage {
                Label(statusMessage, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle")
                    .foregroundStyle(isError ? .orange : .secondary)
                    .font(.caption)
            }
        }
    }

    private func runResync() async {
        isWorking = true
        statusMessage = nil
        defer { isWorking = false }
        if source == .garmin, await GarminAuth.shared.isAuthenticated == false {
            statusMessage = "Connect to Garmin first."
            isError = true
            return
        }
        let count = await DataSyncCoordinator.shared.resync(source: source)
        if let count {
            isError = false
            statusMessage = "Re-synced \(count) activities — TSS recomputed."
        } else {
            isError = true
            statusMessage = source == .garmin ? "Re-sync failed — check your Garmin connection." : "Re-sync failed."
        }
    }
}
