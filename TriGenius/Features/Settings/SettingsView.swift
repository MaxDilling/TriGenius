import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - Data Source (read) & Write Target

/// A *read* source: where athlete history is pulled from. Multiple can be active
/// at once (parallel read), merged into the local store.
enum DataSource: String, CaseIterable, Identifiable {
    case garmin = "Garmin"
    case appleHealth = "Apple Health"

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

// MARK: - App Settings

final class AppSettings: ObservableObject {
    @Published var geminiAPIKey: String {
        didSet { UserDefaults.standard.set(geminiAPIKey, forKey: "gemini_api_key") }
    }
    @Published var selectedBackend: BackendType {
        didSet { UserDefaults.standard.set(selectedBackend.rawValue, forKey: "selected_backend") }
    }
    @Published var geminiModel: String {
        didSet { UserDefaults.standard.set(geminiModel, forKey: "gemini_model") }
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
    @Published var garminEmail: String {
        didSet { UserDefaults.standard.set(garminEmail, forKey: "garmin_email") }
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

    static let availableGeminiModels = [
        "gemini-2.5-flash",
        "gemini-3.5-flash",
        "gemini-3.1-pro-preview",
        "gemma-3-27b-it",
        "google/gemma-4-26b-a4b-qat"
    ]

    init() {
        geminiAPIKey = UserDefaults.standard.string(forKey: "gemini_api_key") ?? ""
        let savedBackend = UserDefaults.standard.string(forKey: "selected_backend") ?? ""
        selectedBackend = BackendType(rawValue: savedBackend) ?? .gemini
        geminiModel = UserDefaults.standard.string(forKey: "gemini_model") ?? "gemini-2.5-flash"
        readSources = Self.loadReadSources()
        metricsSource = Self.loadMetricsSource()
        writeTarget = Self.loadWriteTarget()
        garminEmail = UserDefaults.standard.string(forKey: "garmin_email") ?? ""
        lmStudioBaseURL = UserDefaults.standard.string(forKey: "lmstudio_base_url") ?? "http://localhost:1234/v1"
        lmStudioModel = UserDefaults.standard.string(forKey: "lmstudio_model") ?? "local-model"
        debugMode = UserDefaults.standard.bool(forKey: "debug_mode")
        proactiveNotifications = UserDefaults.standard.bool(forKey: Self.proactiveNotificationsKey)
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
        case .gemini: return !geminiAPIKey.isEmpty
        case .appleIntelligence: return true
        case .lmStudio: return !lmStudioBaseURL.isEmpty
        }
    }

    func makeBackend() -> LLMBackend {
        switch selectedBackend {
        case .gemini:
            return GeminiBackend(apiKey: geminiAPIKey, model: geminiModel)
        case .appleIntelligence:
            return FoundationModelBackendFactory.make()
        case .lmStudio:
            return LMStudioBackend(baseURL: lmStudioBaseURL, model: lmStudioModel)
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
    @State private var showDeletePerfConfirm = false

    var body: some View {
        List {
            // Backend section
            Section("AI Backend") {
                Picker("Backend", selection: $settings.selectedBackend) {
                    ForEach(BackendType.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.selectedBackend) { onBackendChanged() }

                switch settings.selectedBackend {
                case .gemini:
                    geminiSection
                case .appleIntelligence:
                    appleIntelligenceSection
                case .lmStudio:
                    lmStudioSection
                }
            }

            // Read sources — parallel; merged into the local store. Source selection
            // only; each enabled source's own controls live in its section below.
            Section {
                ForEach(DataSource.allCases) { source in
                    Toggle(isOn: readBinding(source)) {
                        Label(source.displayName, systemImage: source.icon)
                    }
                }
                // When both providers feed activities, pick exactly one to supply the
                // performance + wellness metrics, so FTP/VO₂max/sleep aren't sourced twice.
                if settings.readSources.count > 1 {
                    Picker("Metrics from", selection: $settings.metricsSource) {
                        ForEach(settings.readSources.sorted(by: { $0.rawValue < $1.rawValue })) { source in
                            Text(source.displayName).tag(source)
                        }
                    }
                }
            } header: {
                Text("Read From")
            } footer: {
                Text("Pull training and health data from one or both. Garmin Connect workouts already mirrored into Apple Health are skipped to avoid duplicates. When both are on, performance and wellness metrics come from the single \u{201C}Metrics from\u{201D} provider.")
            }

            // Per-source controls — one section each, headed by the provider, so it's
            // clear what belongs to whom. Each carries a Re-sync that re-pulls and
            // recomputes that source's history in place.
            if settings.readSources.contains(.garmin) {
                Section {
                    GarminLoginSection(settings: settings)
                    ReadSourceSyncSection(source: .garmin)
                } header: {
                    Label(DataSource.garmin.displayName, systemImage: DataSource.garmin.icon)
                } footer: {
                    Text("Re-sync re-fetches your Garmin history and recomputes TSS for every activity.")
                }
            }
            if settings.readSources.contains(.appleHealth) {
                Section {
                    ReadSourceSyncSection(source: .appleHealth)
                } header: {
                    Label(DataSource.appleHealth.displayName, systemImage: DataSource.appleHealth.icon)
                } footer: {
                    Text("Re-sync re-reads every Apple Health workout — recomputing heart rate, zones and TSS for sessions imported before they were supported.")
                }
            }

            // Write target — where the coach schedules planned workouts.
            Section {
                Picker("Schedule workouts to", selection: $settings.writeTarget) {
                    ForEach(WriteTarget.allCases.filter { $0.isSupportedOnThisPlatform }) { target in
                        Text(target.displayName).tag(target)
                    }
                }
                .onChange(of: settings.writeTarget) { onBackendChanged() }

                if settings.writeTarget == .garmin, !settings.readSources.contains(.garmin) {
                    GarminLoginSection(settings: settings)
                }
            } header: {
                Text("Write To")
            } footer: {
                Text(settings.writeTarget == .appleWatch
                     ? "Planned workouts are sent to the Apple Watch via WorkoutKit — start them from the Workout app."
                     : "Planned workouts are created and scheduled in Garmin Connect. Switching targets re-syncs upcoming plans; nothing is lost.")
            }

            // Schedule (calendar) section — gives the coach awareness of busy days.
            Section {
                CalendarAccessSection()
            } header: {
                Text("Schedule")
            } footer: {
                Text("Lets the coach read your calendar's busy/free windows to plan workouts around busy days. Read-only — TriGenius never changes your events.")
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

            // Training plan section
            if memory.trainingPlan.targetEvent != nil || memory.trainingPlan.currentPhase != nil {
                Section("Training Plan") {
                    profileRow("Target event", value: memory.trainingPlan.targetEvent)
                    profileRow("Date", value: memory.trainingPlan.eventDate)
                    profileRow("Phase", value: memory.trainingPlan.currentPhase?.uppercased())
                    profileRow("Focus", value: memory.trainingPlan.monthlyFocus)
                }
            }

            // Developer section
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
                                trainingPlan: memory.trainingPlan,
                                makeBackend: settings.makeBackend
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
                NavigationLink {
                    IgnoredWorkoutsView()
                } label: {
                    Label("Ignored workouts", systemImage: "eye.slash")
                }
                Button(role: .destructive) {
                    showClearDataConfirm = true
                } label: {
                    Label("Clear local database", systemImage: "externaldrive.badge.xmark")
                }
                .confirmationDialog(
                    "Clear local database?",
                    isPresented: $showClearDataConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Clear", role: .destructive) {
                        clearDatabase()
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

            // About section
            Section("About") {
                HStack {
                    Text("TriGenius")
                    Spacer()
                    Text("AI Triathlon Coach")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Settings")
    }

    // MARK: - Gemini section

    private var geminiSection: some View {
        Group {
            HStack {
                if showAPIKey {
                    TextField("API key", text: $settings.geminiAPIKey)
                        .onChange(of: settings.geminiAPIKey) { onBackendChanged() }
                } else {
                    SecureField("API key", text: $settings.geminiAPIKey)
                        .onChange(of: settings.geminiAPIKey) { onBackendChanged() }
                }
                Button {
                    showAPIKey.toggle()
                } label: {
                    Image(systemName: showAPIKey ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
            }

            Picker("Model", selection: $settings.geminiModel) {
                ForEach(AppSettings.availableGeminiModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .onChange(of: settings.geminiModel) { onBackendChanged() }

            if settings.geminiAPIKey.isEmpty {
                Label("API key required for Gemini", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            } else {
                Label("Gemini configured", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }
        }
    }

    // MARK: - Apple Intelligence section

    private var appleIntelligenceSection: some View {
        Group {
            if #available(iOS 27.0, macOS 27.0, *) {
                let backend = AppleFoundationModelBackend()
                if backend.isAvailable {
                    Label("Apple Intelligence available", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                } else {
                    Label("Not available on this device", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            } else {
                Label("Requires iOS 27 / macOS 27", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
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

    /// Toggle binding for a read source. Keeps at least one source enabled.
    private func readBinding(_ source: DataSource) -> Binding<Bool> {
        Binding(
            get: { settings.readSources.contains(source) },
            set: { on in
                var next = settings.readSources
                if on { next.insert(source) } else { next.remove(source) }
                if next.isEmpty { next = [source] } // never leave zero sources
                settings.readSources = next
                onBackendChanged()
            }
        )
    }

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
        memory.updateTrainingPlan { $0 = TrainingPlan() }
    }

    /// Wipe the local time-series database (workouts, performance metrics,
    /// scheduled workouts) and the last-sync watermarks. The coach profile and
    /// app settings (`coach_memory.json`, UserDefaults UI prefs) are kept.
    private func clearDatabase() {
        TrainingDataStore.shared.deleteAllData()
        DataSyncCoordinator.shared.resetSyncState()
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
        // Garmin's Cloudflare WAF forces a 30–45s delay between the sign-in page
        // load and the credential submit, so the login deliberately takes a while.
        statusMessage = "Connecting to Garmin… this takes about 30–45 seconds (protection against Garmin's rate limit)."
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
