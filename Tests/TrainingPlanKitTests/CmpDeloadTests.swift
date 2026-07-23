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
}
