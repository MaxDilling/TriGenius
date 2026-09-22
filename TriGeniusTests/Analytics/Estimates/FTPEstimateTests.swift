import Testing
@testable import TriGenius

// Pins `FTPEstimate.fromVO2max`. Expected values are hand-computed from
// `wattsPerAbsoluteVO2 * vo2 * mass`, where the constant is the published chain
// `0.22 (gross efficiency) x 0.76 (fraction of VO2max at threshold) x 20.9/60
// (W per ml O2/min) = 0.0582413...`. Derivation: `ref/threshold_lab/cycling`.
struct FTPEstimateTests {

    @Test func estimatesFromVO2maxAndMass() {
        // 0.05824133333333334 * 57.0 * 75.6 = 250.9735536
        #expect(FTPEstimate.fromVO2max(57.0, massKg: 75.6)! == 250.9735536)
    }

    @Test func scalesWithBodyMass() {
        // Same VO2max per kg, lighter athlete -> proportionally less absolute power.
        // 0.05824133333333334 * 43.0 * 62.0 = 155.27139466666668
        #expect(FTPEstimate.fromVO2max(43.0, massKg: 62.0)! == 155.27139466666668)
    }

    @Test func missingInputYieldsNoEstimate() {
        #expect(FTPEstimate.fromVO2max(nil, massKg: 75.6) == nil)
        #expect(FTPEstimate.fromVO2max(57.0, massKg: nil) == nil)
    }

    @Test func nonPositiveInputYieldsNoEstimate() {
        #expect(FTPEstimate.fromVO2max(0, massKg: 75.6) == nil)
        #expect(FTPEstimate.fromVO2max(57.0, massKg: 0) == nil)
    }
}
