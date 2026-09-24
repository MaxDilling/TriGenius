import Testing
@testable import TriGenius

// Pins `Analytics/Tissue/StrengthProfile.swift`: which library exercises a
// training place and the areas to work around leave available (handoff flow 7,
// D10 — exclusion only).

private func allowed(_ profile: StrengthProfile, _ id: String) -> Bool {
    ExerciseLibrary.find(id: id).map(profile.allows) ?? false
}

@Test func anUnsetProfileAllowsEveryExercise() {
    #expect(ExerciseLibrary.all.allSatisfy(StrengthProfile().allows))
}

@Test func homeWithWeightsDropsTheBarbell() {
    let home = StrengthProfile(place: .homeWeights)
    #expect(allowed(home, "back_squat") == false)
    #expect(allowed(home, "bicep_curl") == true)
    #expect(allowed(home, "push_up") == true)
}

@Test func bodyweightOnlyKeepsBodyweightExercises() {
    let bodyweight = StrengthProfile(place: .bodyweight)
    #expect(ExerciseLibrary.all.filter(bodyweight.allows).allSatisfy { $0.equipment == .bodyweight })
}

@Test func aKneeExcludesEveryExerciseLoadingTheQuads() {
    let knee = StrengthProfile(excludedAreas: [.knee])
    #expect(allowed(knee, "back_squat") == false)
    #expect(allowed(knee, "conventional_deadlift") == false)
    #expect(allowed(knee, "push_up") == true)
}

@Test func theSummaryNamesPlaceAndAreas() {
    #expect(StrengthProfile(place: .gym, excludedAreas: [.shoulder, .achilles]).summary
            == "trains at: gym; works around: achilles, shoulder")
    #expect(StrengthProfile().summary == nil)
}
