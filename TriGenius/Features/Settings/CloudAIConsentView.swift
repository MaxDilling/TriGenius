import SwiftUI

/// Consent gate shown before the cloud AI backend (OpenRouter) is activated.
/// On-device Apple Intelligence needs no consent; the cloud path sends the
/// athlete's workout + health data to a third party, so App Review requires an
/// explicit, informed opt-in (Guidelines 5.1.2 / 5.1.3).
struct CloudAIConsentView: View {
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    Label("Use cloud AI?", systemImage: "cloud")
                        .font(.title2.bold())

                    Text("OpenRouter is a third-party cloud service you connect with your own API key. To answer your questions, TriGenius will send the data it uses as context to OpenRouter and the model you select there:")
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        bullet("figure.run", "Your workouts and training load (TSS, CTL/ATL/TSB)")
                        bullet("heart.text.square", "Health metrics: FTP, VO₂max, thresholds, weight, sleep, resting HR, HRV")
                        bullet("person.text.rectangle", "Your athlete profile and the messages you send the coach")
                    }

                    Text("Your data is governed by OpenRouter's own privacy terms and the settings on your OpenRouter account. TriGenius keeps no copy on any server of its own. You can revoke this at any time in Settings, which switches the coach back to on-device Apple Intelligence.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Link(destination: URL(string: SettingsView.privacyPolicyURL)!) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }
                    .font(.callout)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: Theme.Spacing.s) {
                    Button(action: onAccept) {
                        Text("Enable cloud AI")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(action: onDecline) {
                        Text("Keep coaching on-device")
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle("Cloud AI")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .interactiveDismissDisabled()
        }
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.callout)
            .labelStyle(.titleAndIcon)
    }
}
