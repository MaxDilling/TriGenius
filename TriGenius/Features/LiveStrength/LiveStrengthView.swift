import SwiftUI

// MARK: - Live strength workout
//
// The full-screen session: a floating glass bar (collapse, clock, pause) above
// two pages — the current set or its rest, and the queue — and the summary once
// the session has ended. Presented from `RootTabView`, so collapsing it leaves
// the mini bar (`LiveStrengthMiniBar`) above the tab bar on iOS.

struct LiveStrengthView: View {
    @Bindable private var live = LiveStrengthController.shared
    @State private var page: Int? = 0

    var body: some View {
        if let session = live.session {
            if session.endedAt != nil {
                LiveSummaryView(session: session)
            } else {
                VStack(spacing: Theme.Spacing.m) {
                    topBar(session)
                    pages(session)
                    pageDots
                }
                .padding(.vertical, Theme.Spacing.s)
                .background(Color.appBackground)
            }
        }
    }

    private func topBar(_ session: StrengthSession) -> some View {
        GlassEffectContainer(spacing: Theme.Spacing.s) {
            HStack {
                Button { live.isPresented = false } label: { Image(systemName: "chevron.down") }
                    .accessibilityLabel("Minimize workout")
                    .liveRoundButton()
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: Theme.Spacing.xs) {
                        Text(LiveFormat.clock(session.elapsed(at: context.date))).fontWeight(.semibold)
                        if session.plannedMinutes > 0 {
                            Text("/ ~\(LiveFormat.clock(session.plannedMinutes * 60))").foregroundStyle(.secondary)
                        }
                    }
                    .monospacedDigit()
                }
                .headerPill()
                Spacer()
                Button {
                    live.update { s, now in s.pausedAt == nil ? s.pause(at: now) : s.resume(at: now) }
                } label: {
                    Image(systemName: session.pausedAt == nil ? "pause.fill" : "play.fill")
                }
                .accessibilityLabel(session.pausedAt == nil ? "Pause workout" : "Resume workout")
                .liveRoundButton()
            }
        }
        .padding(.horizontal)
    }

    private func pages(_ session: StrengthSession) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                LiveSetPage(session: session).containerRelativeFrame(.horizontal).id(0)
                LiveQueuePage(session: session).containerRelativeFrame(.horizontal).id(1)
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $page)
        .scrollIndicators(.hidden)
    }

    private var pageDots: some View {
        HStack(spacing: Theme.Spacing.s) {
            ForEach(0..<2, id: \.self) { index in
                Circle()
                    .fill(page == index ? Color.primary : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
                    .onTapGesture { withAnimation { page = index } }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Shared pieces

/// Sets done (success) and the current one (accent) over every set of the session.
struct LiveProgressBar: View {
    let session: StrengthSession

    var body: some View {
        GeometryReader { geo in
            let total = max(1, CGFloat(session.totalSets))
            let unit = geo.size.width / total
            HStack(spacing: 2) {
                Capsule().fill(Theme.Palette.success).frame(width: unit * CGFloat(session.doneSets))
                if session.current != nil { Capsule().fill(Color.accentColor).frame(width: unit) }
                Spacer(minLength: 0)
            }
            .background(Color.appTertiaryBackground, in: Capsule())
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("\(session.doneSets) of \(session.totalSets) sets done")
    }
}

enum LiveFormat {
    /// "8:42", "1:02:05".
    static func clock(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, seconds).rounded(.down))
            .formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    /// "8 · BW", "5 · 60 kg", "0:30 · BW".
    static func set(_ set: StrengthSets.SetRow) -> String {
        let extent = set.reps.map(String.init) ?? ExerciseSetsCard.time(set.seconds)
        return "\(extent) · \(load(set.weightKg))"
    }

    static func load(_ kg: Double?) -> String {
        kg.map { "\($0.formatted(.number.precision(.fractionLength(0...1)))) kg" } ?? "BW"
    }

    /// "rest 0:45", "rest until ready", nil where none follows.
    static func rest(_ rest: StrengthSets.Rest?) -> String? {
        switch rest {
        case .timed(let seconds): return "rest \(ExerciseSetsCard.time(seconds))"
        case .lapButton: return "rest until ready"
        case nil: return nil
        }
    }
}

extension View {
    /// A round glass control of the floating layer.
    func liveRoundButton() -> some View {
        self.font(.headline)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
    }
}

// MARK: - Mini bar

/// The collapsed session above the tab bar: what is happening now, one tap back in.
struct LiveStrengthMiniBar: View {
    let session: StrengthSession
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: Theme.Spacing.m) {
                    Image(systemName: "dumbbell.fill").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(session.current?.title ?? session.planName).font(.subheadline.weight(.semibold))
                        Text(status(at: context.date)).font(.caption).foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    Spacer()
                    Text(LiveFormat.clock(session.elapsed(at: context.date))).font(.subheadline).monospacedDigit()
                }
                .padding(.horizontal, Theme.Spacing.l)
            }
        }
        .buttonStyle(.plain)
    }

    private func status(at now: Date) -> String {
        if session.endedAt != nil { return "Workout complete · save it" }
        if session.pausedAt != nil { return "Paused" }
        switch session.phase(at: now) {
        case .resting(_, let until?): return "Rest \(LiveFormat.clock(until.timeIntervalSince(now)))"
        case .resting: return "Rest · until ready"
        default:
            guard let position = session.currentSetPosition, let draft = session.draft else { return "" }
            return "Set \(position.number) of \(position.of) · \(LiveFormat.set(draft))"
        }
    }
}
