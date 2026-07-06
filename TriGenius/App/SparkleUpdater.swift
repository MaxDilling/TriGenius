#if os(macOS)
import SwiftUI
import Combine
import Sparkle

/// Sparkle auto-updates for the Developer-ID macOS build. Feeds off the
/// appcast.xml that Scripts/release.sh signs and attaches to each GitHub
/// release (SUFeedURL points at the latest release's asset).
@MainActor
final class SparkleUpdater: ObservableObject {
    static let shared = SparkleUpdater()
    @Published var canCheck = false

    private let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )

    private init() {
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }
}

/// "Check for Updates…" in the app menu, disabled while a check/install runs.
struct CheckForUpdatesCommand: Commands {
    @ObservedObject private var updater = SparkleUpdater.shared

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheck)
        }
    }
}
#endif
