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

extension PlanRecalculatorTests {
    // 12. Pace→VDOT inversion round-trips (the missed-week door derives the
    //     plan's implied fitness from its stored planned pace).
    func testRacePaceVDOTInversionRoundTrips() {
        for v in [28.0, 38.0, 52.0] {
            let vdot = VDOT(value: v)
            let pace = vdot.marathonPaceSecondsPerKm
            let back = VDOT.fromRacePace(secondsPerKm: pace, distanceMeters: 42195)
            XCTAssertNotNil(back)
            XCTAssertEqual(back!.value, v, accuracy: 0.3, "round-trip within a third of a point")
        }
        XCTAssertNil(VDOT.fromRacePace(secondsPerKm: 60, distanceMeters: 42195),
                     "absurd pace → nil, not garbage")
    }
}

extension PlanRecalculatorTests {
    // 13. Pace-offset door: with the race-pace override, the WHOLE plan shifts
    //     — MP blocks move by ≈ the offset instead of being re-earned by the
    //     projection (the only-easy-runs-changed bug).
    func testRacePaceOverrideShiftsQualityToo() {
        let plan = makePlan(currentVDOT: VDOT(value: 38), completedWeeks: 6)
        let asOf = cal.date(byAdding: .weekOfYear, value: 6, to: start)!
        let oldPlanned = PlanRecalculator.storedPlannedRacePace(plan)!
        guard let implied = VDOT.fromRacePace(secondsPerKm: oldPlanned + 10,
                                              distanceMeters: 42195) else {
            return XCTFail("inversion failed")
        }
        var input = self.input(plan, vdot: implied, asOf: asOf)
        input.plannedRacePaceOverride = oldPlanned + 10
        input.currentVDOTDerivedFromPlannedPace = true   // as the offset door passes it
        let r = PlanRecalculator.recalculate(input)
        XCTAssertEqual(r.newPlannedRacePace, oldPlanned + 10, "override pins race-day pace")
        for e in r.events where !e.isCompleted && e.date >= asOf {
            if let mp = mpPaceForTest(e) {
                XCTAssertEqual(mp, oldPlanned + 10, "MP blocks shift by the offset")
            }
        }
    }

    // 14. Offset door, easy side: "easier" must make easy runs SLOWER by ≈ the
    //     offset (and "harder" faster). Regression for the wrong-direction bug:
    //     currentVDOT derived from the PLANNED (race-day) pace anchored easy
    //     paces at race-week fitness, so +easier rendered FASTER easy runs.
    func testOffsetDoorMovesEasyPacesTheRightWay() {
        let plan = makePlan(currentVDOT: VDOT(value: 38), completedWeeks: 6)
        let asOf = cal.date(byAdding: .weekOfYear, value: 6, to: start)!
        let oldPlanned = PlanRecalculator.storedPlannedRacePace(plan)!

        func easyPace(_ events: [WorkoutEvent], after: Date) -> (id: UUID, pace: Int)? {
            for e in events.sorted(by: { $0.date < $1.date })
            where !e.isCompleted && e.date >= after && e.workout.subtype == .easy {
                for iv in e.workout.intervals where iv.type == .work {
                    if case .paceTarget(let b, let rel) = iv.target {
                        return (e.id, Int(Double(b) * rel))
                    }
                }
            }
            return nil
        }
        guard let oldEasy = easyPace(plan.events, after: asOf) else {
            return XCTFail("fixture has no future easy run")
        }

        for off in [10, -10] {
            guard let implied = VDOT.fromRacePace(secondsPerKm: oldPlanned + off,
                                                  distanceMeters: 42195) else {
                return XCTFail("inversion failed")
            }
            var input = self.input(plan, vdot: implied, asOf: asOf)
            input.plannedRacePaceOverride = oldPlanned + off
            input.currentVDOTDerivedFromPlannedPace = true
            let r = PlanRecalculator.recalculate(input)
            guard let newEasy = easyPace(r.events, after: asOf) else {
                return XCTFail("recalced plan has no future easy run")
            }
            XCTAssertEqual(newEasy.id, oldEasy.id, "identity survives the splice")
            let shift = newEasy.pace - oldEasy.pace
            if off > 0 {
                XCTAssertTrue((off - 5...off + 5).contains(shift),
                              "easier +\(off) must slow easy by ≈\(off), got \(shift)")
            } else {
                XCTAssertTrue((off - 5...off + 5).contains(shift),
                              "harder \(off) must speed easy by ≈\(off), got \(shift)")
            }
        }
    }
}

// MARK: - #174 long-run growth cap

final class LongRunGrowthCapTests: XCTestCase {
    private let cal = Calendar.current
    private let start = Calendar.current.startOfDay(for: Date())

    /// HR-side long runs with a deliberate phase cliff (90 → 150min) and a
    /// deload: render must cap build-chain growth at +25%/+15min while the
    /// deload keeps its #171 cut and later weeks still reach their targets.
    func testBuildChainCliffIsCapped() {
        let planId = UUID()
        let end = cal.date(byAdding: .weekOfYear, value: 8, to: start)!
        let minutes: [Int] = [60, 70, 75, 90, 150, 160, 170, 175]   // W5 cliff +67%
        var events: [WorkoutEvent] = []
        for (w, m) in minutes.enumerated() {
            let workout = Workout(
                id: Int64(100 + w), title: "Long Run", type: .longRun,
                subtype: .steadyLong, trainingType: .timeBased,
                targetType: .heartRate, duration: Int64(m * 60), distance: 0,
                key: "lr\(w)", trainingLoad: Int64(m * 100),
                intervals: [WorkoutInterval(id: 0, type: .work, duration: Double(m * 60),
                                            distance: 0, targetType: .heartRate,
                                            target: .heartRateZone(zone: 2))],
                workRestRatio: 1, workDuration: Int64(m * 60), restDuration: 0,
                workDistance: 0, restDistance: 0)
            var e = WorkoutEvent(workout: workout, planId: planId,
                                 date: cal.date(byAdding: .day, value: w * 7 + 5, to: start)!)
            e.planWeekIndex = w
            if w == 2 { e.isDeloadWeek = true }
            events.append(e)
        }
        let rendered = PaceZoneConverter.applyPaceProgression(
            to: events, racePace: 330, conversationalPace: 420, speedPace: 290,
            config: .beginner, startDate: start, endDate: end,
            racePaceEnd: 320, conversationalPaceEnd: 410, speedPaceEnd: 280,
            raceDistanceMeters: 42195, isBeginner: true)

        var prevNonDeload: Double? = nil
        for e in rendered.sorted(by: { $0.planWeekIndex < $1.planWeekIndex }) {
            let d = Double(e.workout.duration)
            if e.isDeloadWeek { continue }
            if let prev = prevNonDeload {
                let cap = max(prev + 900, prev * 1.25) + 300   // +tick tolerance
                XCTAssertLessThanOrEqual(d, cap,
                    "W\(e.planWeekIndex) long run \(Int(d/60))min exceeds growth cap vs \(Int(prev/60))min")
            }
            prevNonDeload = d
        }
        // The cliff week specifically: was 150min HR-side, must land ≤ ~118min
        let w4 = rendered.first { $0.planWeekIndex == 4 }!
        XCTAssertLessThanOrEqual(w4.workout.duration, Int64(120 * 60),
            "cliff week must be capped (+25% of ~90min, ticked)")
        // And the final week must still climb (the cap spreads, not flattens)
        let w7 = rendered.first { $0.planWeekIndex == 7 }!
        XCTAssertGreaterThan(w7.workout.duration, w4.workout.duration)
    }
}

extension LongRunGrowthCapTests {

    private func makeEvents(_ minutes: [(Int, WorkoutSubtype, Bool)],
                            planId: UUID, start: Date) -> [WorkoutEvent] {
        let cal = Calendar.current
        return minutes.enumerated().map { (w, spec) in
            let (m, sub, deload) = spec
            let ivs: [WorkoutInterval]
            if sub == .raceRehearsalM {
                ivs = [
                    WorkoutInterval(id: 0, type: .warmup, duration: Double(m * 60) * 0.3,
                                    distance: 0, targetType: .heartRate, target: .heartRateZone(zone: 2)),
                    WorkoutInterval(id: 1, type: .work, duration: Double(m * 60) * 0.5,
                                    distance: 0, targetType: .heartRate, target: .heartRateZone(zone: 3)),
                    WorkoutInterval(id: 2, type: .cooldown, duration: Double(m * 60) * 0.2,
                                    distance: 0, targetType: .heartRate, target: .heartRateZone(zone: 2)),
                ]
            } else {
                ivs = [WorkoutInterval(id: 0, type: .work, duration: Double(m * 60),
                                       distance: 0, targetType: .heartRate,
                                       target: .heartRateZone(zone: 2))]
            }
            let workout = Workout(id: Int64(500 + w), title: sub == .raceRehearsalM ? "Race Rehearsal" : "Long Run",
                                  type: .longRun, subtype: sub, trainingType: .timeBased,
                                  targetType: .heartRate, duration: Int64(m * 60), distance: 0,
                                  key: "k\(w)", trainingLoad: Int64(m * 100), intervals: ivs,
                                  workRestRatio: 1, workDuration: Int64(m * 60), restDuration: 0,
                                  workDistance: 0, restDistance: 0)
            var e = WorkoutEvent(workout: workout, planId: planId,
                                 date: cal.date(byAdding: .day, value: w * 7 + 5, to: start)!)
            e.planWeekIndex = w
            e.isDeloadWeek = deload
            return e
        }
    }

    /// Rehearsals are growth-capped too: a floored 28km rehearsal arriving
    /// right out of a deload must not spike past +25% of the last build week
    /// (the 155→210 hole found 2026-07-04).
    func testRehearsalJoinsGrowthCap() {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .weekOfYear, value: 6, to: start)!
        let events = makeEvents([
            (140, .steadyLong, false),
            (155, .steadyLong, false),
            (135, .steadyLong, true),      // deload
            (210, .raceRehearsalM, false), // wants to spike
            (200, .steadyLong, false),
            (175, .steadyLong, false),
        ], planId: UUID(), start: start)
        let rendered = PaceZoneConverter.applyPaceProgression(
            to: events, racePace: 400, conversationalPace: 450, speedPace: 350,
            config: .beginner, startDate: start, endDate: end,
            racePaceEnd: 390, conversationalPaceEnd: 440, speedPaceEnd: 340,
            raceDistanceMeters: 42195, isBeginner: true)
        let reh = rendered.first { $0.workout.subtype == .raceRehearsalM }!
        let capSecs = Double(155 * 60) * 1.25 + 300      // vs last non-deload + tick
        XCTAssertLessThanOrEqual(Double(reh.workout.duration), capSecs,
            "rehearsal must obey the growth cap (\(reh.workout.duration / 60)min)")
    }

    /// Beginner 42K: never more than THREE runs ≥3h, regardless of how many
    /// the floor/generator produce — earliest extras scale under 3h.
    func testBeginnerThreeHourExposureCappedAtThree() {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .weekOfYear, value: 10, to: start)!
        let events = makeEvents([
            (120, .steadyLong, false),
            (150, .steadyLong, false),
            (185, .steadyLong, false),
            (150, .steadyLong, true),      // deload
            (185, .steadyLong, false),
            (190, .steadyLong, false),
            (155, .steadyLong, true),      // deload
            (195, .steadyLong, false),
            (200, .steadyLong, false),
            (185, .steadyLong, false),
        ], planId: UUID(), start: start)
        let rendered = PaceZoneConverter.applyPaceProgression(
            to: events, racePace: 400, conversationalPace: 450, speedPace: 350,
            config: .beginner, startDate: start, endDate: end,
            racePaceEnd: 390, conversationalPaceEnd: 440, speedPaceEnd: 340,
            raceDistanceMeters: 42195, isBeginner: true)
        let over3h = rendered.filter {
            !$0.isDeloadWeek && !$0.isTaperWeek && $0.workout.duration >= 180 * 60
        }
        XCTAssertLessThanOrEqual(over3h.count, 3,
            "≥3h exposure must cap at 3 (got \(over3h.count))")
        // The LAST peaks survive; the earliest oversized ones were reduced.
        let w2 = rendered.first { $0.planWeekIndex == 2 }!
        XCTAssertLessThan(w2.workout.duration, 180 * 60, "earliest 185 scales under 3h")
        let w8 = rendered.first { $0.planWeekIndex == 8 }!
        XCTAssertGreaterThanOrEqual(w8.workout.duration, 180 * 60, "late peak survives")
    }

    /// Length-aware floor ramp: at the same mid-plan progression point, a 30w
    /// plan's km floor is WEAKER than an 18w plan's — long plans build slower.
    func testFloorRampIsLengthAware() {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        func rendered(atWeeks total: Int) -> Int64 {
            let end = cal.date(byAdding: .weekOfYear, value: total, to: start)!
            // One 100min easy long at ~62% through the plan (short of both ramps'
            // full point, inside the floor window).
            let day = Int(Double(total) * 7.0 * 0.62)
            let w = Workout(id: 1, title: "Long Run", type: .longRun, subtype: .steadyLong,
                            trainingType: .timeBased, targetType: .heartRate,
                            duration: 6000, distance: 0, key: "lr", trainingLoad: 8000,
                            intervals: [WorkoutInterval(id: 0, type: .work, duration: 6000,
                                                        distance: 0, targetType: .heartRate,
                                                        target: .heartRateZone(zone: 2))],
                            workRestRatio: 1, workDuration: 6000, restDuration: 0,
                            workDistance: 0, restDistance: 0)
            var e = WorkoutEvent(workout: w, planId: UUID(),
                                 date: cal.date(byAdding: .day, value: day, to: start)!)
            e.planWeekIndex = Int(Double(total) * 0.62)
            let out = PaceZoneConverter.applyPaceProgression(
                to: [e], racePace: 400, conversationalPace: 450, speedPace: 350,
                config: .beginner, startDate: start, endDate: end,
                racePaceEnd: 390, conversationalPaceEnd: 440, speedPaceEnd: 340,
                raceDistanceMeters: 42195, isBeginner: true)
            return out[0].workout.duration
        }
        let d18 = rendered(atWeeks: 18)
        let d30 = rendered(atWeeks: 30)
        XCTAssertLessThan(d30, d18,
            "same relative point: 30w floor (\(d30/60)min) must be weaker than 18w (\(d18/60)min)")
    }
}
