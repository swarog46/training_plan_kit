import XCTest
@testable import TrainingPlanKit

/// Weeks hold at most the plan's quality cap (recovery weeks one session) and recovery weeks dip.
final class QualityCapTests: XCTestCase {
    private let catalog = loadSampleCatalog()

    private func qualityPerWeek(_ config: PlanConfiguration, weeks: Int) -> [(week: Int, count: Int, deload: Bool)] {
        let (plan, deloads, taper) = generatePlanV3WithDeloads(config: config, totalWeeks: weeks, allWorkouts: catalog)
        return plan.keys.sorted().filter { !taper.contains($0) }.map { week in
            (week, plan[week]!.filter { $0.workout.subtype.qualityRank != nil }.count, deloads.contains(week))
        }
    }

    func testAdvancedTenKHoldsTwoQualitySessions() {
        let weeks = qualityPerWeek(.raceConfig(level: .advanced, distanceMeters: 10000), weeks: 12)
        XCTAssertTrue(weeks.contains { $0.count == 2 })
        for w in weeks { XCTAssertLessThanOrEqual(w.count, w.deload ? 1 : 2, "week \(w.week + 1)") }
    }

    func testThreeDayPlansKeepAnEasyRunAndMaintenanceHoldsOne() {
        for w in qualityPerWeek(.raceConfig(level: .intermediate, distanceMeters: 10000), weeks: 12) {
            XCTAssertLessThanOrEqual(w.count, w.deload ? 1 : 2, "week \(w.week + 1)")
        }
        for w in qualityPerWeek(.maintenanceIntermediate, weeks: 12) { XCTAssertLessThanOrEqual(w.count, 1, "week \(w.week + 1)") }
    }

    /// A recovery week's long run stops at 80% of the build week's before it (60 min at least),
    /// and the week runs at most 90% of that week's minutes unless no plain run is left to shorten.
    func testRecoveryWeeksDip() {
        for meters in [10000, 21097, 42195] {
            for level in [RunnerLevel.intermediate, .advanced, .competitive] {
                let config = PlanConfiguration.raceConfig(level: level, distanceMeters: meters)
                let (plan, deloads, taper) = generatePlanV3WithDeloads(config: config, totalWeeks: 18, allWorkouts: catalog)
                func minutes(_ week: Int) -> Int { plan[week]!.reduce(0) { $0 + $1.workout.minutes } }
                func longRun(_ week: Int) -> Int { plan[week]!.filter { $0.workout.subtype.isLongRun }.map { $0.workout.minutes }.max() ?? 0 }
                for week in deloads where plan[week - 1] != nil && !deloads.contains(week - 1) && !taper.contains(week - 1) {
                    let label = "\(level) \(meters) week \(week + 1)"
                    XCTAssertLessThanOrEqual(longRun(week), max(60, longRun(week - 1) * 4 / 5), label)
                    let nothingToShorten = plan[week]!.allSatisfy { !$0.workout.subtype.isPlainRun || $0.workout.minutes <= 30 }
                    XCTAssertTrue(minutes(week) <= minutes(week - 1) * 9 / 10 || nothingToShorten,
                                  "\(label): \(minutes(week)) vs \(minutes(week - 1))")
                }
            }
        }
    }

    func testIntensityChoicesPerPlan() {
        func choices(_ level: RunnerLevel, _ meters: Int) -> [PlanIntensity] {
            PlanConfiguration.raceConfig(level: level, distanceMeters: meters).intensities
        }
        XCTAssertEqual(choices(.advanced, 10000), [.gentler, .standard, .harder])
        XCTAssertEqual(choices(.intermediate, 42195), [.gentler, .standard], "uncapped already: nothing harder to offer")
        XCTAssertEqual(choices(.beginner, 10000), [])
        XCTAssertEqual(PlanConfiguration.maintenanceIntermediate.intensities, [])
    }

    func testIntensityMovesTheWeeklyQuality() {
        let standard = PlanConfiguration.raceConfig(level: .advanced, distanceMeters: 10000)
        func total(_ intensity: PlanIntensity) -> Int { qualityPerWeek(standard.with(intensity), weeks: 12).reduce(0) { $0 + $1.count } }
        for w in qualityPerWeek(standard.with(.gentler), weeks: 12) { XCTAssertLessThanOrEqual(w.count, 1, "week \(w.week + 1)") }
        XCTAssertLessThan(total(.gentler), total(.standard))
        XCTAssertGreaterThan(total(.harder), total(.standard))
        // A marathon plan has no harder setting: asking for it changes nothing.
        let marathon = PlanConfiguration.raceConfig(level: .advanced, distanceMeters: 42195)
        XCTAssertNil(marathon.with(.harder).maxQualitySessions)
        XCTAssertEqual(marathon.with(.gentler).maxQualitySessions, 1)
    }

    func testHalfAndUpKeepTheGeneratorsCount() {
        XCTAssertNil(PlanConfiguration.raceConfig(level: .advanced, distanceMeters: 21097).qualityCap)
        XCTAssertNil(PlanConfiguration.raceConfig(level: .beginner, distanceMeters: 10000).qualityCap)
    }
}
