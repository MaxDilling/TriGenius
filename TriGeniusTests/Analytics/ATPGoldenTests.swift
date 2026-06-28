import Foundation
import Testing
@testable import TriGenius

// MARK: - ATP golden-master calibration tests
//
// Pins the ATP weekly-TSS engine against a corpus of real TrainingPeaks plans
// (`ref/atp_lab/data/plans/*.json` — config + events sent to TP, weekly `volume`
// TP returned). Each plan is one parameterized case: we feed its config/events to
// `ATPPeriodization.layout` + `ATPEngine.weeklyTSS` and compare our `plannedTSS`
// series, week by week, to TP's `volume` series.
//
// These are EXPECTED TO FAIL until the engine is calibrated — that's the point.
// A failure prints the WHOLE series side by side (engine vs TP, with periods and
// per-week delta) plus the aggregate mean-absolute-error, bias and RMSE, so the
// miss is diagnosable at a glance instead of "week 13 said 12, wanted 235".
//
// The single acceptance threshold lives in `ATPGoldenTolerance` below.

/// The one place that says how close to TrainingPeaks counts as "matching".
/// Both are in raw TSS units, measured over a plan's full weekly series.
enum ATPGoldenTolerance {
    /// Max acceptable mean absolute weekly-TSS error vs TP.
    static let maxMeanAbsError: Double = 20
    /// Max acceptable root-mean-square weekly-TSS error vs TP.
    static let maxRMSE: Double = 30
}

// MARK: - Fixtures

/// Locate `ref/atp_lab/data/plans` by walking up from this source file (tests run
/// on macOS against the working tree — the plans aren't bundled).
private func plansDirectory() -> URL? {
    var dir = URL(fileURLWithPath: #filePath)
    for _ in 0..<8 {
        dir.deleteLastPathComponent()
        let candidate = dir.appendingPathComponent("ref/atp_lab/data/plans")
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
    }
    return nil
}

/// Every plan fixture, unfiltered.
private func allPlanFiles() -> [String] {
    guard let dir = plansDirectory(),
          let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
    else { return [] }
    return names.filter { $0.hasSuffix(".json") }.sorted()
}

/// The plans the parameterized test runs — `allPlanFiles()` narrowed by
/// `ATPGoldenFilter.current` (env-driven). With no env filter set, that's all of
/// them; with e.g. `ATP_FITNESS=Strong` it's just the Strong ones.
private func planFiles() -> [String] {
    guard let dir = plansDirectory() else { return [] }
    let filter = ATPGoldenFilter.current
    return allPlanFiles().filter { name in
        guard let f = try? loadFixture(dir.appendingPathComponent(name)) else { return false }
        return filter.matches(f, file: name)
    }
}

private func loadFixture(_ url: URL) throws -> PlanFixture {
    try JSONDecoder().decode(PlanFixture.self, from: Data(contentsOf: url))
}

/// The slice of a TP plan export the calibration cares about.
private struct PlanFixture: Decodable {
    let name: String
    let dimension: String
    let atp_config_sent: ConfigSent
    let events_sent: [EventSent]
    let atp_result: ResultBlock
    let pins: Pins?

    struct ConfigSent: Decodable {
        let startWeek: String
        let atpType: String
        let weeklyAvgVolume: String      // TP sends this as a string
        let recoveryCycle: String        // "ThreeWeeks" | "FourWeeks"
        let currentFitnessLevel: String
        let ctlStart: Double?
    }
    struct EventSent: Decodable {
        let eventDate: String
        let name: String
        let eventType: String
        let atpPriority: String          // "A" | "B" | "C"
        let ctlTarget: Double?
    }
    struct ResultBlock: Decodable { let atpWeeks: [WeekResult] }
    struct WeekResult: Decodable {
        let startDay: String
        let period: String?      // null on TP's post-event "Not-Set" weeks
        let volume: Double
    }
    struct Pins: Decodable {
        let applied: [Applied]?
        struct Applied: Decodable { let startDay: String; let volume: Double }
    }
}

// MARK: - Filtering (the corpus is growing past 60 plans)
//
// Swift Testing `@Tag`s attach to a test function, not to individual data-driven
// arguments, so per-plan filtering is done by narrowing the `arguments:` list with
// these keys. Unset ⇒ all plans run.
//   ATP_FITNESS  currentFitnessLevel, case-insensitive ("Strong" | "Weak")
//   ATP_EVENTS   exact event count (e.g. "1")
//   ATP_METHOD   "TSS" | "CTL" (atpType)
//   ATP_DIM      dimension substring  (e.g. "pins", "tss", "events")
//   ATP_NAME     plan-name / file-name substring (e.g. "13", "spacing")
//
// Two ways to set them, because `xcodebuild` scrubs the shell environment before
// launching the test runner (a CLI `ATP_FITNESS=… xcodebuild test` does NOT reach
// the test):
//   • IDE — Scheme ▸ Test ▸ Arguments ▸ Environment Variables (these ARE forwarded).
//   • CLI — a `key=value`-per-line file at `ref/atp_lab/.atp_test_filter`
//     (git-ignored). A set env var wins over the file. Delete the file ⇒ all plans.
private struct ATPGoldenFilter {
    let fitness: String?
    let events: Int?
    let method: String?
    let dimension: String?
    let name: String?

    static let current = ATPGoldenFilter(
        fitness: value("ATP_FITNESS"), events: value("ATP_EVENTS").flatMap { Int($0) },
        method: value("ATP_METHOD"), dimension: value("ATP_DIM"), name: value("ATP_NAME"))

    /// `key=value` lines from `ref/atp_lab/.atp_test_filter`, the CLI fallback.
    private static let fileValues: [String: String] = {
        guard let url = plansDirectory()?
                .deletingLastPathComponent().deletingLastPathComponent()  // plans → data → atp_lab
                .appendingPathComponent(".atp_test_filter"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
            out[String(t[..<eq]).trimmingCharacters(in: .whitespaces)] =
                String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        }
        return out
    }()

    private static func value(_ k: String) -> String? {
        let v = ProcessInfo.processInfo.environment[k] ?? fileValues[k]
        return v?.isEmpty == false ? v : nil
    }

    func matches(_ f: PlanFixture, file: String) -> Bool {
        if let fitness, f.atp_config_sent.currentFitnessLevel.caseInsensitiveCompare(fitness) != .orderedSame { return false }
        if let events, f.events_sent.count != events { return false }
        if let method, f.atp_config_sent.atpType.caseInsensitiveCompare(method) != .orderedSame { return false }
        if let dimension, !f.dimension.localizedCaseInsensitiveContains(dimension) { return false }
        if let name, !f.name.localizedCaseInsensitiveContains(name), !file.localizedCaseInsensitiveContains(name) { return false }
        return true
    }
}

// MARK: - Mapping TP → engine DTOs

private let plansCal = Calendar.current

/// Parse a `"2026-05-18T00:00:00"` TP timestamp to local midnight, so its week
/// snaps to the same Monday `TrainingVolume.weekStart` uses.
private func parseDay(_ s: String) -> Date {
    let d = s.split(separator: "T").first.map(String.init) ?? s
    let p = d.split(separator: "-").compactMap { Int($0) }
    guard p.count == 3 else { return Date(timeIntervalSince1970: 0) }
    var c = DateComponents()
    c.year = p[0]; c.month = p[1]; c.day = p[2]
    return plansCal.date(from: c) ?? Date(timeIntervalSince1970: 0)
}

private func methodology(_ atpType: String) -> ATPMethodology {
    atpType == "CTL" ? .targetCTL : .weeklyTSS
}

private func recoveryWeeks(_ cycle: String) -> Int { cycle == "ThreeWeeks" ? 3 : 4 }

private func priority(_ p: String) -> ATPEventPriority {
    ATPEventPriority(rawValue: p) ?? .a
}

private func params(_ f: PlanFixture) -> ATPParams {
    ATPParams(
        startDate: parseDay(f.atp_config_sent.startWeek),
        startingCTL: f.atp_config_sent.ctlStart,
        methodology: methodology(f.atp_config_sent.atpType),
        recoveryCycle: recoveryWeeks(f.atp_config_sent.recoveryCycle),
        maxRampRate: 7,
        weeklyAverageTSS: Double(f.atp_config_sent.weeklyAvgVolume) ?? 0)
}

private func events(_ f: PlanFixture) -> [ATPEventInput] {
    f.events_sent.map {
        ATPEventInput(id: UUID().uuidString, name: $0.name, date: parseDay($0.eventDate),
                      eventType: $0.eventType, priority: priority($0.atpPriority),
                      targetCTL: $0.ctlTarget, notes: "")
    }
}

private func overrides(_ f: PlanFixture) -> [ATPWeekOverrideInput] {
    (f.pins?.applied ?? []).map {
        ATPWeekOverrideInput(weekStart: parseDay($0.startDay), pinnedTSS: $0.volume, note: "")
    }
}

// MARK: - Comparison

private struct WeekDelta {
    let weekStart: Date
    let enginePeriod: String
    let tpPeriod: String
    let engineTSS: Double
    let tpTSS: Double
    var diff: Double { engineTSS - tpTSS }
}

private struct PlanComparison {
    let rows: [WeekDelta]
    var n: Int { rows.count }
    var meanSignedError: Double { n == 0 ? 0 : rows.reduce(0) { $0 + $1.diff } / Double(n) }
    var meanAbsError: Double { n == 0 ? 0 : rows.reduce(0) { $0 + abs($1.diff) } / Double(n) }
    var rmse: Double { n == 0 ? 0 : (rows.reduce(0) { $0 + $1.diff * $1.diff } / Double(n)).squareRoot() }
    var maxAbsError: Double { rows.map { abs($0.diff) }.max() ?? 0 }
}

/// Run the engine on a fixture and pair each produced week to TP's `volume`.
private func compare(_ f: PlanFixture) -> PlanComparison {
    let p = params(f)
    let evs = events(f)
    let shells = ATPPeriodization.layout(params: p, events: evs)
    let weeks: [ATPWeekPlan]
    switch p.methodology {
    case .weeklyTSS: weeks = ATPEngine.weeklyTSS(shells: shells, params: p, overrides: overrides(f))
    case .targetCTL: weeks = ATPEngine.targetCTL(shells: shells, params: p, events: evs, overrides: overrides(f))
    }

    // TP weekly volume + raw period, keyed by Monday.
    var tpVolume: [Date: Double] = [:]
    var tpPeriod: [Date: String] = [:]
    for w in f.atp_result.atpWeeks {
        let k = TrainingVolume.weekStart(of: parseDay(w.startDay))
        tpVolume[k] = w.volume
        tpPeriod[k] = w.period ?? "Not-Set"
    }

    let rows = weeks.map { w in
        WeekDelta(weekStart: w.weekStart,
                  enginePeriod: w.period.label + (w.isRecovery ? " (rec)" : "") + (w.isTaper ? " (taper)" : ""),
                  tpPeriod: tpPeriod[w.weekStart] ?? "—",
                  engineTSS: w.plannedTSS,
                  tpTSS: tpVolume[w.weekStart] ?? 0)
    }
    return PlanComparison(rows: rows)
}

private let dayFmt: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.calendar = plansCal; return f
}()

/// Full side-by-side report — printed only when a case fails.
private func report(_ f: PlanFixture, _ c: PlanComparison) -> String {
    var s = """
    ATP plan "\(f.name)" [\(f.dimension)] — engine vs TrainingPeaks
      method=\(methodology(f.atp_config_sent.atpType)) avgTSS=\(f.atp_config_sent.weeklyAvgVolume) \
    recovery=\(f.atp_config_sent.recoveryCycle) fitness=\(f.atp_config_sent.currentFitnessLevel) \
    ctlStart=\(f.atp_config_sent.ctlStart.map { String($0) } ?? "nil") pins=\(overrides(f).count)
      events: \(f.events_sent.map { "\($0.atpPriority) \($0.name) @\($0.eventDate.prefix(10))" }.joined(separator: ", "))

      meanAbsError=\(String(format: "%.1f", c.meanAbsError)) (≤ \(ATPGoldenTolerance.maxMeanAbsError))  \
    RMSE=\(String(format: "%.1f", c.rmse)) (≤ \(ATPGoldenTolerance.maxRMSE))  \
    bias=\(String(format: "%+.1f", c.meanSignedError))  maxAbs=\(String(format: "%.1f", c.maxAbsError))  n=\(c.n)

      wk  date        engine                 TP                 |  engineTSS    tpTSS     Δ
      --  ----------  ---------------------  -----------------  |  ---------  -------  ------

    """
    func pad(_ str: String, _ w: Int) -> String {
        str.count >= w ? str : str + String(repeating: " ", count: w - str.count)
    }
    for (i, r) in c.rows.enumerated() {
        s += String(format: "  %2d  %@  %@  %@  |  %8.0f  %7.0f  %+6.0f\n",
                    i, dayFmt.string(from: r.weekStart) as NSString,
                    pad(r.enginePeriod, 21) as NSString, pad(r.tpPeriod, 17) as NSString,
                    r.engineTSS, r.tpTSS, r.diff)
    }
    return s
}

// MARK: - Tests

@Test func atpGoldenFixturesPresent() {
    // Checks the corpus itself, not the (env-filtered) run set.
    #expect(!allPlanFiles().isEmpty,
            "No ATP plan fixtures found under ref/atp_lab/data/plans relative to \(#filePath)")
}

@Test(arguments: planFiles())
func atpWeeklyVolumeMatchesTrainingPeaks(_ file: String) throws {
    let url = try #require(plansDirectory()).appendingPathComponent(file)
    let f = try loadFixture(url)
    let c = compare(f)

    #expect(c.n > 0, "\(file): engine produced no weeks to compare")
    #expect(c.meanAbsError <= ATPGoldenTolerance.maxMeanAbsError
            && c.rmse <= ATPGoldenTolerance.maxRMSE,
            "\(report(f, c))")
}
