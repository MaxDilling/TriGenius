import SwiftUI

// MARK: - Live strength controller
//
// Owns the one running `StrengthSession`: every change goes through `update`,
// which writes the session to `live_strength.json` (device-local — a killed app
// resumes where it was), re-arms the next deadline and keeps the display awake
// while a session runs. The deadlines are the moments the athlete should feel:
// five seconds before a rest ends, its end, and a hold's end — which also logs
// the hold at its target. Nothing reaches the store until `save`.

@MainActor
@Observable
final class LiveStrengthController {
    static let shared = LiveStrengthController()

    private(set) var session: StrengthSession?
    /// Full screen, as opposed to collapsed into the mini bar.
    var isPresented = false
    /// Bumped at every deadline; views play a haptic on the change.
    private(set) var cue = 0

    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var lifted: [String: [StrengthSets.SetRow]] = [:]
    @ObservationIgnored private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("live_strength.json")
    }()

    private init() {
        session = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(StrengthSession.self, from: $0) }
        changed()
    }

    /// Start a session of `plan`, or open the one already running.
    func start(_ plan: WorkoutRecord) {
        if session == nil {
            session = StrengthSession(planId: plan.id, planName: plan.name, sport: plan.sport,
                                      plannedMinutes: plan.plannedDurationMinutes,
                                      steps: WorkoutPayloadBuilder.parseSteps(plan.stepsJSON) ?? [], at: .now)
            changed()
        }
        isPresented = true
    }

    func update(_ change: (inout StrengthSession, Date) -> Void) {
        guard var s = session else { return }
        change(&s, .now)
        session = s
        changed()
    }

    /// Write the session to the store as the plan's completed session.
    func save() {
        guard let session else { return }
        DataSyncCoordinator.shared.saveLiveStrength(session)
        close()
    }

    /// Drop the session; the plan stays exactly as it was.
    func close() {
        session = nil
        lifted = [:]
        isPresented = false
        changed()
    }

    /// What was lifted on this set's exercise last time, read once per session.
    func lastLifted(_ set: StrengthSets.SetRow) -> [StrengthSets.SetRow] {
        guard let key = set.garminKey else { return [] }
        if let cached = lifted[key] { return cached }
        let sets = TrainingDataStore.shared.lastLiftedSets(key: key)
        lifted[key] = sets
        return sets
    }

    private func changed() {
        if let session, let data = try? JSONEncoder().encode(session) {
            try? data.write(to: fileURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: fileURL)
        }
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = session != nil
        #endif
        arm()
    }

    private func arm() {
        deadline?.cancel()
        guard let s = session, s.pausedAt == nil, s.endedAt == nil else { return }
        let now = Date.now
        let fire: Date
        switch s.phase(at: now) {
        case .resting(_, let until?):
            let warning = until.addingTimeInterval(-5)
            fire = warning > now ? warning : until
        case .holding(let since):
            guard let seconds = s.current?.seconds else { return }
            fire = since.addingTimeInterval(seconds)
        default:
            return
        }
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, fire.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.reach(fire)
        }
    }

    private func reach(_ date: Date) {
        cue += 1
        update { s, _ in
            if case .holding = s.phase, var set = s.draft {
                set.seconds = s.current?.seconds
                s.complete(set, at: date)
            } else {
                s.settle(at: date)
            }
        }
    }
}
