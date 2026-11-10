import XCTest
@testable import TrainingPlanKit

/// Weeks hold at most the plan's quality cap; recovery weeks one session.
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

    func testThreeDayAndMaintenancePlansHoldOne() {
        for config in [PlanConfiguration.raceConfig(level: .intermediate, distanceMeters: 10000), .maintenanceIntermediate] {
            for w in qualityPerWeek(config, weeks: 12) { XCTAssertLessThanOrEqual(w.count, 1, "week \(w.week + 1)") }
        }
    }

    func testHalfAndUpKeepTheGeneratorsCount() {
        XCTAssertNil(PlanConfiguration.raceConfig(level: .advanced, distanceMeters: 21097).qualityCap)
        XCTAssertNil(PlanConfiguration.raceConfig(level: .beginner, distanceMeters: 10000).qualityCap)
    }
}
