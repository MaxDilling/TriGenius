import Foundation

// MARK: - Threshold-calculation settings, mirrored across the athlete's devices
//
// These describe the *athlete*, not the device: each switch decides which number
// every surface shows for the same stored history, so a phone and a Mac reading one
// CloudKit-mirrored store have to agree or they disagree about the athlete's FTP.
//
// They stay in UserDefaults — `TrainingDataStore` reads them off the main actor while
// resolving thresholds, and they must survive a DB clear — and ride
// `NSUbiquitousKeyValueStore` on top, the same mirror `IgnoredWorkouts` uses. One KVS
// key per setting, so two devices changing different switches both keep their change;
// the same switch is last-writer-wins, which for a boolean is the only merge there is.

enum AthleteSettingsSync {
    private static let cloud = NSUbiquitousKeyValueStore.default

    private static let flags = [AppSettings.estimateFTPFromVO2maxKey,
                                AppSettings.estimateVO2maxFromRidesKey,
                                AppSettings.estimateLTHRFromHRMaxKey,
                                AppSettings.estimateCyclingLTHRFromRidesKey,
                                AppSettings.estimateLTPaceFromRunsKey,
                                AppSettings.estimateRunningVO2maxFromRunsKey]
    private static let numbers = [AppSettings.ltPaceFractionOfMASKey]

    /// One athlete setting changed on this device: mirror it, and re-resolve.
    ///
    /// The re-resolve is the half that is easy to forget. These settings are read-time
    /// inputs to `PerformanceHistory`, not stored values, so flipping one changes every
    /// threshold the app shows without writing a row — and every surface refreshes on
    /// `trainingDataDidChange`, which a defaults write does not post. Called from every
    /// setter rather than per key: five writes are cheaper than five call sites that can
    /// each forget one.
    @MainActor static func didChange() {
        for key in flags { cloud.set(UserDefaults.standard.bool(forKey: key), forKey: key) }
        for key in numbers { cloud.set(UserDefaults.standard.double(forKey: key), forKey: key) }
        // The cards re-resolve; the stored TL was scored against the old thresholds and
        // only a rescore rewrites it. Mark it so the gap is visible instead of silent.
        UserDefaults.standard.set(true, forKey: TrainingDataStore.historyNeedsRescoreKey)
        TrainingDataStore.shared.invalidateResolvedValues()
    }

    /// Pull the cloud values into `settings` and keep watching for changes pushed from
    /// another device. Call once at launch.
    static func startSync(into settings: AppSettings) {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud, queue: .main
        ) { _ in MainActor.assumeIsolated { apply(to: settings) } }
        cloud.synchronize()
        apply(to: settings)
    }

    /// Overwrite the local mirror where the cloud disagrees, then let the settings
    /// object and every threshold reader see it. A key the cloud has never held is
    /// left alone — absent is not `false`.
    @MainActor private static func apply(to settings: AppSettings) {
        var changed = false
        for key in flags where cloud.object(forKey: key) != nil {
            let value = cloud.bool(forKey: key)
            guard UserDefaults.standard.bool(forKey: key) != value else { continue }
            UserDefaults.standard.set(value, forKey: key)
            changed = true
        }
        for key in numbers where cloud.object(forKey: key) != nil {
            let value = cloud.double(forKey: key)
            guard UserDefaults.standard.double(forKey: key) != value else { continue }
            UserDefaults.standard.set(value, forKey: key)
            changed = true
        }
        guard changed else { return }
        // The setters this fires re-enter `didChange()`, which invalidates and notifies;
        // the values are already the ones being read, so the mirror write is a no-op.
        settings.reloadAthleteSettings()
    }
}
