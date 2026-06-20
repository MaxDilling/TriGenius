import SwiftUI
import Combine

// MARK: - Data Source

enum DataSource: String, CaseIterable, Identifiable {
    case garmin = "Garmin"
    case appleHealth = "Apple Health"

    var id: String { rawValue }
    var displayName: String { rawValue }
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
    @Published var dataSource: DataSource {
        didSet { UserDefaults.standard.set(dataSource.rawValue, forKey: "data_source") }
    }
    @Published var garminEmail: String {
        didSet { UserDefaults.standard.set(garminEmail, forKey: "garmin_email") }
    }
    /// Developer toggle: surface hidden tool calls in the chat and log prompts to
    /// the console. Read live by `CoachBrain.isDebugEnabled`.
    @Published var debugMode: Bool {
        didSet { UserDefaults.standard.set(debugMode, forKey: "debug_mode") }
    }

    static let availableGeminiModels = [
        "gemini-2.5-flash",
        "gemini-3.5-flash",
        "gemini-3.1-pro-preview",
        "gemini-3-flash-preview",
        "gemma-3-27b-it"
    ]

    init() {
        geminiAPIKey = UserDefaults.standard.string(forKey: "gemini_api_key") ?? ""
        let savedBackend = UserDefaults.standard.string(forKey: "selected_backend") ?? ""
        selectedBackend = BackendType(rawValue: savedBackend) ?? .gemini
        geminiModel = UserDefaults.standard.string(forKey: "gemini_model") ?? "gemini-2.5-flash"
        let savedSource = UserDefaults.standard.string(forKey: "data_source") ?? ""
        dataSource = DataSource(rawValue: savedSource) ?? .appleHealth
        garminEmail = UserDefaults.standard.string(forKey: "garmin_email") ?? ""
        debugMode = UserDefaults.standard.bool(forKey: "debug_mode")
    }

    var isConfigured: Bool {
        switch selectedBackend {
        case .gemini: return !geminiAPIKey.isEmpty
        case .appleIntelligence: return true
        }
    }

    func makeBackend() -> LLMBackend {
        switch selectedBackend {
        case .gemini:
            return GeminiBackend(apiKey: geminiAPIKey, model: geminiModel)
        case .appleIntelligence:
            return FoundationModelBackendFactory.make()
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var memory: CoachMemory
    let onBackendChanged: () -> Void

    @State private var showAPIKey = false
    @State private var showClearConfirm = false
    @State private var showClearDataConfirm = false

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

                if settings.selectedBackend == .gemini {
                    geminiSection
                } else {
                    appleIntelligenceSection
                }
            }

            // Data source section
            Section("Data Source") {
                Picker("Source", selection: $settings.dataSource) {
                    ForEach(DataSource.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.dataSource) { onBackendChanged() }

                if settings.dataSource == .garmin {
                    GarminLoginSection(settings: settings)
                } else {
                    Text("Training and health data comes from Apple Health.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Athlete profile section
            Section("Athlete Profile") {
                profileRow("Name", value: memory.userProfile.name)
                profileRow("Max HR", value: memory.userProfile.maxHR.map { "\($0) bpm" })

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
                profileRow("Weight", value: performance.weightKg.map { String(format: "%.1f kg", $0) })
            } header: {
                Text("Performance")
            } footer: {
                Text("Synced automatically from \(settings.dataSource == .garmin ? "Garmin" : "Apple Health"). History is kept in the local database.")
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
            } header: {
                Text("Developer")
            } footer: {
                Text("Shows the coach's hidden tool calls as messages in the chat and logs the full prompt to the console.")
            }

            // About section
            Section("About") {
                HStack {
                    Text("TriGenius")
                    Spacer()
                    Text("AI Triathlon Coach")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Data")
                    Spacer()
                    Text(settings.dataSource == .garmin ? "Garmin Connect" : "Apple HealthKit")
                        .foregroundStyle(.secondary)
                }
                NavigationLink {
                    MemoryDebugView(memory: memory)
                } label: {
                    Label("Storage (coach_memory.json)", systemImage: "curlybraces")
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
            if #available(iOS 18.0, macOS 15.0, *) {
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
                Label("Requires iOS 18 / macOS 15", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("File path")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(memory.storageFilePath)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)

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
    }
}
