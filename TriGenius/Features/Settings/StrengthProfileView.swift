import SwiftUI

// MARK: - Strength profile (handoff flow 7)
//
// The three questions the strength side is set up from — where the athlete
// trains, how much they have lifted, what to work around. Each answer is saved
// the moment it changes, into the same `strength` sport profile fields
// `update_sport_profile` writes. Never asked: a max, bodyweight, days per week.

struct StrengthProfileView: View {
    @ObservedObject var memory: CoachMemory

    private var progress: SportProgress { memory.sportProgress.progress(for: "strength") }

    var body: some View {
        Form {
            Section {
                Picker("Where do you train?", selection: Binding(
                    get: { progress.strengthProfile.place },
                    set: { place in memory.updateSportProgress(sport: "strength") { $0.trainingPlace = place?.rawValue } }
                )) {
                    ForEach(StrengthProfile.Place.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Where do you train?")
            } footer: {
                Text("Sets the equipment the exercise library and the coach offer you.")
            }
            Section("How much have you lifted before?") {
                Picker("How much have you lifted before?", selection: Binding(
                    get: { progress.currentLevel.flatMap(StrengthProfile.Experience.init(rawValue:)) },
                    set: { level in memory.updateSportProgress(sport: "strength") { $0.currentLevel = level?.rawValue } }
                )) {
                    ForEach(StrengthProfile.Experience.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section {
                ForEach(StrengthProfile.Area.allCases, id: \.self) { area in
                    Toggle(area.label, isOn: Binding(
                        get: { progress.strengthProfile.excludedAreas.contains(area) },
                        set: { on in
                            memory.updateSportProgress(sport: "strength") { sp in
                                sp.excludedAreas.removeAll { $0 == area.rawValue }
                                if on { sp.excludedAreas.append(area.rawValue) }
                            }
                        }
                    ))
                }
            } header: {
                Text("Anything to work around?")
            } footer: {
                Text("Only removes the exercises that load it. This isn't medical advice — see a physio for pain.\n\nNo max tests, ever: weights come from the sets you do.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Strength profile")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
