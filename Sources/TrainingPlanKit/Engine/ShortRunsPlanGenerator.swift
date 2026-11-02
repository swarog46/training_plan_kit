//
//  ShortRunsPlanGenerator.swift
//  TrainingPlanKit
//
//  Short Runs: open-ended fitness for busy weeks. Every run is 40 min or less,
//  except one 50-60 min run every 4th week (the top of each block, right before
//  the cutback). Fitness builds through denser quality and slowly longer easy
//  days, not through long runs. Light weeks follow maintenance's cadence.
//

import Foundation

final class ShortRunsPlanGenerator: PlanGeneratorV3 {
    static let capMinutes = 40
    // The last few quality sessions (title + minutes, both kinds — the pools
    // overlap), so the ramp neither parks on one session nor repeats a week later.
    private var recentQuality: [String] = []

    /// The 0-based weeks that carry the longer run: W5, W9, W13, … — each one the
    /// week before a maintenance light week (W6, W10, …).
    static func isLongerRunWeek(week: Int) -> Bool {
        week >= 4 && week % 4 == 0
    }

    override func buildWeek(week: Int) {
        let phaseInfo = determinePhaseV3(weekIndex: week, baseDur: baseDur, speedDur: speedDur, peakDur: peakDur, taperDur: taperDur)
        if let prev = prevPhase, prev != phaseInfo.phase { usedIds.removeAll() }
        prevPhase = phaseInfo.phase
        let isLight = MaintenancePlanGenerator.isLightWeek(week: week)
        let level = config.runnerLevel
        let cap = Int64(Self.capMinutes * 60)

        // Easy days and quality sessions lengthen slowly toward the cap.
        let easyCap = level == .beginner ? 35 : Self.capMinutes
        let easyMin = min(easyCap, (level == .beginner ? 25 : 30) + week / 2)
        let qualityMin = min(easyCap, 30 + week / 2)
        let weekendMin = min(Self.capMinutes, easyMin + 5)
        let longerMin = min(60, 50 + (week / 4 - 1) * 5)

        let short: (Workout) -> Bool = { $0.duration <= cap }
        let easyPool = easyRuns.filter { $0.subtype == .easy && short($0) }
        // 2-3 tiny strides barely register; keep the 4+ rep sessions when there are any.
        let allStrides = easyRuns.filter { $0.subtype == .strides && short($0) }
        let realStrides = allStrides.filter { stridesRepCount($0) >= 4 }
        let stridesPool = realStrides.isEmpty ? allStrides : realStrides
        let progressionPool = workoutPool.filter { $0.subtype == .progression && short($0) }
        // Split quality by true intensity: Z5 reps + hills are speed, Z4 reps join
        // threshold/progression as tempo. Hills wait until W4; no rest-heavy reps.
        let reps = filterIntervalsByMaxRest(filteredIntervals, maxRest: config.profile.intervalRestCapSeconds)
            .filter { short($0) && ($0.subtype != .hillRepeats || week >= 3) }
        let z5Reps = reps.filter { isRealZ5($0) || $0.subtype == .hillRepeats }
        let z4Reps = reps.filter { !isRealZ5($0) && $0.subtype != .hillRepeats }
        // Beginner pools hold almost no short Z5 work; widen speed to all reps then.
        let speedPool = z5Reps.count >= 4 ? z5Reps : reps
        let tempoPool = (filteredThresholds.filter(short) + progressionPool + z4Reps)
        let longerPool = (easyRuns + longRuns).filter {
            [.easy, .long, .steadyLong, .progressiveLong].contains($0.subtype)
                && $0.duration >= 50 * 60 && $0.duration <= Int64(longerMin) * 60
        }

        // Quality climbs through its pool by load — the lightest sessions first,
        // the densest from ~W16 on (then held) — so fitness keeps building.
        func pick(_ pool: [Workout], prev: Workout?) -> Workout? {
            let loads = pool.map { Double($0.trainingLoad) }.sorted()
            guard !loads.isEmpty else { return nil }
            let target = loads[Int(min(0.9, 0.15 + Double(week) * 0.05) * Double(loads.count - 1))]
            let tag = { (w: Workout) in "\(w.title)|\(w.duration / 60)" }
            let fresh = pool.filter { !recentQuality.contains(tag($0)) }
            guard let w = selectWorkoutByTargetV3(workouts: fresh.isEmpty ? pool : fresh, targetLoad: target,
                                                  targetDuration: qualityMin, usedIds: &usedIds, previousWorkout: prev)
            else { return nil }
            recentQuality = Array((recentQuality + [tag(w)]).suffix(4))
            return w
        }
        func speed() -> (String, Workout)? {
            guard let w = pick(speedPool, prev: prevInterval) else { return nil }
            prevInterval = w
            return (w.subtype == .hillRepeats ? "hill" : "interval", w)
        }
        func tempo() -> (String, Workout)? {
            guard let w = pick(tempoPool, prev: prevThreshold) else { return nil }
            prevThreshold = w
            return ("threshold", w)
        }
        // Aerobic days go by minutes, not load: the closest length, least-used first.
        func easy(_ pool: [Workout], _ type: String, _ minutes: Int) -> (String, Workout)? {
            let pool = pool.isEmpty ? easyPool : pool
            guard let w = pool.min(by: { a, b in
                let da = abs(Int(a.duration / 60) - minutes), db = abs(Int(b.duration / 60) - minutes)
                return da != db ? da < db : usedIds[a.key, default: 0] < usedIds[b.key, default: 0]
            }) else { return nil }
            usedIds[w.key, default: 0] += 1
            return (type, w)
        }

        // Slots in priority order; a week of N days keeps the first N.
        var slots: [() -> (String, Workout)?] = []
        if isLight {
            // W1 is pure easy; W2 and the cutbacks keep strides, no hard session.
            if week > 0 {
                slots.append { easy(stridesPool, "easy_light", max(25, easyMin - 5)) }
            }
            slots.append { easy(easyPool, "long", weekendMin - 5) }
        } else {
            let speedFirst = week % 2 == 0
            slots.append { speedFirst ? speed() ?? tempo() : tempo() ?? speed() }
            if Self.isLongerRunWeek(week: week), !longerPool.isEmpty {
                slots.append { easy(longerPool, "long", longerMin) }
            } else {
                slots.append { easy(easyPool, "long", weekendMin) }
            }
            // Adv gets both qualities every week; Int adds strides or a progression;
            // beginners keep one quality and get strides every 3rd week.
            switch level {
            case .advanced, .competitive:
                slots.append { speedFirst ? tempo() ?? speed() : speed() ?? tempo() }
                slots.append { easy(stridesPool, "easy_strides", easyMin) }
            case .intermediate:
                slots.append { easy(week % 4 < 2 ? stridesPool : progressionPool, "easy_second", easyMin) }
            case .beginner:
                if week % 3 == 2 { slots.append { easy(stridesPool, "easy_strides", easyMin) } }
            }
        }

        var weekWorkouts: [(type: String, workout: Workout)] = []
        for slot in slots.prefix(config.trainingDays.count) {
            if let s = slot() { weekWorkouts.append(s) }
        }
        while weekWorkouts.count < config.trainingDays.count, let s = easy(easyPool, "easy_fill", easyMin) {
            weekWorkouts.append(s)
        }
        workoutsByWeek[week] = weekWorkouts
    }
}
