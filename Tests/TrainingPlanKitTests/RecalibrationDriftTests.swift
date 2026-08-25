import XCTest
@testable import TrainingPlanKit

/// Recalibration REGENERATES the plan with today's pace model. Any change to
/// that model since the plan was created therefore shows up in the review diff
/// as if it were a fitness change — and can point the WRONG WAY.
///
/// Q, 2026-08-23: "ease your paces" review showed a long run 5:20 → 5:15.
/// Cause: the easy-vs-long gap widened 3% → 5% (b91ec64) after that plan was
/// generated. Stored long = easy × 0.97; regenerated long = easy × 0.95. That
/// 2% speed-up swamped the ~0.6% easing, so an "easing" made long runs faster.
///
/// The rail under test: an easing recalibration must never render ANY workout
/// faster than it already is (and a fitness-gain recalibration must never make
/// one slower). This holds regardless of what the pace model does between
/// plan creation and recalibration.
final class RecalibrationDriftTests: XCTestCase {

    private let cal = Calendar.current
    private let start = Calendar.current.startOfDay(for: Date())
    private var race: Date { cal.date(byAdding: .weekOfYear, value: 18, to: start)! }
    private let perWeek = 0.25
    private let ceiling = 2.5

    /// Long run + easy run each week — the two families whose ratio changed.
    private func fakeGenerate(planId: UUID, start: Date, end: Date) -> [WorkoutEvent] {
        var events: [WorkoutEvent] = []
        for w in 0..<18 {
            let long = Workout(id: Int64(1000 + w), title: "Long Run", type: .longRun,
                               subtype: .steadyLong, trainingType: .timeBased,
                               targetType: .heartRate, duration: 5400, distance: 0,
                               key: "lr\(w)", trainingLoad: 9000,
                               intervals: [WorkoutInterval(id: 0, type: .work, duration: 5400,
                                                           distance: 0, targetType: .heartRate,
                                                           target: .heartRateZone(zone: 2))],
                               workRestRatio: 1, workDuration: 5400, restDuration: 0,
                               workDistance: 0, restDistance: 0)
            var e1 = WorkoutEvent(workout: long, planId: planId,
                                  date: cal.date(byAdding: .day, value: w * 7 + 5, to: start)!)
            e1.planWeekIndex = w
            events.append(e1)

            let easy = Workout(id: Int64(2000 + w), title: "Easy Run", type: .easyRun,
                               subtype: .easy, trainingType: .timeBased,
                               targetType: .heartRate, duration: 2400, distance: 0,
                               key: "ez\(w)", trainingLoad: 2000,
                               intervals: [WorkoutInterval(id: 0, type: .work, duration: 2400,
                                                           distance: 0, targetType: .heartRate,
                                                           target: .heartRateZone(zone: 2))],
                               workRestRatio: 1, workDuration: 2400, restDuration: 0,
                               workDistance: 0, restDistance: 0)
            var e2 = WorkoutEvent(workout: easy, planId: planId,
                                  date: cal.date(byAdding: .day, value: w * 7 + 1, to: start)!)
            e2.planWeekIndex = w
            events.append(e2)

            // Z3 marathon-pace session: renders at relative 1.0, which is how
            // storedPlannedRacePace finds the plan's planned race pace.
            let mp = Workout(id: Int64(3000 + w), title: "Marathon Pace", type: .thresholdRun,
                             subtype: .marathonPace, trainingType: .timeBased,
                             targetType: .heartRate, duration: 3600, distance: 0,
                             key: "mp\(w)", trainingLoad: 6000,
                             intervals: [WorkoutInterval(id: 0, type: .work, duration: 3600,
                                                         distance: 0, targetType: .heartRate,
                                                         target: .heartRateZone(zone: 3))],
                             workRestRatio: 1, workDuration: 3600, restDuration: 0,
                             workDistance: 0, restDistance: 0)
            var e3 = WorkoutEvent(workout: mp, planId: planId,
                                  date: cal.date(byAdding: .day, value: w * 7 + 3, to: start)!)
            e3.planWeekIndex = w
            events.append(e3)
        }
        return events
    }

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

    /// Rewrites long-family work paces by `factor` — simulates a plan stored by
    /// a kit whose easy-vs-long multiplier differed from today's.
    private func rescaleLongFamily(_ plan: Plan, factor: Double) -> Plan {
        var p = plan
        p.events = plan.events.map { e in
            guard e.workout.subtype == .steadyLong || e.workout.subtype == .long
                    || e.workout.subtype == .mediumLong else { return e }
            let ivs = e.workout.intervals.map { iv -> WorkoutInterval in
                guard iv.type == .work,
                      case .paceTarget(let b, let r) = iv.target else { return iv }
                return WorkoutInterval(id: iv.id, type: iv.type, duration: iv.duration,
                                       distance: iv.distance, targetType: iv.targetType,
                                       target: .paceTarget(basePace: b, relative: r * factor))
            }
            let w = e.workout
            var ev = e
            ev.workout = Workout(id: w.id, title: w.title, type: w.type, subtype: w.subtype,
                                 trainingType: w.trainingType, targetType: w.targetType,
                                 duration: w.duration, distance: w.distance, key: w.key,
                                 trainingLoad: w.trainingLoad, intervals: ivs,
                                 workRestRatio: w.workRestRatio, workDuration: w.workDuration,
                                 restDuration: w.restDuration, workDistance: w.workDistance,
                                 restDistance: w.restDistance)
            return ev
        }
        return p
    }

    private func workPace(_ e: WorkoutEvent) -> Int? {
        for iv in e.workout.intervals where iv.type == .work {
            if case .paceTarget(let b, let rel) = iv.target { return Int(Double(b) * rel) }
        }
        return nil
    }

    /// Q's exact scenario: an older-model plan (long = easy × 0.97) eased today
    /// (long = easy × 0.95). Nothing may come back faster.
    func testModelDriftCannotSpeedUpAnEasing() {
        let completedWeeks = 9
        let fresh = makePlan(vdot: VDOT(value: 46), completedWeeks: completedWeeks)
        // 0.97/0.95 — what the SAME long run looked like before b91ec64.
        let stored = rescaleLongFamily(fresh, factor: 0.97 / 0.95)
        let asOf = cal.date(byAdding: .weekOfYear, value: completedWeeks, to: start)!

        let planned = PlanRecalculator.storedPlannedRacePace(stored)!
        let plannedVDOT = VDOT.fromRacePace(secondsPerKm: planned, distanceMeters: 42195)!
        var input = PlanRecalculator.Input(
            plan: stored, currentVDOT: VDOT(value: plannedVDOT.value - 0.6),
            asOf: asOf, perWeek: perWeek, adaptationCeiling: ceiling,
            config: .intermediate,
            regenerate: { id, s, e in self.fakeGenerate(planId: id, start: s, end: e) })
        input.currentVDOTDerivedFromPlannedPace = true
        let r = PlanRecalculator.recalculate(input)

        let oldByKey = Dictionary(uniqueKeysWithValues:
            stored.events.map { ("\($0.planWeekIndex)|\($0.workout.id)", $0) })
        var checkedLong = 0
        for e in r.events.filter({ !$0.isCompleted && $0.date >= asOf }) {
            guard let o = oldByKey["\(e.planWeekIndex)|\(e.workout.id)"],
                  let op = workPace(o), let np = workPace(e) else { continue }
            if e.workout.subtype == .steadyLong { checkedLong += 1 }
            XCTAssertGreaterThanOrEqual(np, op - 1,
                "\(e.workout.key): easing rendered FASTER (\(op) → \(np) s/km) — "
                + "pace-model drift leaked into the recalibration diff")
        }
        XCTAssertGreaterThan(checkedLong, 3, "compared too few long runs")
    }

    /// Mirror: a fitness GAIN must not make anything slower, even if the model
    /// drifted the other way.
    func testModelDriftCannotSlowDownAnImprovement() {
        let completedWeeks = 9
        let fresh = makePlan(vdot: VDOT(value: 46), completedWeeks: completedWeeks)
        let stored = rescaleLongFamily(fresh, factor: 0.93 / 0.95)   // drift the other way
        let asOf = cal.date(byAdding: .weekOfYear, value: completedWeeks, to: start)!

        let planned = PlanRecalculator.storedPlannedRacePace(stored)!
        let plannedVDOT = VDOT.fromRacePace(secondsPerKm: planned, distanceMeters: 42195)!
        var input = PlanRecalculator.Input(
            plan: stored, currentVDOT: VDOT(value: plannedVDOT.value + 0.8),
            asOf: asOf, perWeek: perWeek, adaptationCeiling: ceiling,
            config: .intermediate,
            regenerate: { id, s, e in self.fakeGenerate(planId: id, start: s, end: e) })
        input.currentVDOTDerivedFromPlannedPace = true
        let r = PlanRecalculator.recalculate(input)

        let oldByKey = Dictionary(uniqueKeysWithValues:
            stored.events.map { ("\($0.planWeekIndex)|\($0.workout.id)", $0) })
        for e in r.events.filter({ !$0.isCompleted && $0.date >= asOf }) {
            guard let o = oldByKey["\(e.planWeekIndex)|\(e.workout.id)"],
                  let op = workPace(o), let np = workPace(e) else { continue }
            XCTAssertLessThanOrEqual(np, op + 1,
                "\(e.workout.key): improvement rendered SLOWER (\(op) → \(np) s/km)")
        }
    }

    // MARK: - Time-trial door (the OTHER branch: measured today-fitness,
    // projected forward exponentially — `currentVDOTDerivedFromPlannedPace`
    // is false here, so none of the missed-training tests exercise it.)

    /// Runs the TT door: `currentVDOT` is TODAY's measured fitness.
    private func runTimeTrial(vdotToday: Double, completedWeeks: Int,
                              stored: Plan) -> (PlanRecalculator.Result, Date) {
        let asOf = cal.date(byAdding: .weekOfYear, value: completedWeeks, to: start)!
        let input = PlanRecalculator.Input(
            plan: stored, currentVDOT: VDOT(value: vdotToday), asOf: asOf,
            perWeek: perWeek, adaptationCeiling: ceiling, config: .intermediate,
            regenerate: { id, s, e in self.fakeGenerate(planId: id, start: s, end: e) })
        // NOT derived from planned pace — a time trial measures today directly.
        return (PlanRecalculator.recalculate(input), asOf)
    }

    private func assertRows(_ r: PlanRecalculator.Result, vs stored: Plan, asOf: Date,
                            noSlower: Bool = false, noFaster: Bool = false,
                            minRows: Int = 5, _ label: String) {
        let oldByKey = Dictionary(uniqueKeysWithValues:
            stored.events.map { ("\($0.planWeekIndex)|\($0.workout.id)", $0) })
        var checked = 0
        for e in r.events.filter({ !$0.isCompleted && $0.date >= asOf }) {
            guard let o = oldByKey["\(e.planWeekIndex)|\(e.workout.id)"],
                  let op = workPace(o), let np = workPace(e) else { continue }
            checked += 1
            if noSlower {
                XCTAssertLessThanOrEqual(np, op + 1,
                    "\(label) \(e.workout.key): rendered SLOWER (\(op) → \(np) s/km)")
            }
            if noFaster {
                XCTAssertGreaterThanOrEqual(np, op - 1,
                    "\(label) \(e.workout.key): rendered FASTER (\(op) → \(np) s/km)")
            }
        }
        XCTAssertGreaterThan(checked, minRows, "\(label): compared too few rows")
    }

    /// A time trial showing real improvement: race pace gets FASTER and no
    /// remaining workout gets slower.
    func testTimeTrialGainSpeedsUpThePlan() {
        let stored = makePlan(vdot: VDOT(value: 46), completedWeeks: 9)
        let planned = PlanRecalculator.storedPlannedRacePace(stored)!
        let (r, asOf) = runTimeTrial(vdotToday: 48.6, completedWeeks: 9, stored: stored)
        XCTAssertLessThan(r.newPlannedRacePace, planned,
                          "a fitter time trial must speed the race pace up")
        assertRows(r, vs: stored, asOf: asOf, noSlower: true, "TT gain")
    }

    /// A time trial showing the runner is BEHIND plan eases everything, through
    /// the very same door.
    func testTimeTrialDeclineEasesThePlan() {
        let stored = makePlan(vdot: VDOT(value: 46), completedWeeks: 9)
        let planned = PlanRecalculator.storedPlannedRacePace(stored)!
        let (r, asOf) = runTimeTrial(vdotToday: 45.0, completedWeeks: 9, stored: stored)
        XCTAssertGreaterThan(r.newPlannedRacePace, planned,
                             "a slower time trial must ease the race pace")
        assertRows(r, vs: stored, asOf: asOf, noFaster: true, "TT decline")
    }

    /// The mirror of Q's bug on the TT door: a plan stored by an older pace
    /// model whose long runs were FASTER than today's renderer produces. An
    /// improvement must still never render a row slower.
    ///
    /// The gain is deliberately SMALL (47.5 vs ~47.25 expected at this point,
    /// ~0.8% on pace) — smaller than the ~2.1% model drift. A large gain
    /// swamps the drift and the test passes even with the rail removed, i.e.
    /// proves nothing; verified by disabling the rail and watching this fail.
    func testTimeTrialGainUnderModelDriftNeverSlowsARow() {
        let fresh = makePlan(vdot: VDOT(value: 46), completedWeeks: 9)
        let stored = rescaleLongFamily(fresh, factor: 0.93 / 0.95)
        let planned = PlanRecalculator.storedPlannedRacePace(stored)!
        let (r, asOf) = runTimeTrial(vdotToday: 47.5, completedWeeks: 9, stored: stored)
        XCTAssertLessThan(r.newPlannedRacePace, planned, "should still be an improvement")
        assertRows(r, vs: stored, asOf: asOf, noSlower: true, "TT gain + drift")
    }
}
