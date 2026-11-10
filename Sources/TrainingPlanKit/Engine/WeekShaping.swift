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

    /// A quality session the runner did in an earlier block of the same kind gives way to its
    /// twin: the same kind of session at the same intensity, within 5 minutes and 10% of its
    /// load and hard running. Selection is finished by now, so the week's shape, the long
    /// runs and every other choice stay exactly as built. No twin, no change.
    func withFreshSessions(_ plan: WeekPlan) -> WeekPlan {
        guard !config.sessionsDoneBefore.isEmpty else { return plan }
        var out = plan
        // One twin per session for the whole block, and never the same twin for two sessions.
        var twins: [String: Workout] = [:]
        var taken = config.sessionsDoneBefore.union(plan.values.joined().map(\.workout.key))
        for week in plan.keys.sorted() where !taperWeeks.contains(week) {
            for (index, session) in plan[week]!.enumerated() where isRepeat(session.workout) {
                let key = session.workout.key
                if twins[key] == nil, let twin = twin(of: session.workout, excluding: taken) {
                    twins[key] = twin
                    taken.insert(twin.key)
                }
                if let twin = twins[key] { out[week]![index].workout = twin }
            }
        }
        return out
    }

    /// A session worth varying: done before, and neither a long run nor a session whose exact
    /// form matters (race rehearsals, time trials).
    private func isRepeat(_ workout: Workout) -> Bool {
        guard let rank = workout.subtype.qualityRank, rank < 3, !workout.subtype.isLongRun else { return false }
        return config.sessionsDoneBefore.contains(workout.key)
    }

    /// The closest match in the generator's own pool, or nil when nothing is close enough.
    private func twin(of workout: Workout, excluding taken: Set<String>) -> Workout? {
        func near(_ a: Double, _ b: Double, within share: Double) -> Bool { abs(a - b) <= max(a, b) * share }
        func distance(_ w: Workout) -> Int64 { abs(w.trainingLoad - workout.trainingLoad) }
        return workoutPool
            .filter { $0.subtype == workout.subtype && $0.type == workout.type && !taken.contains($0.key) }
            .filter { $0.peakZone == workout.peakZone && abs($0.minutes - workout.minutes) <= 5 }
            .filter { near(Double($0.trainingLoad), Double(workout.trainingLoad), within: 0.10) }
            .filter { near($0.hardSeconds, workout.hardSeconds, within: 0.10) }
            .min { (distance($0), $0.key) < (distance($1), $1.key) }
    }

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

    /// A recovery week runs at most 90% of the minutes of the build week before it (80% with
    /// extended recovery). Its long run stops at 80% of that week's (75%), 60 min at least,
    /// then its longest plain run gives up 5 minutes at a time, never under 30. Quality stays.
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
            let cap = max(60, longBefore * config.recoveryWeekPercent.longRun / 100 / 5 * 5)
            if week.sessions[long].workout.minutes > cap { week.shorten(long, to: cap) }
        }
        let limit = before.minutes * config.recoveryWeekPercent.week / 100
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

    /// The highest heart-rate zone any of its intervals asks for.
    var peakZone: Int { intervals.compactMap(\.zone).max() ?? 0 }

    /// Hard reps of at most 4 minutes, each followed by a recovery at least half as long.
    var hasGentleReps: Bool {
        let reps = intervals.filter { $0.type == .work && ($0.zone ?? 0) >= 5 }.map(\.duration)
        let recoveries = intervals.filter { $0.type == .recovery || $0.type == .rest }.map(\.duration)
        guard let longestRep = reps.max(), let shortestRecovery = recoveries.min() else { return false }
        return longestRep <= 240 && shortestRecovery * 2 >= longestRep
    }

    /// Time at threshold effort or harder (zone 4 and up).
    var hardSeconds: Double { intervals.filter { ($0.zone ?? 0) >= 4 }.reduce(0) { $0 + $1.duration } }
}

extension WorkoutInterval {
    var zone: Int? {
        if case .heartRateZone(let zone) = target { return zone }
        return nil
    }
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
