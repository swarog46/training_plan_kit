import XCTest
@testable import TrainingPlanKit

/// Deload weeks cut the STRESSOR (R18): no race rehearsal, no midweek
/// marathon-pace session, no MP-finish progressive long. Volume already drops;
/// these guarantee the down week is actually down in intensity too.
/// Covers the real competitive configs AND the Int/Adv marathon tiers whose
/// `preferMP` used to force an MP session onto even-indexed deload peak weeks.
final class CmpDeloadTests: XCTestCase {

    private func assertNoMPStressorOnDeloads(config: PlanConfiguration, weeks: Int,
                                             label: String, file: StaticString = #filePath,
                                             line: UInt = #line) {
        let cal = Calendar.current
        let catalog = loadSampleCatalog()
        let start = cal.startOfDay(for: Date())
        let race = cal.date(byAdding: .weekOfYear, value: weeks, to: start)!
        let events = createMarathonPlanV3(startDate: start, raceDate: race,
                                          from: catalog, planId: UUID(), config: config)

        let banned: Set<WorkoutSubtype> = [.marathonPace, .progressiveLong,
                                           .raceRehearsalM, .raceRehearsalHM, .raceRehearsal10K]
        var deloadWeeksSeen = 0
        var byWeek: [Int: [WorkoutEvent]] = [:]
        for e in events { byWeek[e.planWeekIndex, default: []].append(e) }
        for (week, evs) in byWeek where evs.contains(where: { $0.isDeloadWeek }) && !evs.contains(where: { $0.isTaperWeek }) {
            deloadWeeksSeen += 1
            for e in evs {
                XCTAssertFalse(banned.contains(e.workout.subtype),
                    "\(label) deload w\(week) carries MP stressor: \(e.workout.subtype)",
                    file: file, line: line)
            }
        }
        XCTAssertGreaterThan(deloadWeeksSeen, 0, "\(label): no deload weeks found",
                             file: file, line: line)
    }

    func testCompetitiveDeloadWeeksCarryNoMPStressor() {
        assertNoMPStressorOnDeloads(config: .competitive42Default, weeks: 18, label: "cmp 42K")
        assertNoMPStressorOnDeloads(config: .competitive21Default, weeks: 12, label: "cmp 21K")
    }

    func testAdvancedAndIntermediateMarathonDeloadsCarryNoMPStressor() {
        assertNoMPStressorOnDeloads(
            config: PlanConfiguration.raceConfig(level: .advanced, distanceMeters: 42195),
            weeks: 16, label: "adv 42K")
        assertNoMPStressorOnDeloads(
            config: PlanConfiguration.raceConfig(level: .intermediate, distanceMeters: 42195),
            weeks: 16, label: "int 42K")
    }

    /// Pfitz-shaped recovery + taper for competitive: deload weeks keep the
    /// training frequency but land at a -15..-32% volume dip (not the -40%+
    /// crash), and the last two pre-race weeks never carry a 2h long run.
    func testCompetitiveDeloadDepthAndTaperLong() {
        let cal = Calendar.current
        let catalog = loadSampleCatalog()
        let start = cal.startOfDay(for: Date())

        for (config, weeks, label) in [(PlanConfiguration.competitive42Default, 18, "cmp 42K"),
                                       (.competitive21Default, 12, "cmp 21K")] {
            let race = cal.date(byAdding: .weekOfYear, value: weeks, to: start)!
            let events = createMarathonPlanV3(startDate: start, raceDate: race,
                                              from: catalog, planId: UUID(), config: config)
            var byWeek: [Int: [WorkoutEvent]] = [:]
            for e in events where e.planWeekIndex >= 0 { byWeek[e.planWeekIndex, default: []].append(e) }
            func mins(_ evs: [WorkoutEvent]) -> Double { evs.reduce(0.0) { $0 + Double($1.workout.duration) / 60 } }

            for (w, evs) in byWeek
            where evs.contains(where: { $0.isDeloadWeek }) && !evs.contains(where: { $0.isTaperWeek }) {
                guard let prev = byWeek[w - 1], let next = byWeek[w + 1],
                      !prev.contains(where: { $0.isTaperWeek }), !next.contains(where: { $0.isTaperWeek })
                else { continue }
                let nb = max(mins(prev), mins(next))
                let cut = 1.0 - mins(evs) / nb
                XCTAssertTrue((0.10...0.35).contains(cut),
                    "\(label) deload w\(w): cut \(Int(cut * 100))% outside the Pfitz band (10-35%)")
                XCTAssertGreaterThanOrEqual(Set(evs.map { cal.startOfDay(for: $0.date) }).count,
                    config.trainingDays.count - 1,
                    "\(label) deload w\(w) dropped below \(config.trainingDays.count - 1) days")
            }

            // Taper: the long run steps DOWN — no ≥2h long inside the final 2 weeks.
            let raceDay = cal.startOfDay(for: race)
            for e in events {
                guard let days = cal.dateComponents([.day], from: cal.startOfDay(for: e.date), to: raceDay).day,
                      days <= 14, days > 0 else { continue }
                let longSubs: Set<WorkoutSubtype> = [.long, .steadyLong, .mediumLong, .progressiveLong]
                if longSubs.contains(e.workout.subtype) {
                    XCTAssertLessThanOrEqual(Int(e.workout.duration) / 60, 115,
                        "\(label): \(Int(e.workout.duration) / 60)min long \(days)d before race")
                }
            }
        }
    }
}
