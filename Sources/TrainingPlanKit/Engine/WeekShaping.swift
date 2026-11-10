//
//  WeekShaping.swift
//  TrainingPlanKit
//
//  Passes over a generated plan, week by week, after selection: the weekly
//  quality cap and the recovery-week dip. They only swap or shorten sessions,
//  so the day count and the selector's choices for other weeks stay as built.
//

import Foundation

/// One week's sessions, with what the shaping passes ask of a week.
struct WeekSessions {
    typealias Session = (type: String, workout: Workout)
    var sessions: [Session]

    var minutes: Int { sessions.reduce(0) { $0 + $1.workout.minutes } }
    var longRunMinutes: Int? { longRun.map { sessions[$0].workout.minutes } }

    /// The long-run slot: the longest session of a long-run subtype.
    var longRun: Int? { longest { $0.subtype.isLongRun } }

    /// The longest plain run still above `minutes`.
    func longestPlainRun(above minutes: Int) -> Int? {
        longest { $0.subtype.isPlainRun && $0.minutes > minutes }
    }

    /// Quality sessions, least important first: by rank, then the lighter one.
    var qualityByImportance: [Int] {
        sessions.indices.filter { sessions[$0].workout.subtype.qualityRank != nil }
            .sorted { importance($0) < importance($1) }
    }

    mutating func shorten(_ index: Int, to minutes: Int) {
        sessions[index].workout = rescaledV3(sessions[index].workout, toSeconds: Int64(minutes * 60))
    }

    private func importance(_ index: Int) -> (Int, Int64) {
        (sessions[index].workout.subtype.qualityRank ?? 0, sessions[index].workout.trainingLoad)
    }

    private func longest(where matches: (Workout) -> Bool) -> Int? {
        sessions.indices.filter { matches(sessions[$0].workout) }
            .max { sessions[$0].workout.duration < sessions[$1].workout.duration }
    }
}

extension PlanGeneratorV3 {
    typealias WeekPlan = [Int: [WeekSessions.Session]]

    /// Weeks over the plan's quality cap swap their least important quality sessions for an
    /// easy run (a quality long run for a steady one) of the same length. Taper weeks stay.
    func withQualityCap(_ plan: WeekPlan) -> WeekPlan {
        guard let cap = config.qualityCap else { return plan }
        let longestSteady = plan.values.joined().map(\.workout)
            .filter { $0.subtype == .steadyLong || $0.subtype == .long }.map(\.minutes).max()
        var out = plan
        for (week, sessions) in plan where !taperWeeks.contains(week) {
            // A recovery week keeps one quality session.
            let kept = deloadWeeks.contains(week) ? min(cap, 1) : cap
            for index in WeekSessions(sessions: sessions).qualityByImportance.dropLast(kept) {
                guard let swap = plainSwap(for: sessions[index], longestSteady: longestSteady) else { continue }
                out[week]![index] = swap
            }
        }
        return out
    }

    /// A quality long run turns steady, no longer than the plan's own steady long runs; other
    /// sessions, and long runs in plans without a long-run ramp (5K), turn into an easy run.
    private func plainSwap(for session: WeekSessions.Session, longestSteady: Int?) -> WeekSessions.Session? {
        let workout = session.workout
        if workout.subtype.isLongRun, config.longRunProgression != nil {
            return plainRun(.steadyLong, minutes: min(workout.minutes, longestSteady ?? .max)).map { (session.type, $0) }
        }
        return plainRun(.easy, minutes: min(workout.minutes, 75)).map { ("easy", $0) }
    }

    /// A recovery week runs at most 90% of the minutes of the build week before it. Its long
    /// run stops at 80% of that week's (60 min at least), then its longest plain run gives up
    /// 5 minutes at a time, never under 30. Quality sessions stay.
    func withRecoveryDip(_ plan: WeekPlan) -> WeekPlan {
        var out = plan
        for week in deloadWeeks.sorted() where isBuildWeek(week - 1) {
            guard let before = plan[week - 1].map(WeekSessions.init), let sessions = plan[week] else { continue }
            out[week] = recovering(WeekSessions(sessions: sessions), after: before).sessions
        }
        return out
    }

    private func isBuildWeek(_ week: Int) -> Bool {
        !deloadWeeks.contains(week) && !taperWeeks.contains(week)
    }

    private func recovering(_ recovery: WeekSessions, after before: WeekSessions) -> WeekSessions {
        var week = recovery
        if let long = week.longRun, let longBefore = before.longRunMinutes {
            let cap = max(60, longBefore * 4 / 5 / 5 * 5)
            if week.sessions[long].workout.minutes > cap { week.shorten(long, to: cap) }
        }
        let limit = before.minutes * 9 / 10
        while week.minutes > limit, let run = week.longestPlainRun(above: 30) {
            week.shorten(run, to: week.sessions[run].workout.minutes - 5)
        }
        return relabelingShortMediumLongs(week)
    }

    /// A medium-long run cut under an hour is an easy run.
    private func relabelingShortMediumLongs(_ recovery: WeekSessions) -> WeekSessions {
        var week = recovery
        for index in week.sessions.indices {
            let workout = week.sessions[index].workout
            guard workout.subtype == .mediumLong, workout.minutes < 60,
                  let easy = plainRun(.easy, minutes: workout.minutes) else { continue }
            week.sessions[index].workout = rescaledV3(easy, toSeconds: workout.duration)
        }
        return week
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
