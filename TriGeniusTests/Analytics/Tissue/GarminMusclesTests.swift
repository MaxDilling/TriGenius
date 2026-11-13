import Testing
@testable import TriGenius

// Pins `ExerciseMuscles` in `Analytics/Tissue/GarminMuscles.swift`: Garmin's own
// muscles where its catalog has the exercise, else every muscle folding onto the
// exercise's own groups.

/// Garmin's BARBELL_BENCH_PRESS: chest primary — kept apart from the shoulders the
/// tissue groups fold it into.
@Test func aPressColoursTheChestAsPrimary() throws {
    let muscles = ExerciseMuscles(try #require(ExerciseLibrary.find(id: "bench_press")))
    #expect(muscles.level([.chest]) == 2)
}

/// Copenhagen plank has no Garmin entry: adductors primary, Low back secondary,
/// which abs, obliques and the lower back all fold onto.
@Test func anExerciseGarminLacksUsesItsOwnGroups() throws {
    let muscles = ExerciseMuscles(try #require(ExerciseLibrary.find(id: "copenhagen_plank")))
    #expect(muscles.secondary == [.lowerBack, .abs, .obliques])
}
