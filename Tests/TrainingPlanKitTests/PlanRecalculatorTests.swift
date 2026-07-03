import XCTest
@testable import TrainingPlanKit

final class PlanRecalculatorTests: XCTestCase {

    private let cal = Calendar.current
    private let start = Calendar.current.startOfDay(for: Date())
    private var race: Date { cal.date(byAdding: .weekOfYear, value: 18, to: start)! }

    // Deterministic fake generator: one rehearsal-shaped long run per week
    // (Z2 WU / Z3 MP / Z2 CD) + one easy run — enough surface to verify
    // anchoring, splicing and identity preservation without a catalog.
    private func fakeGenerate(planId: UUID, start: Date, end: Date) -> [WorkoutEvent] {
        var events: [WorkoutEvent] = []
        for w in 0..<18 {
            let d = cal.date(byAdding: .day, value: w * 7 + 3, to: start)!
            let ivs = [
                WorkoutInterval(id: 0, type: .warmup, duration: 900, distance: 0,
                                targetType: .heartRate, target: .heartRateZone(zone: 2)),
                WorkoutInterval(id: 1, type: .work, duration: 3600, distance: 0,
                                targetType: .heartRate, target: .heartRateZone(zone: 3)),
                WorkoutInterval(id: 2, type: .cooldown, duration: 900, distance: 0,
                                targetType: .heartRate, target: .heartRateZone(zone: 2)),
            ]
            let lr = Workout(id: Int64(1000 + w), title: "Race Rehearsal (60min @ MP)",
                             type: .longRun, subtype: .raceRehearsalM,
                             trainingType: .timeBased, targetType: .heartRate,
                             duration: 5400, distance: 0, key: "rr\(w)",
                             trainingLoad: 9000, intervals: ivs, workRestRatio: 1,
                             workDuration: 5400, restDuration: 0, workDistance: 0,
                             restDistance: 0)
            var e1 = WorkoutEvent(workout: lr, planId: planId, date: d)
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
        }
        return events
    }

    private func makePlan(currentVDOT: VDOT, completedWeeks: Int) -> Plan {
        let planId = UUID()
        let hr = fakeGenerate(planId: planId, start: start, end: race)
        let projected = currentVDOT.projected(afterWeeks: 18, perWeek: 0.25, adaptationCeiling: 6)
        var events = PaceZoneConverter.applyPaceProgression(
            to: hr,
            racePace: currentVDOT.marathonPaceSecondsPerKm,
            conversationalPace: currentVDOT.easyPaceSecondsPerKm,
            speedPace: currentVDOT.fiveKPaceSecondsPerKm,
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

    private func input(_ plan: Plan, vdot: VDOT, asOf: Date) -> PlanRecalculator.Input {
        PlanRecalculator.Input(plan: plan, currentVDOT: vdot, asOf: asOf,
                               perWeek: 0.25, adaptationCeiling: 6,
                               config: .intermediate,
                               regenerate: { id, s, e in self.fakeGenerate(planId: id, start: s, end: e) })
    }

    private func mpPace(_ e: WorkoutEvent) -> Int? {
        for iv in e.workout.intervals {
            if case .paceTarget(let b, let rel) = iv.target, abs(rel - 1.0) < 0.001 { return b }
        }
        return nil
    }

    // 1. Fitter checkpoint → future MP re-anchors to the NEW planned race pace;
    //    past + completed events stay byte-identical.
    func testFitterCheckpointReanchorsFutureOnly() {
        let plan = makePlan(currentVDOT: VDOT(value: 38), completedWeeks: 8)
        let asOf = cal.date(byAdding: .weekOfYear, value: 8, to: start)!
        let newVDOT = VDOT(value: 39.5)
        let r = PlanRecalculator.recalculate(input(plan, vdot: newVDOT, asOf: asOf))

        XCTAssertGreaterThan(r.replacedCount, 0)
        XCTAssertLessThan(r.newPlannedRacePace, r.oldPlannedRacePace ?? .max,
                          "fitter runner → faster planned race pace")
        for e in r.events where !e.isCompleted && e.date >= asOf {
            if let mp = mpPace(e) {
                XCTAssertEqual(mp, r.newPlannedRacePace, "future MP == new planned pace")
            }
        }
        let oldPast = plan.events.filter { $0.isCompleted }
        let newPast = r.events.filter { $0.isCompleted }
        XCTAssertEqual(oldPast.count, newPast.count)
        for (o, n) in zip(oldPast.sorted { $0.date < $1.date },
                          newPast.sorted { $0.date < $1.date }) {
            XCTAssertEqual(mpPace(o), mpPace(n), "completed events untouched")
        }
    }

    // 2. Same-fitness recalc ≈ no-op on the planned pace (idempotence).
    func testSameFitnessIsStable() {
        let vdot = VDOT(value: 38)
        let plan = makePlan(currentVDOT: vdot, completedWeeks: 6)
        let asOf = cal.date(byAdding: .weekOfYear, value: 6, to: start)!
        // At asOf the runner is ON the original trajectory: current fitness =
        // start VDOT lerped toward the original projection.
        let origProjected = vdot.projected(afterWeeks: 18, perWeek: 0.25, adaptationCeiling: 6)
        let onTrack = VDOT(value: vdot.value + (origProjected.value - vdot.value) * (6.0 / 18.0))
        let r = PlanRecalculator.recalculate(input(plan, vdot: onTrack, asOf: asOf))
        XCTAssertEqual(r.newPlannedRacePace, r.oldPlannedRacePace ?? -1,
                       accuracy: 6, "on-track checkpoint barely moves the plan")
    }

    // 3. Continuity: the first future week's EASY pace ≈ current fitness easy
    //    (the backward-extrapolated start anchor passes through `current` at asOf).
    func testEasyPaceContinuityAtSplice() {
        let plan = makePlan(currentVDOT: VDOT(value: 38), completedWeeks: 9)
        let asOf = cal.date(byAdding: .weekOfYear, value: 9, to: start)!
        let now = VDOT(value: 38.8)
        let r = PlanRecalculator.recalculate(input(plan, vdot: now, asOf: asOf))
        let firstEasy = r.events.first {
            $0.date >= asOf && $0.workout.subtype == .easy && !$0.isCompleted
        }
        guard case .paceTarget(let b, let rel)? = firstEasy?.workout.intervals.first?.target else {
            return XCTFail("no easy pace found")
        }
        XCTAssertEqual(Double(b) * rel, Double(now.easyPaceSecondsPerKm), accuracy: 12,
                       "easy pace at the splice ≈ current-fitness easy")
    }

    // 4. Safety rail: an absurd +10 VDOT jump is clamped to ±6% race pace.
    func testRailClampsAbsurdJump() {
        let plan = makePlan(currentVDOT: VDOT(value: 38), completedWeeks: 8)
        let asOf = cal.date(byAdding: .weekOfYear, value: 8, to: start)!
        let r = PlanRecalculator.recalculate(input(plan, vdot: VDOT(value: 48), asOf: asOf))
        XCTAssertTrue(r.clampedToRail)
        let old = Double(r.oldPlannedRacePace ?? 0)
        XCTAssertGreaterThanOrEqual(Double(r.newPlannedRacePace), old * 0.935,
                                    "shift bounded by the rail")
    }

    // 5. User-moved date survives recalculation (same week + workout identity).
    func testManualDateMoveSurvives() {
        var plan = makePlan(currentVDOT: VDOT(value: 38), completedWeeks: 5)
        let asOf = cal.date(byAdding: .weekOfYear, value: 5, to: start)!
        let idx = plan.events.firstIndex { $0.planWeekIndex == 10 && $0.workout.subtype == .easy }!
        let movedDate = cal.date(byAdding: .day, value: 2, to: plan.events[idx].date)!
        plan.events[idx].date = movedDate
        let movedId = plan.events[idx].id
        let r = PlanRecalculator.recalculate(input(plan, vdot: VDOT(value: 38.5), asOf: asOf))
        let after = r.events.first { $0.id == movedId }
        XCTAssertEqual(after?.date, movedDate, "manual move preserved through recalc")
    }

    // 6. Missed-training detector: 2-week gap → rebuild suggested, conservative
    //    detraining (no cliff), zero-gap → no suggestion.
    func testMissedTrainingDetector() {
        var plan = makePlan(currentVDOT: VDOT(value: 38), completedWeeks: 6)
        let today = cal.date(byAdding: .day, value: 6 * 7 + 14, to: start)!  // 2w after last completed
        let report = PlanRecalculator.missedTraining(plan: plan,
                                                     lastKnownVDOT: VDOT(value: 38),
                                                     today: today)
        XCTAssertTrue(report.suggestsRebuild)
        XCTAssertGreaterThanOrEqual(report.gapDays, 13)
        XCTAssertEqual(report.detrainedVDOT.value, 38.0 - min(4, (Double(report.gapDays - 10) / 7) * 0.35),
                       accuracy: 0.01)
        XCTAssertLessThan(38.0 - report.detrainedVDOT.value, 1.0, "2-week gap costs well under 1 VDOT")

        // fully on-track plan: everything up to today completed
        for i in plan.events.indices where plan.events[i].date <= today {
            plan.events[i].isCompleted = true
        }
        let clean = PlanRecalculator.missedTraining(plan: plan,
                                                    lastKnownVDOT: VDOT(value: 38),
                                                    today: today)
        XCTAssertFalse(clean.suggestsRebuild)
        XCTAssertEqual(clean.detrainedVDOT.value, 38.0, accuracy: 0.01)
    }
}

extension PlanRecalculatorTests {

    // 7. MISSED (incomplete, past-dated) workouts stay in the calendar exactly
    //    as they were — the record of what was skipped is part of the plan.
    func testMissedPastWorkoutsPreserved() {
        let plan = makePlan(currentVDOT: VDOT(value: 38), completedWeeks: 4) // W5-6 happened but NOT completed
        let asOf = cal.date(byAdding: .weekOfYear, value: 7, to: start)!
        let missedBefore = plan.events.filter { !$0.isCompleted && $0.date < asOf }
        XCTAssertFalse(missedBefore.isEmpty, "fixture must contain missed events")
        let r = PlanRecalculator.recalculate(input(plan, vdot: VDOT(value: 37.5), asOf: asOf))
        for old in missedBefore {
            let kept = r.events.first { $0.id == old.id }
            XCTAssertNotNil(kept, "missed event stays in the plan")
            XCTAssertEqual(kept?.date, old.date)
            XCTAssertEqual(kept?.isCompleted, false)
            XCTAssertEqual(kept.flatMap(self.mpPaceForTest), self.mpPaceForTest(old),
                           "missed event's workout untouched")
        }
    }

    // 8. Competitive plans are goal-locked: recalculate is a structured no-op.
    func testCompetitivePlanIsNoOp() {
        var plan = makePlan(currentVDOT: VDOT(value: 55), completedWeeks: 6)
        plan.difficultyLevel = .competitive
        let asOf = cal.date(byAdding: .weekOfYear, value: 6, to: start)!
        let r = PlanRecalculator.recalculate(input(plan, vdot: VDOT(value: 58), asOf: asOf))
        XCTAssertEqual(r.replacedCount, 0)
        XCTAssertEqual(r.events.count, plan.events.count)
    }

    // 9. asOf at/after race day: nothing to re-anchor, plan returned unchanged.
    func testPastRaceDayIsNoOp() {
        let plan = makePlan(currentVDOT: VDOT(value: 38), completedWeeks: 17)
        let r = PlanRecalculator.recalculate(
            input(plan, vdot: VDOT(value: 40), asOf: race))
        XCTAssertEqual(r.replacedCount, 0)
    }

    // 10. Week-1 recalc (nothing completed yet): every event re-anchors and the
    //     backward-extrapolation degenerates safely to the plain current anchor.
    func testFreshPlanFullReanchor() {
        let plan = makePlan(currentVDOT: VDOT(value: 38), completedWeeks: 0)
        let asOf = cal.date(byAdding: .day, value: 1, to: start)!
        let newVDOT = VDOT(value: 36.5)  // opener TT says slower than assumed
        let r = PlanRecalculator.recalculate(input(plan, vdot: newVDOT, asOf: asOf))
        XCTAssertGreaterThan(r.newPlannedRacePace, r.oldPlannedRacePace ?? 0,
                             "slower runner → slower (more honest) planned race pace")
        let future = r.events.filter { $0.date >= asOf }
        XCTAssertEqual(r.replacedCount, future.count, "whole plan re-anchored")
    }

    // 11. THE TT SCENARIO end-to-end — how a time trial actually moves the plan:
    //     W9 20:00 TT covers 4.30km → VDOT.from(4300m, 1200s) ≈ real fitness →
    //     recalculate → every remaining MP block lands on the NEW planned pace,
    //     faster than the old one but inside the ±6% rail.
    func testTimeTrialResultReanchorsPlan() {
        let plan = makePlan(currentVDOT: VDOT(value: 38), completedWeeks: 9)
        let asOf = cal.date(byAdding: .weekOfYear, value: 9, to: start)!
        guard let ttVDOT = VDOT.from(distanceMeters: 4300, timeSeconds: 1200) else {
            return XCTFail("TT VDOT derivation failed")
        }
        XCTAssertGreaterThan(ttVDOT.value, 38, "fixture: the TT shows MORE fitness than assumed")
        let r = PlanRecalculator.recalculate(input(plan, vdot: ttVDOT, asOf: asOf))
        let old = r.oldPlannedRacePace ?? 0
        XCTAssertLessThan(r.newPlannedRacePace, old, "TT gain → faster planned race pace")
        XCTAssertGreaterThanOrEqual(Double(r.newPlannedRacePace), Double(old) * 0.94,
                                    "…but never beyond the per-checkpoint rail")
        for e in r.events where e.date >= asOf {
            if let mp = mpPaceForTest(e) {
                XCTAssertEqual(mp, r.newPlannedRacePace)
            }
        }
    }

    private func mpPaceForTest(_ e: WorkoutEvent) -> Int? {
        for iv in e.workout.intervals {
            if case .paceTarget(let b, let rel) = iv.target, abs(rel - 1.0) < 0.001 { return b }
        }
        return nil
    }
}
