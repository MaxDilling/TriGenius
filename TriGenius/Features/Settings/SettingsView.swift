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
    case planBanner = "plan_banner"
    case performance = "performance"
    case weeklyTarget = "weekly_target"
    case statistics = "statistics"
    case aiInsight = "ai_insight"
    case upNext = "up_next"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .planBanner: return "Plan Banner"
        case .performance: return "Performance Insights"
        case .weeklyTarget: return "Weekly Target"
        case .statistics: return "Statistics"
        case .aiInsight: return "AI Summary"
        case .upNext: return "Up Next"
        }
    }
    var icon: String {
        switch self {
        case .planBanner: return "flag.checkered"
        case .performance: return "chart.bar.xaxis"
        case .weeklyTarget: return "target"
        case .statistics: return "chart.xyaxis.line"
        case .aiInsight: return "sparkles"
        case .upNext: return "calendar.day.timeline.left"
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
    /// Dashboard section order + visibility (Settings → Dashboard → Dashboard
    /// layout). Persisted as an order-preserving CSV under `dashboard_sections`,
    /// hidden sections prefixed `-`. Hiding the AI summary also skips its LLM call
    /// (the card is off by default — it costs a call per load).
    @Published var dashboardLayout: [DashboardLayoutItem] {
        didSet { UserDefaults.standard.set(Self.encode(dashboardLayout), forKey: "dashboard_sections") }
    }
    /// How much of an over-delivered discipline's surplus TSS credits the other
    /// weekly rings (0 = strict per-discipline, 1 = fully fungible). Read by
    /// `BackgroundCoordinator` (outside SwiftUI) via `storedCreditFactor()`.
    @Published var crossTrainingCreditFactor: Double {
        didSet { UserDefaults.standard.set(crossTrainingCreditFactor, forKey: Self.crossTrainingCreditKey) }
    }
    static let crossTrainingCreditKey = "cross_training_credit"
    static let defaultCrossTrainingCredit = 0.5

    /// A curated shortlist of tool-capable OpenRouter model ids. OpenRouter
    /// exposes hundreds; these are the ones worth defaulting to for the coach.
    static let availableOpenRouterModels = [
        "openai/gpt-oss-120b:free",
        "google/gemma-4-31b-it:free",
        "deepseek/deepseek-v4-flash",
        "deepseek/deepseek-v4-pro",
        "z-ai/glm-5.2",
        "google/gemini-3-flash-preview",
        "meta-llama/llama-4-maverick",

    ]

    init() {
        openRouterAPIKey = KeychainStore.string(for: KeychainStore.openRouterAPIKey) ?? ""
        let savedBackend = UserDefaults.standard.string(forKey: "selected_backend") ?? ""
        // Default to the privacy-safe on-device backend; cloud AI is an explicit,
        // consented opt-in.
        selectedBackend = BackendType(rawValue: savedBackend) ?? .appleIntelligence
        useAppleCloudCompute = UserDefaults.standard.bool(forKey: "use_apple_cloud_compute")
        cloudAIConsent = UserDefaults.standard.bool(forKey: "cloud_ai_consent")
        openRouterModel = UserDefaults.standard.string(forKey: "openrouter_model") ?? Self.availableOpenRouterModels[0]
        readSources = Self.loadReadSources()
        metricsSource = Self.loadMetricsSource()
        writeTarget = Self.loadWriteTarget()
        let keychainEmail = KeychainStore.string(for: KeychainStore.garminEmail)
        let legacyEmail = UserDefaults.standard.string(forKey: "garmin_email")
        garminEmail = keychainEmail ?? legacyEmail ?? ""
        // One-time migration of the pre-iCloud UserDefaults email into the
        // synchronizable Keychain (didSet doesn't fire during init).
        if keychainEmail == nil, let legacyEmail, !legacyEmail.isEmpty {
            KeychainStore.set(legacyEmail, for: KeychainStore.garminEmail)
            UserDefaults.standard.removeObject(forKey: "garmin_email")
        }
        lmStudioBaseURL = UserDefaults.standard.string(forKey: "lmstudio_base_url") ?? "http://localhost:1234/v1"
        lmStudioModel = UserDefaults.standard.string(forKey: "lmstudio_model") ?? "local-model"
        debugMode = UserDefaults.standard.bool(forKey: "debug_mode")
        proactiveNotifications = UserDefaults.standard.bool(forKey: Self.proactiveNotificationsKey)
        let layout = Self.loadDashboardLayout()
        dashboardLayout = layout
        // One-time migration of the pre-layout AI-summary toggle (its value seeded
        // the load above; didSet doesn't fire during init, so persist explicitly).
        if UserDefaults.standard.object(forKey: "ai_dashboard_insight") != nil {
            UserDefaults.standard.set(Self.encode(layout), forKey: "dashboard_sections")
            UserDefaults.standard.removeObject(forKey: "ai_dashboard_insight")
        }
        crossTrainingCreditFactor = Self.loadCreditFactor()
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
        if let csv = UserDefaults.standard.string(forKey: "dashboard_sections"), !csv.isEmpty {
            for token in csv.split(separator: ",") {
                let hidden = token.hasPrefix("-")
                guard let section = DashboardSection(rawValue: String(hidden ? token.dropFirst() : token)) else { continue }
                items.append(DashboardLayoutItem(section: section, isVisible: !hidden))
            }
        } else {
            // First run: everything visible except the AI summary, which keeps the
            // legacy opt-in toggle's value (false when never set).
            let aiOn = UserDefaults.standard.bool(forKey: "ai_dashboard_insight")
            items = DashboardSection.allCases.map { DashboardLayoutItem(section: $0, isVisible: $0 != .aiInsight || aiOn) }
        }
        // Sections the app gained after the layout was stored surface at the end.
        let known = Set(items.map(\.section))
        items += DashboardSection.allCases.filter { !known.contains($0) }.map { DashboardLayoutItem(section: $0, isVisible: true) }
        return items
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

    var isConfigured: Bool {
        switch selectedBackend {
        case .openRouter: return cloudAIConsent && !openRouterAPIKey.isEmpty
        case .appleIntelligence: return true
        case .lmStudio: return !lmStudioBaseURL.isEmpty
        }
    }

    func makeBackend() -> LLMBackend {
        switch selectedBackend {
        case .openRouter:
            return OpenAICompatibleBackend(
                displayName: BackendType.openRouter.rawValue,
                baseURL: "https://openrouter.ai/api/v1",
                apiKey: openRouterAPIKey,
                extraHeaders: ["X-Title": "TriGenius"],
                model: openRouterModel
            )
        case .appleIntelligence:
            return FoundationModelBackendFactory.make(useCloud: useAppleCloudCompute)
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

struct SettingsView: View {
    let brain: CoachBrain
    @ObservedObject var settings: AppSettings
    @ObservedObject var memory: CoachMemory
    let onBackendChanged: () -> Void

    @State private var showAPIKey = false
    @State private var showClearConfirm = false
    @State private var showClearDataConfirm = false
    @State private var showCloudConsent = false
    #if DEBUG
    @State private var showClearDBConfirm = false
    @State private var showDeletePerfConfirm = false
    @State private var plannedTSSRecomputeCount: Int?
    #endif

    var body: some View {
        List {
            // AI Coach section — which model answers. On-device Apple Intelligence
            // is the private default; OpenRouter (cloud) is gated behind explicit
            // consent because it sends training + health data to a third party.
            Section {
                Picker("Backend", selection: $settings.selectedBackend) {
                    ForEach(BackendType.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.selectedBackend) { _, new in
                    // Selecting the cloud backend without prior consent opens the
                    // consent sheet instead of activating it.
                    if new == .openRouter && !settings.cloudAIConsent {
                        showCloudConsent = true
                    } else {
                        onBackendChanged()
                    }
                }

                switch settings.selectedBackend {
                case .openRouter:
                    openRouterSection
                case .appleIntelligence:
                    appleIntelligenceSection
                case .lmStudio:
                    lmStudioSection
                }
            } header: {
                Text("AI Coach")
            } footer: {
                Text("Apple Intelligence runs on your device — no training or health data leaves it. OpenRouter is a cloud service you connect with your own API key; using it sends your workout data to OpenRouter and the model you pick.")
            }

            // Data sources — read (Garmin / Apple Health) + write target live on
            // their own sub-page to keep the root list scannable.
            Section {
                NavigationLink {
                    DataSourcesView(settings: settings, onBackendChanged: onBackendChanged)
                } label: {
                    Label("Data Sources", systemImage: "arrow.triangle.2.circlepath")
                }
            } footer: {
                Text("Where TriGenius reads your training and health data from, and where it schedules planned workouts.")
            }

            // Schedule (calendar) section — gives the coach awareness of busy days.
            Section {
                CalendarAccessSection()
            } header: {
                Text("Schedule")
            } footer: {
                Text("Lets the coach read your calendar's busy/free windows to plan workouts around busy days. Read-only — TriGenius never changes your events.")
            }

            // Dashboard section — section layout + weekly-ring tuning.
            Section {
                NavigationLink {
                    DashboardLayoutView(settings: settings)
                } label: {
                    Label("Dashboard layout", systemImage: "rectangle.grid.1x2")
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("Cross-training credit", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        Text(settings.crossTrainingCreditFactor, format: .percent.precision(.fractionLength(0)))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: $settings.crossTrainingCreditFactor, in: 0...1, step: 0.05)
                }
            } header: {
                Text("Dashboard")
            } footer: {
                Text("Dashboard layout picks which sections appear and in what order (the AI summary costs an LLM call per load, off by default). Cross-training credit lets surplus in one discipline partly fill the other weekly rings — 0 % keeps each discipline strict, 100 % treats load as fully interchangeable.")
            }

            // Notifications section — proactive background coaching.
            Section {
                NotificationSettingsSection(settings: settings)
            } header: {
                Text("Notifications")
            } footer: {
                Text("Proactive alerts when your form (TSB) signals high fatigue or detraining. Evaluated on a background refresh.")
            }

            // Reminders section — user/coach-configurable push reminders.
            RemindersSection()

            // Athlete profile section
            Section("Athlete Profile") {
                profileRow("Name", value: memory.userProfile.name)

                if !memory.userProfile.goals.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Goals")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(memory.userProfile.goals.joined(separator: ", "))
                            .font(.body)
                    }
                    .padding(.vertical, 2)
                }

                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Label("Reset profile", systemImage: "trash")
                }
                .confirmationDialog(
                    "Delete athlete profile?",
                    isPresented: $showClearConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        resetMemory()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("All saved profile and training data will be deleted.")
                }
            }

            // Performance metrics — auto-synced from the data source into the
            // local time-series DB; read-only here.
            Section {
                let performance = TrainingDataStore.shared.latestSnapshot()
                profileRow("FTP (cycling)", value: performance.cyclingFTP.map { "\($0) W" })
                profileRow("Threshold power (run)", value: performance.runningFTP.map { "\($0) W" })
                profileRow("CSS", value: performance.cssPaceFormatted.map { "\($0)/100m" })
                profileRow("Lactate threshold HR", value: performance.lactateThrHR.map { "\($0) bpm" })
                profileRow("Lactate threshold pace", value: performance.lactateThrPaceFormatted.map { "\($0)/km" })
                profileRow("VO₂max (run)", value: performance.vo2maxRunning.map { String(format: "%.1f", $0) })
                profileRow("VO₂max (cycling)", value: performance.vo2maxCycling.map { String(format: "%.1f", $0) })
                profileRow("Max HR", value: performance.maxHR.map { "\($0) bpm" })
                profileRow("Weight", value: performance.weightKg.map { String(format: "%.1f kg", $0) })
            } header: {
                Text("Performance")
            } footer: {
                Text("Synced automatically from \(settings.metricsSource.displayName). History is kept in the local database.")
            }

            // Privacy & Data — user-facing controls Apple review expects: the
            // privacy policy, a medical disclaimer, and full data deletion.
            Section {
                Link(destination: URL(string: Self.privacyPolicyURL)!) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
                NavigationLink {
                    IgnoredWorkoutsView()
                } label: {
                    Label("Ignored workouts", systemImage: "eye.slash")
                }
                Button(role: .destructive) {
                    showClearDataConfirm = true
                } label: {
                    Label("Delete all my data", systemImage: "trash")
                }
                .confirmationDialog(
                    "Delete all my data?",
                    isPresented: $showClearDataConfirm,
                    titleVisibility: .visible
                ) {
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
                                makeBackend: settings.makeBackend,
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
                .confirmationDialog(
                    "Clear local database?",
                    isPresented: $showClearDBConfirm,
                    titleVisibility: .visible
                ) {
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
                .confirmationDialog(
                    "Delete historical performance data?",
                    isPresented: $showDeletePerfConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        TrainingDataStore.shared.deletePerformanceMetrics()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Removes the stored performance history (FTP, VO₂max, thresholds, zones, weight). Daily wellness (sleep, resting HR, HRV) and your activities are kept; values re-sync from Garmin on the next sync or backfill.")
                }
            } header: {
                Text("Developer")
            } footer: {
                Text("Debug mode shows the coach's hidden tool calls as messages in the chat and logs the full prompt to the console.")
            }
            #endif

            // About section
            Section("About") {
                HStack {
                    Text("TriGenius")
                    Spacer()
                    Text("AI Triathlon Coach")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Version")
                    Spacer()
                    Text(Self.appVersion).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showCloudConsent) {
            CloudAIConsentView(
                onAccept: {
                    settings.cloudAIConsent = true
                    showCloudConsent = false
                    onBackendChanged()
                },
                onDecline: {
                    settings.selectedBackend = .appleIntelligence
                    showCloudConsent = false
                }
            )
        }
    }

    // MARK: - OpenRouter section

    private var openRouterSection: some View {
        Group {
            HStack {
                if showAPIKey {
                    TextField("API key", text: $settings.openRouterAPIKey)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .disableAutocorrection(true)
                        .onChange(of: settings.openRouterAPIKey) { onBackendChanged() }
                } else {
                    SecureField("API key", text: $settings.openRouterAPIKey)
                        .onChange(of: settings.openRouterAPIKey) { onBackendChanged() }
                }
                Button {
                    showAPIKey.toggle()
                } label: {
                    Image(systemName: showAPIKey ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
            }

            Picker("Model", selection: $settings.openRouterModel) {
                ForEach(AppSettings.availableOpenRouterModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .onChange(of: settings.openRouterModel) { onBackendChanged() }

            if settings.openRouterAPIKey.isEmpty {
                Label("API key required for OpenRouter", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            } else {
                Label("OpenRouter configured", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }

            // Cloud-sharing consent state + a way to revoke it (revoking falls the
            // coach back to on-device Apple Intelligence).
            if settings.cloudAIConsent {
                Button(role: .destructive) {
                    settings.cloudAIConsent = false
                    settings.selectedBackend = .appleIntelligence
                    onBackendChanged()
                } label: {
                    Label("Revoke cloud data sharing", systemImage: "hand.raised")
                }
                .font(.caption)
            }
        }
    }

    // MARK: - Apple Intelligence section

    private var appleIntelligenceSection: some View {
        Group {
            if #available(iOS 27.0, macOS 27.0, *) {
                modelStatusRow("On-device", status: AppleModelAvailability.onDeviceStatus())

                // TODO: Force Private Cloud Compute to unavailable until Apple unlocks it
                // for this developer account; restore `AppleModelAvailability.cloudStatus()` then.
                let cloud = AppleModelAvailability.Status(isAvailable: false, detail: "Not yet enabled for this account")
                modelStatusRow("Private Cloud Compute", status: cloud)

                Toggle("Use Private Cloud Compute", isOn: $settings.useAppleCloudCompute)
                    .disabled(!cloud.isAvailable)
                    .onChange(of: settings.useAppleCloudCompute) { onBackendChanged() }
            } else {
                Label("Requires iOS 27 / macOS 27", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }

    @available(iOS 27.0, macOS 27.0, *)
    private func modelStatusRow(_ name: String, status: AppleModelAvailability.Status) -> some View {
        Label {
            Text("\(name)\(status.detail.map { " — \($0)" } ?? "")")
        } icon: {
            Image(systemName: status.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(status.isAvailable ? .green : .red)
        }
        .font(.caption)
    }

    // MARK: - LM Studio section

    private var lmStudioSection: some View {
        Group {
            TextField("Server URL", text: $settings.lmStudioBaseURL)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .disableAutocorrection(true)
                .onChange(of: settings.lmStudioBaseURL) { onBackendChanged() }

            TextField("Model id", text: $settings.lmStudioModel)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .disableAutocorrection(true)
                .onChange(of: settings.lmStudioModel) { onBackendChanged() }

            if settings.lmStudioBaseURL.isEmpty {
                Label("Server URL required for LM Studio", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            } else {
                Label("Start LM Studio's local server, then pick the loaded model id.", systemImage: "desktopcomputer")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    // MARK: - Helpers

    private func profileRow(_ label: String, value: String?) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value ?? "—")
                .foregroundStyle(value == nil ? .tertiary : .secondary)
        }
    }

    private func resetMemory() {
        // Reset by writing a fresh memory
        memory.updateProfile { $0 = UserProfile() }
        memory.updateWeeklyStructure { $0 = WeeklyStructure() }
        memory.updatePreferences { $0 = AthletePreferences() }
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
                    .foregroundStyle(.green)
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
        await GarminClient.shared.clearProfileCache()
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
        await GarminClient.shared.clearProfileCache()
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
        .confirmationDialog(
            "Delete all reports?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { store.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All locally-filed reports will be permanently deleted.")
        }
    }
}

// MARK: - Calendar Access Section

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
                    .foregroundStyle(.green)
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
                    .foregroundStyle(.orange)
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

// MARK: - Notification Settings Section

/// Toggle for proactive background notifications. Enabling it requests
/// notification authorization and schedules the background refresh.
struct NotificationSettingsSection: View {
    @ObservedObject var settings: AppSettings
    @State private var statusMessage: String?

    var body: some View {
        Group {
            Toggle(isOn: Binding(
                get: { settings.proactiveNotifications },
                set: { newValue in
                    settings.proactiveNotifications = newValue
                    Task { await apply(newValue) }
                }
            )) {
                Label("Proactive notifications", systemImage: "bell.badge")
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func apply(_ enabled: Bool) async {
        guard enabled else {
            BackgroundCoordinator.shared.cancel()
            statusMessage = nil
            return
        }
        let granted = await NotificationCenterService.shared.requestAuthorization()
        if granted {
            BackgroundCoordinator.shared.schedule()
            statusMessage = "You'll get a proactive heads-up after the next background refresh."
        } else {
            settings.proactiveNotifications = false
            statusMessage = "Notifications are turned off for TriGenius — enable them in the Settings app."
        }
    }
}

// MARK: - Reminders Section

/// UI display metadata for a `ReminderKind`.
private extension ReminderKind {
    var title: String {
        switch self {
        case .checkIn: return "Check-in"
        case .weeklyReview: return "Weekly review"
        case .custom: return "Custom"
        case .todaysWorkout: return "Today's workout"
        case .sleepAdvice: return "Sleep advice"
        }
    }
    var systemImage: String {
        switch self {
        case .checkIn: return "bubble.left.and.bubble.right"
        case .weeklyReview: return "calendar.badge.clock"
        case .custom: return "bell"
        case .todaysWorkout: return "figure.run"
        case .sleepAdvice: return "bed.double"
        }
    }
}

/// Lists configurable reminders + quiet hours, bound to the shared `ReminderStore`.
/// Static reminders fire at their exact time via the OS; dynamic ones are composed
/// and delivered on a background refresh (timing is approximate).
struct RemindersSection: View {
    @ObservedObject private var store = ReminderStore.shared
    @State private var editing: ReminderRule?
    @State private var isAdding = false

    var body: some View {
        Section {
            // Quiet hours.
            QuietHoursRow(store: store)

            // Existing reminders.
            ForEach(store.rules) { rule in
                Button { editing = rule } label: { reminderRow(rule) }
                    .buttonStyle(.plain)
            }
            .onDelete { offsets in
                offsets.map { store.rules[$0].id }.forEach { store.delete(id: $0) }
                reconcile()
            }

            Button { isAdding = true } label: {
                Label("Add reminder", systemImage: "plus.circle")
            }
        } header: {
            Text("Reminders")
        } footer: {
            Text("Schedule when TriGenius nudges you. Dynamic reminders (today's workout, sleep advice) are delivered around the chosen time on a background refresh, so they may arrive a little late.")
        }
        .sheet(isPresented: $isAdding) {
            ReminderEditorView(rule: nil) { saved in
                store.upsert(saved); reconcile()
            }
        }
        .sheet(item: $editing) { rule in
            ReminderEditorView(rule: rule) { saved in
                store.upsert(saved); reconcile()
            }
        }
    }

    @ViewBuilder
    private func reminderRow(_ rule: ReminderRule) -> some View {
        HStack {
            Image(systemName: rule.kind.systemImage)
                .frame(width: 24)
                .foregroundStyle(rule.enabled ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.kind == .custom ? (rule.message ?? rule.kind.title) : rule.kind.title)
                    .font(.body)
                    .lineLimit(1)
                Text("\(timeLabel(rule)) · \(weekdaysLabel(rule))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !rule.enabled {
                Text("Off").font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private func timeLabel(_ rule: ReminderRule) -> String {
        String(format: "%02d:%02d", rule.hour, rule.minute)
    }

    private func weekdaysLabel(_ rule: ReminderRule) -> String {
        guard !rule.weekdays.isEmpty else { return "Every day" }
        let short = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return rule.weekdays.sorted().map { short[$0] }.joined(separator: " ")
    }

    private func reconcile() {
        Task {
            await NotificationCenterService.shared.requestAuthorization()
            await ReminderScheduler.shared.reconcile()
        }
    }
}

/// A toggle + two time pickers for the quiet-hours window.
private struct QuietHoursRow: View {
    @ObservedObject var store: ReminderStore

    private var isOn: Bool { store.quietStartMinute != nil && store.quietEndMinute != nil }

    var body: some View {
        Toggle(isOn: Binding(
            get: { isOn },
            set: { on in
                if on { store.setQuietHours(start: 22 * 60, end: 7 * 60) }
                else { store.setQuietHours(start: nil, end: nil) }
            }
        )) {
            Label("Quiet hours", systemImage: "moon")
        }

        if isOn {
            DatePicker("From", selection: Binding(
                get: { Self.date(fromMinutes: store.quietStartMinute ?? 0) },
                set: { store.setQuietHours(start: Self.minutes(from: $0), end: store.quietEndMinute) }
            ), displayedComponents: .hourAndMinute)

            DatePicker("To", selection: Binding(
                get: { Self.date(fromMinutes: store.quietEndMinute ?? 0) },
                set: { store.setQuietHours(start: store.quietStartMinute, end: Self.minutes(from: $0)) }
            ), displayedComponents: .hourAndMinute)
        }
    }

    static func date(fromMinutes m: Int) -> Date {
        Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
    }
    static func minutes(from date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}

/// Create/edit sheet for a single reminder.
struct ReminderEditorView: View {
    let rule: ReminderRule?
    let onSave: (ReminderRule) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: ReminderKind
    @State private var time: Date
    @State private var weekdays: Set<Int>
    @State private var enabled: Bool
    @State private var message: String

    private let weekdayOrder = [2, 3, 4, 5, 6, 7, 1] // Mon…Sun
    private let weekdayShort = ["", "S", "M", "T", "W", "T", "F", "S"]

    init(rule: ReminderRule?, onSave: @escaping (ReminderRule) -> Void) {
        self.rule = rule
        self.onSave = onSave
        _kind = State(initialValue: rule?.kind ?? .checkIn)
        _time = State(initialValue: QuietHoursRow.date(fromMinutes: (rule?.hour ?? 8) * 60 + (rule?.minute ?? 0)))
        _weekdays = State(initialValue: Set(rule?.weekdays ?? []))
        _enabled = State(initialValue: rule?.enabled ?? true)
        _message = State(initialValue: rule?.message ?? "")
    }

    private var isValid: Bool {
        kind != .custom || !message.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $kind) {
                        ForEach(ReminderKind.allCases, id: \.self) { k in
                            Label(k.title, systemImage: k.systemImage).tag(k)
                        }
                    }
                    if kind == .custom {
                        TextField("Message", text: $message, axis: .vertical)
                    }
                } footer: {
                    Text(kind.isDynamic
                         ? "Composed from your current data and delivered around this time on a background refresh."
                         : "Fires at the exact time, even when the app is closed.")
                }

                Section {
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    Toggle("Enabled", isOn: $enabled)
                }

                Section {
                    HStack {
                        ForEach(Array(weekdayOrder.enumerated()), id: \.offset) { _, wd in
                            let on = weekdays.contains(wd)
                            Button {
                                if on { weekdays.remove(wd) } else { weekdays.insert(wd) }
                            } label: {
                                Text(weekdayShort[wd])
                                    .font(.caption.bold())
                                    .frame(maxWidth: .infinity, minHeight: 34)
                                    .background(on ? Color.accentColor : Color.secondary.opacity(0.15))
                                    .foregroundStyle(on ? .white : .primary)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("Repeat")
                } footer: {
                    Text(weekdays.isEmpty ? "No days selected → repeats every day." : "")
                }
            }
            .navigationTitle(rule == nil ? "New Reminder" : "Edit Reminder")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!isValid)
                }
            }
        }
    }

    private func save() {
        let m = QuietHoursRow.minutes(from: time)
        let saved = ReminderRule(
            id: rule?.id ?? UUID().uuidString,
            kind: kind,
            enabled: enabled,
            hour: m / 60,
            minute: m % 60,
            weekdays: weekdays.sorted(),
            message: kind == .custom ? message : nil
        )
        onSave(saved)
        dismiss()
    }
}

// MARK: - Reminder Test View

/// Developer screen to exercise the reminder pipeline without waiting for the
/// real schedule or a system background refresh.
struct ReminderTestView: View {
    @ObservedObject private var store = ReminderStore.shared
    @State private var status: String?
    @State private var dynamicPreviews: [ReminderKind: String] = [:]
    @State private var pending: [String] = []
    @State private var isBusy = false

    var body: some View {
        Form {
            Section {
                Button {
                    run { granted in status = granted ? "Notifications authorized." : "Authorization denied — enable TriGenius in the Settings app." }
                } label: { Label("Request authorization", systemImage: "checkmark.shield") }

                Button {
                    run { _ in
                        let ok = await NotificationCenterService.shared.post(
                            title: "TriGenius — test",
                            body: "This is an immediate test reminder.",
                            identifier: "trigenius.reminder.test.\(UUID().uuidString)")
                        status = ok ? "Sent an immediate test notification." : "Couldn't send — check authorization."
                    }
                } label: { Label("Send test notification now", systemImage: "paperplane") }

                Button {
                    run { _ in
                        let ok = await NotificationCenterService.shared.scheduleTest(after: 10)
                        status = ok ? "Scheduled a test for 10s from now — background the app to see it." : "Couldn't schedule — check authorization."
                    }
                } label: { Label("Schedule test in 10s", systemImage: "clock.badge") }
            } header: {
                Text("Delivery")
            } footer: {
                Text("Verifies notification permission and that the OS delivers TriGenius notifications.")
            }

            Section {
                ForEach([ReminderKind.todaysWorkout, .sleepAdvice], id: \.self) { kind in
                    Button {
                        run { _ in
                            let body = await BackgroundCoordinator.shared.sendDynamicReminderTest(kind)
                            dynamicPreviews[kind] = body ?? "(nothing to report right now)"
                            status = body == nil ? "\(label(kind)): nothing to report — not sent." : "\(label(kind)): sent."
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Compose & send \(label(kind))", systemImage: kind.systemImage)
                            if let preview = dynamicPreviews[kind] {
                                Text(preview).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Dynamic reminders")
            } footer: {
                Text("Composes the body from your current data and delivers it immediately, ignoring the once-per-day limit.")
            }

            Section {
                Button {
                    run { _ in
                        await BackgroundCoordinator.shared.runProactiveCheck()
                        status = "Ran the full background check (sync + proactive digest + due dynamic reminders)."
                    }
                } label: { Label("Run background check now", systemImage: "arrow.triangle.2.circlepath") }
            } footer: {
                Text("Simulates the periodic background refresh. Gated by the Proactive notifications toggle and quiet hours, just like the real run.")
            }

            Section {
                Button {
                    run { _ in
                        await NotificationCenterService.shared.requestAuthorization()
                        await ReminderScheduler.shared.reconcile()
                        pending = await ReminderScheduler.shared.pendingReminderBodies()
                        status = "Reconciled \(pending.count) OS-scheduled reminder(s)."
                    }
                } label: { Label("Reconcile & list scheduled", systemImage: "list.bullet.rectangle") }

                if pending.isEmpty {
                    Text("No static reminders scheduled with the OS.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(pending, id: \.self) { Text($0).font(.caption) }
                }
            } header: {
                Text("Scheduled (static) reminders")
            }

            if let status {
                Section {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Test Reminders")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { pending = await ReminderScheduler.shared.pendingReminderBodies() }
        .disabled(isBusy)
    }

    private func label(_ kind: ReminderKind) -> String {
        kind == .todaysWorkout ? "today's workout" : "sleep advice"
    }

    /// Run an async action, requesting authorization first and toggling busy.
    private func run(_ action: @escaping (Bool) async -> Void) {
        isBusy = true
        Task {
            let granted = await NotificationCenterService.shared.requestAuthorization()
            await action(granted)
            isBusy = false
        }
    }
}

// MARK: - Garmin Backfill Section

/// Pulls a deeper slice of Garmin history into the local database so the PMC
/// engine's CTL (Fitness, 42-day) has a proper warm-up window. Garmin only —
/// Apple Health already backfills generously on its first sync.
/// Per-source "Re-sync" row: forgets the source's watermark and re-pulls its
/// history, recomputing each activity in place. One instance per enabled read
/// source (Garmin / Apple Health), so the action reads as belonging to that source.
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
