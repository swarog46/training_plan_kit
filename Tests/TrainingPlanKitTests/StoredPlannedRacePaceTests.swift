import XCTest
@testable import TrainingPlanKit

/// Q, 2026-11-01: a fitness check applied 5:59 → 6:20, yet the next popup and
/// Progress still read 5:59 — from a past missed row the splice never rewrites.
final class StoredPlannedRacePaceTests: XCTestCase {

    private let cal = Calendar.current
    private let today = Calendar.current.startOfDay(for: Date())

    private func row(_ dayOffset: Int, pace: Int, completed: Bool = false, planId: UUID) -> WorkoutEvent {
        let w = Workout(id: Int64(100 + dayOffset), title: "Race Pace", type: .thresholdRun,
                        subtype: .marathonPace, trainingType: .timeBased,
                        targetType: .speed, duration: 1800, distance: 0,
                        key: "rp\(dayOffset)", trainingLoad: 3000,
                        intervals: [WorkoutInterval(id: 0, type: .work, duration: 1800,
                                                    distance: 0, targetType: .speed,
                                                    target: .paceTarget(basePace: pace, relative: 1.0))],
                        workRestRatio: 1, workDuration: 1800, restDuration: 0,
                        workDistance: 0, restDistance: 0)
        var e = WorkoutEvent(workout: w, planId: planId,
                             date: cal.date(byAdding: .day, value: dayOffset, to: today)!)
        e.isCompleted = completed
        return e
    }

    private func plan(_ rows: (UUID) -> [WorkoutEvent]) -> Plan {
        let id = UUID()
        return Plan(id: id, name: "T", startDate: cal.date(byAdding: .day, value: -60, to: today)!,
                    endDate: cal.date(byAdding: .day, value: 60, to: today)!,
                    events: rows(id), isActive: true, raceDistance: 21097)
    }

    /// Past misses and today's kept row hold the old pace; the future holds the new one.
    func testReadsTheNewestGenerationNotAPastMiss() {
        let p = plan { id in [row(-10, pace: 359, planId: id), row(0, pace: 359, planId: id),
                              row(3, pace: 380, planId: id), row(10, pace: 380, planId: id)] }
        XCTAssertEqual(PlanRecalculator.storedPlannedRacePace(p), 380)
    }

    /// Taper tail with nothing at race pace ahead: the latest completed row, not a miss.
    func testTaperTailFallsBackToLatestCompleted() {
        let p = plan { id in [row(-20, pace: 350, completed: true, planId: id),
                              row(-5, pace: 359, completed: true, planId: id),
                              row(-2, pace: 340, planId: id)] }
        XCTAssertEqual(PlanRecalculator.storedPlannedRacePace(p), 359)
    }
}
