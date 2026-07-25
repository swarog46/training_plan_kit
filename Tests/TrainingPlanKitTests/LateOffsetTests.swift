import XCTest
@testable import TrainingPlanKit

/// Offset door pressed LATE in the plan (2 weeks out): every remaining
/// workout must shift by the offset — test 14 only covered the FIRST future
/// easy; Q's device report (2026-07-25) motivated full-tail coverage.
final class LateOffsetTests: XCTestCase {

    private let cal = Calendar.current
    private let start = Calendar.current.startOfDay(for: Date())
    private var race: Date { cal.date(byAdding: .weekOfYear, value: 18, to: start)! }

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
            let lr = Workout(id: Int64(1000 + w), title: "Race Rehearsal",
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

    private func workPace(_ e: WorkoutEvent) -> Int? {
        for iv in e.workout.intervals where iv.type == .work {
            if case .paceTarget(let b, let rel) = iv.target { return Int(Double(b) * rel) }
        }
        return nil
    }

    private func mmss(_ s: Int?) -> String {
        guard let s else { return "  -  " }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    func testLateOffsetTable() {
        let plan = makePlan(currentVDOT: VDOT(value: 38), completedWeeks: 16)
        let asOf = cal.date(byAdding: .weekOfYear, value: 16, to: start)!
        let oldPlanned = PlanRecalculator.storedPlannedRacePace(plan)!
        let off = 10
        let implied = VDOT.fromRacePace(secondsPerKm: oldPlanned + off, distanceMeters: 42195)!

        var input = PlanRecalculator.Input(
            plan: plan, currentVDOT: implied, asOf: asOf,
            perWeek: 0.25, adaptationCeiling: 6, config: .intermediate,
            regenerate: { id, s, e in self.fakeGenerate(planId: id, start: s, end: e) })
        input.plannedRacePaceOverride = oldPlanned + off
        input.currentVDOTDerivedFromPlannedPace = true
        let r = PlanRecalculator.recalculate(input)

        XCTAssertEqual(r.newPlannedRacePace, oldPlanned + off)
        let oldByKey = Dictionary(uniqueKeysWithValues:
            plan.events.map { ("\($0.planWeekIndex)|\($0.workout.id)", $0) })
        var checked = 0
        for e in r.events.filter({ !$0.isCompleted && $0.date >= asOf })
            .sorted(by: { $0.date < $1.date }) {
            guard let old = oldByKey["\(e.planWeekIndex)|\(e.workout.id)"],
                  let op = workPace(old), let np = workPace(e) else { continue }
            checked += 1
            XCTAssertTrue((off - 5...off + 5).contains(np - op),
                "w\(e.planWeekIndex) \(e.workout.subtype.rawValue): late-tail pace must shift ≈+\(off), got \(np - op) (\(mmss(op))→\(mmss(np)))")
        }
        XCTAssertGreaterThanOrEqual(checked, 3, "tail must contain comparable rows")
    }
}

extension LateOffsetTests {

    /// Real catalog + real generator, Q's exact shape: intermediate half,
    /// 19 weeks, door pressed 2 weeks before race, +10s.
    func testRealCatalogLateOffset() {
        let catalog = loadSampleCatalog()
        XCTAssertFalse(catalog.isEmpty)
        let start = cal.startOfDay(for: Date())
        let weeks = 19
        let raceDay = cal.date(byAdding: .weekOfYear, value: weeks, to: start)!
        let planConfig = PlanConfiguration.raceConfig(level: .intermediate,
                                                      distanceMeters: 21097)
        let planId = UUID()
        let hr = createMarathonPlanV3(startDate: start, raceDate: raceDay,
                                      from: catalog, planId: planId, config: planConfig)
        let vdot = VDOT(value: 43)
        let projected = vdot.projected(afterWeeks: weeks, perWeek: 0.25, adaptationCeiling: 6)
        var stored = PaceZoneConverter.applyPaceProgression(
            to: hr,
            racePace: vdot.halfMarathonPaceSecondsPerKm,
            conversationalPace: vdot.easyPaceSecondsPerKm,
            speedPace: vdot.fiveKPaceSecondsPerKm,
            config: .intermediate, startDate: start, endDate: raceDay,
            racePaceEnd: projected.halfMarathonPaceSecondsPerKm,
            conversationalPaceEnd: projected.easyPaceSecondsPerKm,
            speedPaceEnd: projected.fiveKPaceSecondsPerKm,
            raceDistanceMeters: 21097, isBeginner: false)
        let asOf = cal.date(byAdding: .day, value: 17 * 7 + 1, to: start)!
        for i in stored.indices where stored[i].date < asOf { stored[i].isCompleted = true }
        let plan = Plan(id: planId, name: "Q", startDate: start, endDate: raceDay,
                        events: stored, difficultyLevel: .intermediate, raceDistance: 21097)

        let oldPlanned = PlanRecalculator.storedPlannedRacePace(plan)!
        let off = 10
        let implied = VDOT.fromRacePace(secondsPerKm: oldPlanned + off, distanceMeters: 21097)!
        var input = PlanRecalculator.Input(
            plan: plan, currentVDOT: implied, asOf: asOf,
            perWeek: 0.25, adaptationCeiling: 6, config: .intermediate,
            regenerate: { id, s, e in
                createMarathonPlanV3(startDate: s, raceDate: e, from: catalog,
                                     planId: id, config: planConfig)
            })
        input.plannedRacePaceOverride = oldPlanned + off
        input.currentVDOTDerivedFromPlannedPace = true
        let r = PlanRecalculator.recalculate(input)

        XCTAssertEqual(r.newPlannedRacePace, oldPlanned + off)
        XCTAssertGreaterThan(r.replacedCount, 0)
        let oldByKey = Dictionary(plan.events.map { ("\($0.planWeekIndex)|\($0.workout.id)", $0) },
                                  uniquingKeysWith: { a, _ in a })
        var checked = 0
        for e in r.events.filter({ !$0.isCompleted && $0.date >= asOf })
            .sorted(by: { $0.date < $1.date }) {
            guard let old = oldByKey["\(e.planWeekIndex)|\(e.workout.id)"],
                  let op = workPace(old), let np = workPace(e) else { continue }
            checked += 1
            XCTAssertTrue((off - 5...off + 5).contains(np - op),
                "w\(e.planWeekIndex) \(e.workout.subtype.rawValue) [\(e.workout.title)]: must shift ≈+\(off), got \(np - op)")
        }
        XCTAssertGreaterThanOrEqual(checked, 3, "tail must contain comparable rows")
    }
}
