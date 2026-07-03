//
//  PaceRenderInvariantTests.swift
//  TrainingPlanKitTests
//
//  Regression suite for the 2026-07-02 pace-render findings. These test the
//  APP-SHAPED call (VDOT anchors: current → projected end), not just the
//  plan_debug matrix path — the original bugs shipped precisely because the
//  two paths differed and only the matrix path was validated.
//
//  1. Rehearsal WU/CD must render meaningfully slower than the MP block
//     (they collapsed to one pace for low-VDOT runners).
//  2. Z5 intervals must never render slower than current 5K pace, and must
//     reach the VO2 target by ~60% of the plan (they lingered near-5K to race
//     week).
//  3. MP must track the moving race anchor and land on the PROJECTED race
//     pace by race week (it sat pinned at current pace for the whole plan).
//

import XCTest
@testable import TrainingPlanKit

final class PaceRenderInvariantTests: XCTestCase {

    private let calendar = Calendar.current

    // MARK: - Builders

    private func rehearsalWorkout(id: Int64) -> Workout {
        let ivs = [
            WorkoutInterval(id: 0, type: .warmup, duration: 900, distance: 0,
                            targetType: .heartRate, target: .heartRateZone(zone: 2)),
            WorkoutInterval(id: 1, type: .work, duration: 3600, distance: 0,
                            targetType: .heartRate, target: .heartRateZone(zone: 3)),
            WorkoutInterval(id: 2, type: .cooldown, duration: 900, distance: 0,
                            targetType: .heartRate, target: .heartRateZone(zone: 2)),
        ]
        return Workout(id: id, title: "Race Rehearsal (60min @ MP)", type: .longRun,
                       subtype: .raceRehearsalM, trainingType: .timeBased,
                       targetType: .heartRate, duration: 5400, distance: 0,
                       key: "rr\(id)", trainingLoad: 9000, intervals: ivs,
                       workRestRatio: 1, workDuration: 5400, restDuration: 0,
                       workDistance: 0, restDistance: 0)
    }

    private func intervalWorkout(id: Int64) -> Workout {
        var ivs: [WorkoutInterval] = [
            WorkoutInterval(id: 0, type: .warmup, duration: 600, distance: 0,
                            targetType: .heartRate, target: .heartRateZone(zone: 2)),
        ]
        for i in 0..<5 {
            ivs.append(WorkoutInterval(id: Int64(i * 2 + 1), type: .work, duration: 240,
                                       distance: 0, targetType: .heartRate,
                                       target: .heartRateZone(zone: 5)))
            ivs.append(WorkoutInterval(id: Int64(i * 2 + 2), type: .rest, duration: 90,
                                       distance: 0, targetType: .heartRate,
                                       target: .heartRateZone(zone: 1)))
        }
        return Workout(id: id, title: "Intervals (5 segments)", type: .intervalRun,
                       subtype: .intervals, trainingType: .timeBased,
                       targetType: .heartRate, duration: 2400, distance: 0,
                       key: "iv\(id)", trainingLoad: 6000, intervals: ivs,
                       workRestRatio: 1, workDuration: 1200, restDuration: 450,
                       workDistance: 0, restDistance: 0)
    }

    private struct Rendered {
        let date: Date
        let wuPace: Double?
        let workPace: Double
        let cdPace: Double?
        let progression: Double  // 0..1 position in plan
    }

    /// Render one workout per week across an 18-week plan with app-shaped anchors.
    private func render(workout: (Int64) -> Workout,
                        current: VDOT, weeks: Int = 18,
                        anchored: Bool) -> [Rendered] {
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .weekOfYear, value: weeks, to: start)!
        let projected = current.projected(afterWeeks: weeks)

        var events: [WorkoutEvent] = []
        for w in 0..<weeks {
            let date = calendar.date(byAdding: .day, value: w * 7 + 3, to: start)!
            var e = WorkoutEvent(workout: workout(Int64(w)), planId: UUID(), date: date)
            e.planWeekIndex = w
            events.append(e)
        }

        let out = PaceZoneConverter.applyPaceProgression(
            to: events,
            racePace: current.marathonPaceSecondsPerKm,
            conversationalPace: current.easyPaceSecondsPerKm,
            speedPace: current.fiveKPaceSecondsPerKm,
            config: .beginner,
            startDate: start,
            endDate: end,
            racePaceEnd: anchored ? projected.marathonPaceSecondsPerKm : nil,
            conversationalPaceEnd: anchored ? projected.easyPaceSecondsPerKm : nil,
            speedPaceEnd: anchored ? projected.fiveKPaceSecondsPerKm : nil,
            raceDistanceMeters: 42195,
            isBeginner: true
        )

        let total = end.timeIntervalSince(start)
        return out.map { e in
            func pace(_ iv: WorkoutInterval) -> Double? {
                if case .paceTarget(let base, let rel) = iv.target {
                    return Double(base) * rel
                }
                return nil
            }
            let wu = e.workout.intervals.first { $0.type == .warmup }.flatMap(pace)
            let cd = e.workout.intervals.first { $0.type == .cooldown }.flatMap(pace)
            let work = e.workout.intervals.first { $0.type == .work && pace($0) != nil }
                .flatMap(pace) ?? 0
            return Rendered(date: e.date, wuPace: wu, workPace: work, cdPace: cd,
                            progression: e.date.timeIntervalSince(start) / total)
        }
    }

    // MARK: - 1. Rehearsal WU/CD ≠ MP

    func testRehearsalWarmupAndCooldownStaySlowerThanMP_lowVDOT() {
        // VDOT 32 ≈ the slow-runner case where WU/MP/CD collapsed to one pace.
        let rendered = render(workout: rehearsalWorkout, current: VDOT(value: 32), anchored: true)
        for r in rendered {
            guard let wu = r.wuPace, let cd = r.cdPace else {
                return XCTFail("rehearsal lost its WU/CD pace targets")
            }
            XCTAssertGreaterThanOrEqual(wu - r.workPace, 15,
                "W\(Int(r.progression * 18) + 1): warmup (\(wu)s/km) must be ≥15s/km slower than MP (\(r.workPace)s/km)")
            XCTAssertGreaterThanOrEqual(cd - r.workPace, 15,
                "W\(Int(r.progression * 18) + 1): cooldown must be ≥15s/km slower than MP")
        }
    }

    func testLegacyModeKeepsWarmupSeparatedFromMP() {
        // Old plans rendered without end anchors must still never collapse:
        // the 1.03 easy floor guarantees ≥3% separation from race pace.
        let rendered = render(workout: rehearsalWorkout, current: VDOT(value: 32), anchored: false)
        for r in rendered {
            guard let wu = r.wuPace else { return XCTFail("no WU pace") }
            XCTAssertGreaterThanOrEqual(wu - r.workPace, 8,
                "legacy: warmup must stay ≥8s/km slower than MP even late-plan")
        }
    }

    // MARK: - 2. Intervals never slower than 5K, on-target by 60%

    func testIntervalsNeverSlowerThan5KAndReachTargetBySixtyPercent() {
        let current = VDOT(value: 45)
        let projected = current.projected(afterWeeks: 18)
        let rendered = render(workout: intervalWorkout, current: current, anchored: true)
        for r in rendered {
            let speedNow = Double(current.fiveKPaceSecondsPerKm)
                + (Double(projected.fiveKPaceSecondsPerKm) - Double(current.fiveKPaceSecondsPerKm)) * r.progression
            XCTAssertLessThanOrEqual(r.workPace, speedNow + 2,
                "W\(Int(r.progression * 18) + 1): Z5 work (\(r.workPace)) must not be slower than current 5K pace (\(speedNow))")
            if r.progression >= 0.6 {
                XCTAssertLessThanOrEqual(r.workPace, speedNow * 0.97,
                    "from 60% of the plan, Z5 must be at true VO2 pace (≤0.97×5K), got \(r.workPace) vs 5K \(speedNow)")
            }
        }
    }

    // MARK: - 3. MP is the PLANNED race pace, flat — dose progresses, pace doesn't

    func testMarathonPaceHoldsPlannedRacePaceEveryWeek() {
        // Daniels/Pfitz: race-pace work is practiced AT the planned race pace from
        // the first MP session; the progression is the dose (60→70→90min rungs),
        // never a slower rehearsal pace. The 7:30-vs-7:10 case: every MP block
        // renders at the projected race-day pace (~7:10), not current fitness.
        let current = VDOT(value: 32)
        let weeks = 18
        let projected = current.projected(afterWeeks: weeks)
        let mpStart = Double(current.marathonPaceSecondsPerKm)
        let mpEnd = Double(projected.marathonPaceSecondsPerKm)
        XCTAssertLessThan(mpEnd, mpStart - 10, "projection must move MP meaningfully for this test to bite")

        let rendered = render(workout: rehearsalWorkout, current: current, weeks: weeks, anchored: true)
        for r in rendered {
            XCTAssertEqual(r.workPace, mpEnd, accuracy: 2,
                "W\(Int(r.progression * Double(weeks)) + 1): MP block must be the PLANNED race pace (\(mpEnd)), got \(r.workPace)")
        }
        // Legacy (no end anchors): planned == current, so MP is flat at current race pace.
        let legacy = render(workout: rehearsalWorkout, current: current, weeks: weeks, anchored: false)
        for r in legacy {
            XCTAssertEqual(r.workPace, mpStart, accuracy: 2,
                "legacy: MP must be flat at the (only known) race pace")
        }
    }
}
