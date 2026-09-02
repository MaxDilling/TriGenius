import Testing
@testable import TriGenius

// Pins `FTPEstimate.fromVO2max`. Expected values are hand-computed from
// `wattsPerAbsoluteVO2 * vo2 * mass`; the constant itself is calibrated in
// `ref/ftp_lab` and these pins are the spec for the port.
struct FTPEstimateTests {

    @Test func estimatesFromVO2maxAndMass() {
        // 0.0584 * 57.0 * 75.6 = 251.65728
        #expect(FTPEstimate.fromVO2max(57.0, massKg: 75.6)! == 251.65728)
    }

    @Test func scalesWithBodyMass() {
        // Same VO2max per kg, lighter athlete -> proportionally less absolute power.
        // 0.0584 * 43.0 * 62.0 = 155.6944
        #expect(FTPEstimate.fromVO2max(43.0, massKg: 62.0)! == 155.6944)
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
