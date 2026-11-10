//
//  FixedProtocol.swift
//  TrainingPlanKit
//
//  Beginner plans written out week by week instead of selected from the
//  catalog: Walk to Run, 5K to 10K, Return to Running. Their sessions are
//  built in code from two shapes, run/walk repeats and a continuous run, in
//  the same form as the catalog's Couch-to-5K templates.
//

import Foundation

/// One session of a fixed protocol.
public enum ProtocolSession: Equatable {
    /// `reps` runs of `run` seconds, a `walk` of seconds after each but the last.
    case runWalk(reps: Int, run: Int, walk: Int)
    /// A continuous run.
    case run(minutes: Int)

    static let walkBefore = 300.0, walkAfter = 300.0

    public var title: String {
        switch self {
        case .runWalk(let reps, let run, _): return "Run/Walk (\(reps) x \(run % 60 == 0 ? "\(run / 60)min" : "\(run)s"))"
        case .run(let minutes): return "Run \(minutes) min"
        }
    }

    /// Seconds running.
    var runSeconds: Double {
        switch self {
        case .runWalk(let reps, let run, _): return Double(reps * run)
        case .run(let minutes): return Double(minutes * 60)
        }
    }

    func workout(id: Int64, key: String) -> Workout {
        var parts = [Part.walk(.warmup, Self.walkBefore)]
        switch self {
        case .runWalk(let reps, let run, let walk):
            for rep in 0..<reps {
                parts.append(.run(Double(run)))
                if rep < reps - 1 { parts.append(.walk(.rest, Double(walk))) }
            }
        case .run(let minutes):
            parts.append(.run(Double(minutes * 60)))
        }
        parts.append(.walk(.cooldown, Self.walkAfter))

        let intervals = parts.enumerated().map { index, part in
            WorkoutInterval(id: Int64(index), type: part.type, duration: part.seconds, distance: 0,
                            targetType: part.targetType, target: part.target)
        }
        let total = parts.reduce(0) { $0 + $1.seconds }
        let walked = total - runSeconds
        let isContinuous = { if case .run = self { return true } else { return false } }()
        return Workout(id: id, title: title,
                       type: isContinuous ? .easyRun : .intervalRun, subtype: isContinuous ? .easy : .intervals,
                       trainingType: .timeBased, targetType: .heartRate,
                       duration: Int64(total), distance: 0, key: key,
                       // The catalog's Couch-to-5K load: easy running 2.2 a second, walking 0.8.
                       trainingLoad: Int64((runSeconds * 2.2 + walked * 0.8).rounded()),
                       intervals: intervals,
                       workRestRatio: walked > 0 ? runSeconds / walked : 1,
                       workDuration: Int64(runSeconds), restDuration: Int64(walked - Self.walkBefore - Self.walkAfter),
                       workDistance: 0, restDistance: 0)
    }
}

/// A stretch of a protocol session: easy running by heart rate, or walking with no target.
private struct Part {
    let type: IntervalType
    let seconds: Double
    let targetType: TargetType
    let target: TargetRange

    static func run(_ seconds: Double) -> Part {
        Part(type: .work, seconds: seconds, targetType: .heartRate, target: .heartRateZone(zone: 2))
    }

    static func walk(_ type: IntervalType, _ seconds: Double) -> Part {
        Part(type: type, seconds: seconds, targetType: .noTarget, target: .noRange(noValue: true))
    }
}

/// A plan as a fixed list of weeks, each a list of sessions in day order.
public struct FixedProtocol: Equatable {
    /// Stable prefix for its workouts' keys and ids.
    public let key: String
    let idBase: Int64
    public let weeks: [[ProtocolSession]]

    /// The sessions of a week (0-based) as workouts.
    func workouts(week: Int) -> [Workout] {
        weeks[week].enumerated().map { day, session in
            session.workout(id: idBase + Int64(week * 10 + day), key: "\(key)_w\(week + 1)d\(day + 1)")
        }
    }

    /// Brisk walking with short jogs, for a runner who can't yet start Couch to 5K: six weeks
    /// that end on its first session (8 x 1 min with 90 s walks).
    public static let walkToRun = FixedProtocol(key: "walk_to_run", idBase: 70_000, weeks: [
        week(.runWalk(reps: 6, run: 30, walk: 150)),
        week(.runWalk(reps: 8, run: 30, walk: 120)),
        week(.runWalk(reps: 10, run: 30, walk: 90)),
        week(.runWalk(reps: 6, run: 60, walk: 120)),
        week(.runWalk(reps: 8, run: 60, walk: 120)),
        week(.runWalk(reps: 8, run: 60, walk: 90)),
    ])

    /// From 30 minutes of running to a 10K in eight weeks: two steady runs and one longer run
    /// that grows by five minutes a week, a lighter week four, and the 10K itself to finish.
    public static let fiveToTenK = FixedProtocol(key: "five_to_ten_k", idBase: 71_000, weeks: [
        [.run(minutes: 30), .run(minutes: 30), .run(minutes: 35)],
        [.run(minutes: 30), .run(minutes: 32), .run(minutes: 40)],
        [.run(minutes: 32), .run(minutes: 35), .run(minutes: 45)],
        [.run(minutes: 30), .run(minutes: 30), .run(minutes: 40)],
        [.run(minutes: 35), .run(minutes: 35), .run(minutes: 50)],
        [.run(minutes: 35), .run(minutes: 38), .run(minutes: 55)],
        [.run(minutes: 35), .run(minutes: 40), .run(minutes: 60)],
        [.run(minutes: 30), .run(minutes: 25)],
    ])

    /// Back to steady running after time away (injury, illness, a long break): run/walk for
    /// a week, then continuous runs from 15 minutes back to 30. Weekly running climbs
    /// 43, 55, 68, 80 minutes: quick, because the runner is regaining, not building.
    public static let returnToRunning = FixedProtocol(key: "return_to_running", idBase: 72_000, weeks: [
        [.runWalk(reps: 5, run: 120, walk: 60), .runWalk(reps: 5, run: 180, walk: 60), .runWalk(reps: 6, run: 180, walk: 60)],
        [.run(minutes: 15), .runWalk(reps: 4, run: 300, walk: 60), .run(minutes: 20)],
        [.run(minutes: 20), .run(minutes: 22), .run(minutes: 26)],
        [.run(minutes: 25), .run(minutes: 25), .run(minutes: 30)],
    ])

    /// A week's sessions on the runner's days, Monday first, in the order written; the week's
    /// longest run takes the long-run day when the week has one.
    static func days(for sessions: [Workout], on trainingDays: [Int], longDay: Int) -> [(workout: Workout, dayOfWeek: Int)] {
        var days = trainingDays.sorted { ($0 + 6) % 7 < ($1 + 6) % 7 }.prefix(sessions.count).map { $0 }   // 0 = Sunday, last
        var ordered = sessions
        let durations = Set(sessions.map(\.duration))
        if durations.count > 1, let long = days.firstIndex(of: longDay),
           let longest = ordered.indices.max(by: { ordered[$0].duration < ordered[$1].duration }) {
            ordered.append(ordered.remove(at: longest))
            days.append(days.remove(at: long))
        }
        return zip(ordered, days).map { ($0, $1) }
    }

    /// A week that repeats one session on each of three days.
    private static func week(_ session: ProtocolSession) -> [ProtocolSession] { [session, session, session] }
}

/// Runs a FixedProtocol: a shorter plan starts deeper into it, a longer one repeats its last
/// full week (the same rule as Couch to 5K).
final class ProtocolPlanGenerator: PlanGeneratorV3 {
    override func buildWeek(week: Int) {
        guard let plan = config.fixedProtocol else { return }
        let offset = max(0, plan.weeks.count - actualWeeksToGenerate)
        let index = min(week + offset, plan.weeks.count - 1)
        workoutsByWeek[week] = plan.workouts(week: index).prefix(config.trainingDays.count).map { ("protocol", $0) }
    }
}

extension PlanConfiguration {
    public static var walkToRun: PlanConfiguration { fixed(.walkToRun, distance: 0) }
    public static var fiveToTenK: PlanConfiguration { fixed(.fiveToTenK, distance: 10000) }
    public static var returnToRunning: PlanConfiguration { fixed(.returnToRunning, distance: 0) }

    /// A protocol carries its own progression: one phase, three days, no selection. The volume
    /// values only feed shared math the protocol generator ignores (as for Couch to 5K).
    private static func fixed(_ plan: FixedProtocol, distance: Int64) -> PlanConfiguration {
        var config = PlanConfiguration(
            raceDate: Date(), runnerLevel: .beginner, distance: distance,
            basePhaseRatio: 1.0, speedPhaseRatio: 0, peakPhaseRatio: 0, taperPhaseRatio: 0,
            minBasePhaseWeeks: 1, minSpeedPhaseWeeks: 0, minPeakPhaseWeeks: 0, minTaperPhaseWeeks: 0,
            trainingDays: [1, 3, 5], longestWorkoutDay: 5, useSeparateDayForLongRun: false,
            volume: VolumeProfile(weeklyLoadIncreasePercent: 5...10, phaseFinishDeloadPercent: 10...12, taperDeloadPercent: 20,
                                  initialWeeklyDuration: 90, initialLongRunDuration: 20...30, maxLongRunMinutes: 60,
                                  longRunProgression: nil, baseLoad: 3000))
        config.fixedProtocol = plan
        return config
    }
}
