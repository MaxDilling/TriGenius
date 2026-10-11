import Testing
@testable import TriGenius

// Pins `RecencyWeighting.capped` — the share cap `LTHREstimate` puts on its pool.
struct RecencyWeightingTests {

    @Test func aWeightOverTheShareIsClampedOncePerWeight() {
        // 1 of 1.6 is 62.5 %. Each pass clamps it to 25 % of the current total, which the
        // clamp itself lowers: 0.4, 0.25, 0.2125, then 0.203125 after the fourth and last.
        let w = RecencyWeighting.capped([1, 0.2, 0.2, 0.2], share: 0.25)
        #expect(abs(w[0] - 0.203125) < 1e-12 && Array(w[1...]) == [0.2, 0.2, 0.2])
    }

    @Test func weightsUnderTheShareAreUntouched() {
        #expect(RecencyWeighting.capped([1, 1, 1, 1, 1], share: 0.25) == [1, 1, 1, 1, 1])
    }
}
