//
//  WeekShaping.swift
//  TrainingPlanKit
//
//  Passes over a generated plan, week by week, after selection: the weekly
//  quality cap and the recovery-week dip. They only swap or shorten sessions,
//  so the day count and the selector's choices for other weeks stay as built.
//

import Foundation

extension PlanGeneratorV3 {
    typealias WeekPlan = [Int: [(type: String, workout: Workout)]]

    /// Weeks over the plan's quality cap swap their least important quality sessions for an
    /// easy run (a quality long run for a steady one) of the same length. Taper weeks stay.
    func withQualityCap(_ plan: WeekPlan) -> WeekPlan {
        guard let cap = config.qualityCap else { return plan }
        let longestSteady = plan.values.joined().filter { $0.workout.subtype == .steadyLong || $0.workout.subtype == .long }
            .map { $0.workout.minutes }.max()
        var out = plan
        for (week, sessions) in plan where !taperWeeks.contains(week) {
            // Least important first: progressions, quality long runs, then the lightest hard session.
            func key(_ i: Int) -> (Int, Int64) { (sessions[i].workout.subtype.qualityRank ?? 0, sessions[i].workout.trainingLoad) }
            let quality = sessions.indices.filter { sessions[$0].workout.subtype.qualityRank != nil }
                .sorted { key($0) < key($1) }
            // A recovery week keeps one quality session.
            for i in quality.dropLast(deloadWeeks.contains(week) ? min(cap, 1) : cap) {
                let w = sessions[i].workout
                // A quality long run turns steady, no longer than the plan's own steady long runs;
                // plans without a long-run ramp (5K) take an easy run instead.
                let isLong = w.subtype.isLongRun && config.longRunProgression != nil
                let minutes = min(w.minutes, isLong ? longestSteady ?? .max : 75)
                guard let swap = plainRun(isLong ? .steadyLong : .easy, minutes: minutes) else { continue }
                out[week]![i] = (type: isLong ? sessions[i].type : "easy", workout: swap)
            }
        }
        return out
    }

    /// A recovery week runs at most 90% of the minutes of the build week before it. Its long
    /// run stops at 80% of that week's (60 min at least), then its longest plain run gives up
    /// 5 minutes at a time, never under 30. Quality sessions stay.
    func withRecoveryDip(_ plan: WeekPlan) -> WeekPlan {
        var out = plan
        for week in deloadWeeks.sorted() where !deloadWeeks.contains(week - 1) && !taperWeeks.contains(week - 1) {
            guard let before = plan[week - 1], var sessions = plan[week] else { continue }
            func minutes() -> Int { sessions.reduce(0) { $0 + $1.workout.minutes } }
            func longest(_ among: [Int]) -> Int? { among.max { sessions[$0].workout.duration < sessions[$1].workout.duration } }
            func shorten(_ i: Int, to minutes: Int) { sessions[i].workout = rescaledV3(sessions[i].workout, toSeconds: Int64(minutes * 60)) }

            if let long = longest(sessions.indices.filter { sessions[$0].workout.subtype.isLongRun }),
               let longBefore = before.filter({ $0.workout.subtype.isLongRun }).map({ $0.workout.minutes }).max() {
                let cap = max(60, longBefore * 4 / 5 / 5 * 5)
                if sessions[long].workout.minutes > cap { shorten(long, to: cap) }
            }
            let limit = before.reduce(0) { $0 + $1.workout.minutes } * 9 / 10
            while minutes() > limit,
                  let i = longest(sessions.indices.filter { sessions[$0].workout.subtype.isPlainRun && sessions[$0].workout.minutes > 30 }) {
                shorten(i, to: sessions[i].workout.minutes - 5)
            }
            // A medium-long run cut under an hour is an easy run.
            for i in sessions.indices where sessions[i].workout.subtype == .mediumLong && sessions[i].workout.minutes < 60 {
                guard let easy = plainRun(.easy, minutes: sessions[i].workout.minutes) else { continue }
                sessions[i].workout = rescaledV3(easy, toSeconds: sessions[i].workout.duration)
            }
            out[week] = sessions
        }
        return out
    }

    /// The catalog's run of this subtype closest to the length.
    func plainRun(_ subtype: WorkoutSubtype, minutes: Int) -> Workout? {
        allWorkouts.filter { $0.subtype == subtype }.min { abs($0.minutes - minutes) < abs($1.minutes - minutes) }
    }
}

extension Workout {
    var minutes: Int { Int(duration) / 60 }
}

extension WorkoutSubtype {
    /// The week's long-run slot: steady, or with quality in it.
    var isLongRun: Bool {
        switch self {
        case .long, .steadyLong, .progressiveLong, .raceRehearsalM, .raceRehearsalHM, .raceRehearsal10K, .fastFinish: return true
        default: return false
        }
    }
    /// Easy running a recovery week can shorten.
    var isPlainRun: Bool { self == .easy || self == .recovery || self == .mediumLong }
}
