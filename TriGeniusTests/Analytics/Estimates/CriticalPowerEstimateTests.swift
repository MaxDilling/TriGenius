import Foundation
import Testing
@testable import TriGenius

// Pins `CriticalPowerEstimate`. Floors and the posterior are pinned against the lab
// reference on the same inputs (`ref/threshold_lab/cycling/loader.wbal_floor`,
// `cp_wprime.estimate`); FTP and the balance are hand-computed.
struct CriticalPowerEstimateTests {

    @Test func ftpIsCPTimesTheThresholdShareOfIt() {
        // 300 * 0.76 / 0.821
        #expect(abs(CriticalPowerEstimate.ftp(cp: 300) - 277.7101096224117) < 1e-12)
    }

    // MARK: floors

    /// 10 min easy, 5 min at 350 W, 1 min at 100 W, 2 min at 400 W, 10 min easy.
    private let ride: [Double?] = [Double](repeating: 150, count: 600) + [Double](repeating: 350, count: 300)
        + [Double](repeating: 100, count: 60) + [Double](repeating: 400, count: 120)
        + [Double](repeating: 150, count: 600)

    private func index(_ cp: Double) -> Int {
        Int((cp - CriticalPowerEstimate.floorGridStart) / CriticalPowerEstimate.floorGridStep)
    }

    @Test func floorsMatchTheLabReference() {
        let f = CriticalPowerEstimate.floors(power: ride)
        #expect(f.count == CriticalPowerEstimate.floorGridCount)
        // At 200 W the work above CP already passes the 60 kJ cap, so it stands as is;
        // at 250 W and 300 W the one-minute gap refills at k = 1.2 only partly, and the
        // fixed point lies above the 39 and 15 kJ of instant refill.
        #expect(abs(f[index(200)] - 63) < 1e-9)
        #expect(abs(f[index(250)] - 41.06080941978308) < 1e-9)
        #expect(abs(f[index(300)] - 19.039005500053005) < 1e-9)
        #expect(f[index(450)] == 0)
    }

    @Test func gapsAreInterpolatedAndTheEdgesAreNotRide() {
        #expect(CriticalPowerEstimate.oneHertz([nil, 100, nil, nil, 400, nil]) == [100, 200, 300, 400])
        #expect(CriticalPowerEstimate.floors(power: [nil, nil]).isEmpty)
    }

    @Test func floorsRoundTripAtTenJoules() {
        let f = CriticalPowerEstimate.floors(power: ride)
        let decoded = CriticalPowerEstimate.decode(CriticalPowerEstimate.encode(f))
        #expect(decoded.count == CriticalPowerEstimate.floorGridCount)
        #expect(decoded[index(250)] == 41.06)
        #expect(decoded[index(450)] == 0)
        #expect(CriticalPowerEstimate.encode([0, 0]).isEmpty)
        #expect(CriticalPowerEstimate.decode("").isEmpty)
    }

    // MARK: balance

    @Test func balanceSpendsAboveCPAndRefillsBelowIt() {
        // 10 s at 300 W against CP 250 spends 500 J of 10 kJ; one second at 100 W
        // refills to 10 - 0.5 * exp(1.2 / 10000 * (100 - 250)) kJ.
        let b = CriticalPowerEstimate.balance(power: [nil] + [Double](repeating: 300, count: 10) + [100],
                                              cp: 250, wPrimeKJ: 10)
        #expect(b[0] == nil)
        #expect(abs(b[10]! - 9.5) < 1e-12)
        #expect(abs(b[11]! - 9.508919483820849) < 1e-12)
    }

    // MARK: posterior

    @Test func posteriorMatchesTheLabReference() throws {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func day(_ d: Double) -> Date { t0.addingTimeInterval(d * 86_400) }
        let second = [Double](repeating: 150, count: 600) + [Double](repeating: 380, count: 240)
            + [Double](repeating: 150, count: 600)
        let rides = [(day(40), ride), (day(90), second.map { Optional($0) })].map {
            CriticalPowerEstimate.Ride(date: $0.0, floors: CriticalPowerEstimate.decode(
                CriticalPowerEstimate.encode(CriticalPowerEstimate.floors(power: $0.1))))
        }
        let e = try #require(CriticalPowerEstimate.estimate(asOf: day(100), rides: rides) { _ in (260, 0.03) })
        #expect(e.cp == 281)
        #expect(e.wPrimeKJ == 22.25)
        #expect(abs(e.cpRange.lowerBound - 257.14027111088734) < 1e-6)
        #expect(abs(e.cpRange.upperBound - 299.50577867676265) < 1e-6)
        #expect(abs(e.wPrimeRange.lowerBound - 18.46512164350724) < 1e-6)
        #expect(abs(e.wPrimeRange.upperBound - 39.152060163072285) < 1e-6)
    }

    @Test func withoutFloorsThePriorsSpeak() throws {
        let e = try #require(CriticalPowerEstimate.estimate(asOf: Date(), rides: []) { _ in (260, 0.03) })
        #expect(e.cp == 260)
        // The mode of Triska's log-normal, 16.3 ± 7.4 kJ, on the 0.25 kJ grid.
        #expect(e.wPrimeKJ == 12.25)
    }

    @Test func noAerobicPriorNoEstimate() {
        #expect(CriticalPowerEstimate.estimate(asOf: Date(), rides: []) { _ in nil } == nil)
    }
}
