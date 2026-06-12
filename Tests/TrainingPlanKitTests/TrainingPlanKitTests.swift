import XCTest
import TrainingPlanKit

final class TrainingPlanKitTests: XCTestCase {

    func testSampleCatalogDecodes() {
        let catalog = loadSampleCatalog()
        XCTAssertGreaterThan(catalog.count, 50, "bundled sample catalog should decode")
    }

    func testGeneratePlanFillsEveryWeek() {
        let catalog = loadSampleCatalog()
        let plan = generatePlan(config: .intermediate42Default, totalWeeks: 18, catalog: catalog)
        XCTAssertEqual(plan.keys.count, 18)
        for (week, sessions) in plan {
            XCTAssertFalse(sessions.isEmpty, "week \(week) has no sessions")
        }
    }

    func testGeneratePlanIsDeterministic() {
        let catalog = loadSampleCatalog()
        let a = generatePlan(config: .intermediate42Default, totalWeeks: 18, catalog: catalog)
        let b = generatePlan(config: .intermediate42Default, totalWeeks: 18, catalog: catalog)
        XCTAssertEqual(a.keys.sorted(), b.keys.sorted())
        for week in a.keys {
            XCTAssertEqual(a[week]?.map { $0.workout.title },
                           b[week]?.map { $0.workout.title },
                           "week \(week) differs between two runs of the same inputs")
        }
    }

    func testPhaseDurationsSumToTotal() {
        let cases: [(PlanConfiguration, Int)] = [
            (.intermediate42Default, 18),
            (.beginner5Default, 10),
            (.competitive42Default, 24),
        ]
        for (config, weeks) in cases {
            let d = calculatePhaseDurations(config: config, totalWeeks: weeks)
            let sum = (d["base"] ?? 0) + (d["speed"] ?? 0) + (d["peak"] ?? 0) + (d["taper"] ?? 0)
            XCTAssertEqual(sum, weeks, "phase weeks must sum to plan length")
        }
    }

    func testCompetitivePeakCappedAtEightWeeks() {
        let d = calculatePhaseDurations(config: .competitive42Default, totalWeeks: 36)
        XCTAssertLessThanOrEqual(d["peak"] ?? 0, 8, "competitive PEAK is capped; extras go to BASE")
    }
}
