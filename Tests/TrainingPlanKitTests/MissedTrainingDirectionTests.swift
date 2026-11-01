import XCTest
@testable import TrainingPlanKit

/// The missed-training door must EASE, never speed up — and must be an exact
/// no-op at zero detraining. Q's device (2026-08-18): "ease-your-paces shows
/// faster paces … looks random-ish." Root cause: the planned-pace back-out
/// used the plan's linear-capped growth schedule while the re-projection used
/// the exponential curve; wherever the ceiling bound, tail rows came back
/// FASTER. Both paths now ride the same linear schedule.
final class MissedTrainingDirectionTests: XCTestCase {

    private let cal = Calendar.current
    private let start = Calendar.current.startOfDay(for: Date())
    private var race: Date { cal.date(byAdding: .weekOfYear, value: 18, to: start)! }

    private func fakeGenerate(planId: UUID, start: Date, end: Date) -> [WorkoutEvent] {
        var events: [WorkoutEvent] = []
        for w in 0..<18 {
            let easy = Workout(id: Int64(2000 + w), title: "Easy Run", type: .easyRun,
                               subtype: .easy, trainingType: .timeBased,
                               targetType: .heartRate, duration: 2400, distance: 0,
                               key: "ez\(w)", trainingLoad: 2000,
                               intervals: [WorkoutInterval(id: 0, type: .work, duration: 2400,
                                                           distance: 0, targetType: .heartRate,
                                                           target: .heartRateZone(zone: 2))],
                               workRestRatio: 1, workDuration: 2400, restDuration: 0,
                               workDistance: 0, restDistance: 0)
            var e = WorkoutEvent(workout: easy, planId: planId,
                                 date: cal.date(byAdding: .day, value: w * 7 + 1, to: start)!)
            e.planWeekIndex = w
            events.append(e)

            let mp = Workout(id: Int64(3000 + w), title: "Marathon Pace", type: .thresholdRun,
                             subtype: .marathonPace, trainingType: .timeBased,
                             targetType: .heartRate, duration: 3600, distance: 0,
                             key: "mp\(w)", trainingLoad: 6000,
                             intervals: [WorkoutInterval(id: 0, type: .work, duration: 3600,
                                                         distance: 0, targetType: .heartRate,
                                                         target: .heartRateZone(zone: 3))],
                             workRestRatio: 1, workDuration: 3600, restDuration: 0,
                             workDistance: 0, restDistance: 0)
            var e2 = WorkoutEvent(workout: mp, planId: planId,
                                  date: cal.date(byAdding: .day, value: w * 7 + 4, to: start)!)
            e2.planWeekIndex = w
            events.append(e2)
        }
        return events
    }

    /// perWeek/ceiling chosen so the CEILING BINDS (perWeek×18 = 4.5 > 2.5) —
    /// the exact regime where the old code sped the tail up.
    private let perWeek = 0.25
    private let ceiling = 2.5

    private func makePlan(vdot: VDOT, completedWeeks: Int) -> Plan {
        let planId = UUID()
        let hr = fakeGenerate(planId: planId, start: start, end: race)
        let projected = vdot.projected(afterWeeks: 18, perWeek: perWeek,
                                       adaptationCeiling: ceiling)
        var events = PaceZoneConverter.applyPaceProgression(
            to: hr,
            racePace: vdot.marathonPaceSecondsPerKm,
            conversationalPace: vdot.easyPaceSecondsPerKm,
            speedPace: vdot.fiveKPaceSecondsPerKm,
            config: .intermediate, startDate: start, endDate: race,
            racePaceEnd: projected.marathonPaceSecondsPerKm,
            conversationalPaceEnd: projected.easyPaceSecondsPerKm,
            speedPaceEnd: projected.fiveKPaceSecondsPerKm,
            raceDistanceMeters: 42195, isBeginner: false)
        for i in events.indices where events[i].planWeekIndex < completedWeeks {
            events[i].isCompleted = true
        }
        return Plan(id: planId, name: "T", startDate: start, endDate: race,
                    events: events, difficultyLevel: .intermediate, raceDistance: 42195)
    }

    private func workPace(_ e: WorkoutEvent) -> Int? {
        for iv in e.workout.intervals where iv.type == .work {
            if case .paceTarget(let b, let rel) = iv.target { return Int(Double(b) * rel) }
        }
        return nil
    }

    private func run(deltaVDOT: Double, completedWeeks: Int)
        -> (old: Plan, new: PlanRecalculator.Result, asOf: Date) {
        let plan = makePlan(vdot: VDOT(value: 46), completedWeeks: completedWeeks)
        let asOf = cal.date(byAdding: .weekOfYear, value: completedWeeks, to: start)!
        let planned = PlanRecalculator.storedPlannedRacePace(plan)!
        let plannedVDOT = VDOT.fromRacePace(secondsPerKm: planned, distanceMeters: 42195)!
        var input = PlanRecalculator.Input(
            plan: plan, currentVDOT: VDOT(value: plannedVDOT.value - deltaVDOT),
            asOf: asOf, perWeek: perWeek, adaptationCeiling: ceiling,
            config: .intermediate,
            regenerate: { id, s, e in self.fakeGenerate(planId: id, start: s, end: e) })
        input.currentVDOTDerivedFromPlannedPace = true
        return (plan, PlanRecalculator.recalculate(input), asOf)
    }

    /// Zero detraining ⇒ the recalibration is an exact no-op on race pace.
    func testZeroLossIsNoOp() {
        let (old, new, _) = run(deltaVDOT: 0, completedWeeks: 9)
        let oldPlanned = PlanRecalculator.storedPlannedRacePace(old)!
        XCTAssertEqual(new.newPlannedRacePace, oldPlanned,
                       "no detraining must leave the planned race pace untouched")
    }

    /// A real detraining loss ⇒ EVERY remaining workout is same-or-slower.
    /// One faster row anywhere = the old curve mismatch is back.
    func testLossEasesEveryRow() {
        for completed in [5, 9, 13] {
            let (old, new, asOf) = run(deltaVDOT: 0.6, completedWeeks: completed)
            let oldPlanned = PlanRecalculator.storedPlannedRacePace(old)!
            XCTAssertGreaterThan(new.newPlannedRacePace, oldPlanned,
                                 "w\(completed): race pace must ease")
            let oldByKey = Dictionary(uniqueKeysWithValues:
                old.events.map { ("\($0.planWeekIndex)|\($0.workout.id)", $0) })
            var checked = 0
            for e in new.events.filter({ !$0.isCompleted && $0.date >= asOf }) {
                guard let o = oldByKey["\(e.planWeekIndex)|\(e.workout.id)"],
                      let op = workPace(o), let np = workPace(e) else { continue }
                checked += 1
                XCTAssertGreaterThanOrEqual(np, op - 1,
                    "w\(completed) row \(e.workout.key): eased plan rendered FASTER "
                    + "(\(op) → \(np) s/km)")
            }
            XCTAssertGreaterThan(checked, 5, "w\(completed): compared too few rows")
        }
    }
}
