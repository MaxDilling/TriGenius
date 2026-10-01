import SwiftUI

/// Which model answers as the coach. On-device Apple Intelligence is the private
/// default; OpenRouter (cloud) is gated behind explicit consent because it sends
/// training + health data to a third party.
struct AIModelSettingsView: View {
    @ObservedObject var settings: AppSettings
    let onBackendChanged: () -> Void

    @State private var showAPIKey = false
    @State private var showCloudConsent = false

    var body: some View {
        List {
            Section {
                Picker("Provider", selection: $settings.selectedBackend) {
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
            } footer: {
                Text("Apple Intelligence runs on your device — no training or health data leaves it. OpenRouter is a cloud service you connect with your own API key; using it sends your workout data to OpenRouter and the model you pick.")
            }
        }
        .navigationTitle("AI Model")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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
                ForEach(AppSettings.availableOpenRouterModels, id: \.model) { entry in
                    Text(entry.model).tag(entry.model)
                }
            }
            .onChange(of: settings.openRouterModel) { onBackendChanged() }

            Picker("Summary model", selection: $settings.openRouterSummaryModel) {
                ForEach(AppSettings.availableSummaryModels, id: \.model) { entry in
                    Text(entry.model).tag(entry.model)
                }
            }

            Toggle("Web search", isOn: $settings.openRouterWebSearch)
                .onChange(of: settings.openRouterWebSearch) { onBackendChanged() }
            if settings.openRouterWebSearch {
                Text("The coach can look things up on the live web when a question needs current information (billed per search by OpenRouter; queries also reach the search provider). Replies that used the web show a globe.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if settings.openRouterAPIKey.isEmpty {
                Label("API key required for OpenRouter", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Palette.warning)
                    .font(.caption)
            } else {
                Label("OpenRouter configured", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.Palette.success)
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
            modelStatusRow("On-device", status: AppleModelAvailability.onDeviceStatus())

            // TODO: Force Private Cloud Compute to unavailable until Apple unlocks it
            // for this developer account; restore `AppleModelAvailability.cloudStatus()` then.
            let cloud = AppleModelAvailability.Status(isAvailable: false, detail: "Not yet enabled for this account")
            modelStatusRow("Private Cloud Compute", status: cloud)

            Toggle("Use Private Cloud Compute", isOn: $settings.useAppleCloudCompute)
                .disabled(!cloud.isAvailable)
                .onChange(of: settings.useAppleCloudCompute) { onBackendChanged() }
        }
    }

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
                    .foregroundStyle(Theme.Palette.warning)
                    .font(.caption)
            } else {
                Label("Start LM Studio's local server, then pick the loaded model id.", systemImage: "desktopcomputer")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }
}
