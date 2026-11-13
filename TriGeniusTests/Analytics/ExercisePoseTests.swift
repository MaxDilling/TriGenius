import Foundation
import simd
import Testing
@testable import TriGenius

// Pins `Analytics/ExercisePose.swift`. Expected values are hand-computed: the ease is
// ½ − ½·cos(πx); the two-bone limbs use a 3-4-5 triangle, so the joint lands at
// (3.2, ±2.4) for a target 5 away; a Catmull-Rom curve through two keyframes passes
// their mean halfway.

private func pose(props: String = "{}", hand: String = "[0.1, 1.5]", torso: [Double] = [90]) throws -> ExercisePose {
    let keyframes = torso.map { "{ \"pelvis\": [0, 0.5], \"torso\": \($0), \"head\": 90, \"hand\": \(hand), \"foot\": [0, 0.08, 0] }" }
    let json = """
    { "camera": "side", "props": \(props), "grip": 0.3, "stance": 0.1,
      "hints": { "elbow": [0, -1, 0], "knee": [1, 0, 0] }, "tempo": [2, 1, 2, 1],
      "keyframes": [\(keyframes.joined(separator: ","))] }
    """
    return try JSONDecoder().decode(ExercisePose.self, from: Data(json.utf8))
}

private func close(_ a: Double, _ b: Double, within tolerance: Double = 1e-9) -> Bool { abs(a - b) < tolerance }

private func close(_ a: SIMD3<Double>, _ b: SIMD3<Double>, within tolerance: Double = 1e-9) -> Bool {
    close(a.x, b.x, within: tolerance) && close(a.y, b.y, within: tolerance) && close(a.z, b.z, within: tolerance)
}

// MARK: Time

/// Tempo [2, 1, 2, 1]: 1 s in is halfway out, ease(0.5) = 0.5.
@Test func halfwayThroughTheMoveOutIsHalfProgress() throws {
    #expect(close(try pose().progress(at: 1), 0.5))
}

@Test func theHoldAtTheEndStaysAtTheLastKeyframe() throws {
    #expect(try pose().progress(at: 2.5) == 1)
}

/// 4 s in: 1 s into the 2 s move back, 1 − ease(0.5) = 0.5.
@Test func halfwayBackIsHalfProgress() throws {
    #expect(close(try pose().progress(at: 4), 0.5))
}

/// −1 s wraps to 5 s of the 6 s loop: the hold at the start.
@Test func timeBeforeTheLoopWrapsAround() throws {
    #expect(try pose().progress(at: -1) == 0)
}

// MARK: Two-bone IK

@Test func theJointBendsTowardTheHint() {
    let limb = ExercisePose.twoBone(root: .zero, target: [5, 0, 0], 4, 3, hint: [0, 1, 0])
    #expect(close(limb.joint, [3.2, 2.4, 0]))
}

@Test func anOppositeHintMirrorsTheJoint() {
    let limb = ExercisePose.twoBone(root: .zero, target: [5, 0, 0], 4, 3, hint: [0, -1, 0])
    #expect(close(limb.joint, [3.2, -2.4, 0]))
}

/// Segments of 4 and 3 reach 7 at most (less the 1e-4 that keeps the joint defined).
@Test func anUnreachableTargetLeavesTheLimbStraightTowardIt() {
    let limb = ExercisePose.twoBone(root: .zero, target: [10, 0, 0], 4, 3, hint: [0, 1, 0])
    #expect(close(limb.end, [7 - 1e-4, 0, 0]))
}

// MARK: Keyframes

@Test func twoKeyframesBlendToTheirMeanHalfway() throws {
    let keyframes = try pose(torso: [0, 90]).keyframes
    #expect(close(ExercisePose.blend(keyframes, at: 0.5).torso, 45))
}

/// Torso 90° from a pelvis at (0, 0.5): shoulders (0, 1); the bar sits 0.1 behind
/// and 0.02 above them.
@Test func aBarbellOnTheBackSitsBehindTheShoulders() throws {
    let bar = try pose(props: "{ \"barbell\": \"back\" }", hand: "\"bar\"").skeleton(at: 0).bar
    #expect(bar.map { close($0, [-0.1, 1.02, 0]) } == true)
}

/// Both hands reach (0.1, 1.5) — 0.52 from the shoulders, inside the arm's 0.63.
@Test func aHeldBarbellSitsBetweenTheHands() throws {
    let bar = try pose(props: "{ \"barbell\": \"hands\" }").skeleton(at: 0).bar
    #expect(bar.map { close($0, [0.1, 1.5, 0]) } == true)
}

@Test func aHandOnTheBarNeedsABarbellOnTheBack() {
    #expect(throws: DecodingError.self) { try pose(hand: "\"bar\"") }
}

// MARK: Bundled poses

@Test func everyBundledPoseDecodes() throws {
    let url = try #require(Bundle.main.url(forResource: "exercise-poses", withExtension: "json"))
    let raw = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    #expect(ExercisePoses.all.count == raw.count)
}

@Test func everyPoseBelongsToALibraryExercise() {
    #expect(ExercisePoses.all.keys.allSatisfy { ExerciseLibrary.find(id: $0) != nil })
}

/// Through the whole rep every hand and foot stays within 1.5 cm of where the pose
/// puts it: a keyframe or a blend between two that the limbs cannot reach would
/// otherwise lose the bar or lift a foot.
@Test func everyPoseKeepsHandsAndFeetOnTheirTargets() {
    let misses = ExercisePoses.all.filter { _, pose in
        (0...40).contains { step in
            let s = pose.skeleton(at: Double(step) / 40)
            return [s.near, s.far].contains {
                simd_distance($0.hand, $0.handTarget) > 0.015 || simd_distance($0.ankle, $0.ankleTarget) > 0.015
            }
        }
    }
    #expect(misses.keys.sorted() == [])
}
