//
//  PlanGeneratorV3.swift
//  RunPlan
//
//  1:1 Port of Python analyze_plan.py
//  Created by AI on 28/12/2024.
//

import Foundation

// MARK: - Seeded Random Number Generator

public struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

// MARK: - Phase Duration Calculation (mirrors calculate_phase_durations)

public func calculatePhaseDurations(config: PlanConfiguration, totalWeeks: Int) -> [String: Int] {
    // Taper is fixed — longer plans get more training, not more taper
    let taper = config.minTaperPhaseWeeks
    let trainingWeeks = totalWeeks - taper

    // Calculate training phase durations from remaining weeks
    // Normalize ratios excluding taper
    let trainingRatioSum = config.basePhaseRatio + config.speedPhaseRatio + config.peakPhaseRatio
    var base: Int
    var speed: Int
    var peak: Int

    if trainingRatioSum > 0 {
        base = Int(Double(trainingWeeks) * config.basePhaseRatio / trainingRatioSum)
        speed = Int(Double(trainingWeeks) * config.speedPhaseRatio / trainingRatioSum)
        peak = Int(Double(trainingWeeks) * config.peakPhaseRatio / trainingRatioSum)
    } else {
        base = trainingWeeks
        speed = 0
        peak = 0
    }

    // Ensure minimum durations are met
    base = max(base, config.minBasePhaseWeeks)
    speed = max(speed, config.minSpeedPhaseWeeks)
    peak = max(peak, config.minPeakPhaseWeeks)

    // Adjust for total weeks
    let currentTotal = base + speed + peak + taper
    if currentTotal < totalWeeks {
        let extraWeeks = totalWeeks - currentTotal
        if config.runnerLevel == .competitive {
            // Competitive plans: extras go to BASE (VDOT-building phase).
            base += extraWeeks
        } else {
            // Non-competitive: extras go to peak.
            peak += extraWeeks
        }
    } else if currentTotal > totalWeeks {
        // Remove from base first, then speed
        var excess = currentTotal - totalWeeks
        if base > config.minBasePhaseWeeks {
            let reduction = min(excess, base - config.minBasePhaseWeeks)
            base -= reduction
            excess -= reduction
        }
        if excess > 0 && speed > config.minSpeedPhaseWeeks {
            let reduction = min(excess, speed - config.minSpeedPhaseWeeks)
            speed -= reduction
        }
    }

    // Final pass: cap PEAK at 8 weeks for competitive plans (Pfitz peak
    // windows are 6-8 weeks; longer = overtraining). Any excess moves to
    // BASE — that's where VDOT growth actually happens, and a 28-week
    // sub-3h plan needs a long BASE not an 11-week PEAK.
    if config.runnerLevel == .competitive && peak > 8 {
        let excess = peak - 8
        peak = 8
        base += excess
    }

    return ["base": base, "speed": speed, "peak": peak, "taper": taper]
}

// MARK: - Phase Determination (mirrors determine_phase)

public func determinePhaseV3(weekIndex: Int, baseDur: Int, speedDur: Int, peakDur: Int, taperDur: Int) -> (phase: TrainingPhase, weekInPhase: Int) {
    // Week ordering: BASE -> SPEED -> PEAK -> TAPER -> RACE (last week)
    // The final week of the plan is race week — distinct from taper because
    // it cuts volume to ~50% of peak (Pfitz / Daniels) rather than the
    // gradual ramp-down the taper phase delivers. Only fires when taper
    // is >= 2 weeks (a 1-week taper IS the race week, no need to split).
    let totalWeeks = baseDur + speedDur + peakDur + taperDur
    if taperDur >= 2 && weekIndex == totalWeeks - 1 {
        return (.race, 0)
    }
    if weekIndex >= baseDur + speedDur + peakDur {
        return (.taper, weekIndex - (baseDur + speedDur + peakDur))
    } else if weekIndex >= baseDur + speedDur {
        return (.peak, weekIndex - (baseDur + speedDur))
    } else if weekIndex >= baseDur {
        return (.speed, weekIndex - baseDur)
    } else {
        return (.base, weekIndex)
    }
}

// MARK: - Weekly Targets (mirrors calculate_weekly_targets)

public struct WeeklyTargets {
    let load: Double
    let duration: Double
    let isDeloading: Bool
    let phaseProgression: Double
}

public func calculateWeeklyTargetsV3(weekInPlan: Int, weekInPhase: Int, phase: TrainingPhase,
                              phaseDurations: [String: Int], config: PlanConfiguration) -> WeeklyTargets {
    // Calculate phase progression percentage
    let phaseDuration = phaseDurations[phase.rawValue.lowercased()] ?? 1
    let safePhasePhase = max(1, phaseDuration)
    let phaseProgression = min(1.0, Double(weekInPhase) / Double(safePhasePhase))
    
    // Base values
    var baseLoad: Double
    switch config.runnerLevel {
    case .beginner: baseLoad = 4500
    case .intermediate: baseLoad = 8000
    case .advanced: baseLoad = 14000
    case .competitive: baseLoad = 20000  // sub-3h / sub-1:30 starting weekly load
    }
    var duration = Double(config.initialWeeklyDuration)

    // Int/Adv 10K: extra +20% baseLoad on top of the 5K/10K base 1.15×
    // bump (compound effective ~1.38) so the 10K plan visibly out-volumes
    // the 5K plan. Without this, 5K's faster easy pace (sub-20 5K runner
    // at 4:50/km) gives it higher km/wk than 10K (sub-44 10K runner at
    // 5:09/km) at similar training time. The extra bump aligns with user
    // mental model "longer race = more training", and lands Adv 10K at
    // ~92 km/wk (top of Daniels Phase II Adv 10K range = 70-90 km).
    if config.distance == 10000 {
        switch config.runnerLevel {
        case .intermediate: baseLoad *= 1.20
        case .advanced: baseLoad *= 1.20
        default: break
        }
    }

    // Int/Adv 5K/10K: bump baseLoad 15% toward Daniels/Pfitz references.
    // Previous values (Int=8000, Adv=14000) left Int 5K at 36 km/wk
    // (Pfitz/Daniels Int = 50-65 km, ~30% under) and Adv 5K at 63 km
    // (Daniels Adv = 70-85 km, ~15% under). 1.15× lifts Int 5K to ~42
    // and Adv 5K to ~72 — closer to Pfitz/Daniels without overshooting
    // the day-count ceiling (5K runs 3-4 days/wk). Same lift applied to
    // 10K plans (Int 10K from 47→~54 km, Adv 10K from 58→~67). Gated
    // by distance >= 5000 && < 21000 to scope to 5K/10K only.
    if config.distance >= 5000 && config.distance < 21000 {
        switch config.runnerLevel {
        case .intermediate: baseLoad *= 1.15
        case .advanced: baseLoad *= 1.15
        default: break
        }
    }

    // Int/Adv 42K: bump baseLoad 25% toward Pfitz prescriptions. Previous
    // values (8000 / 14000) left marathon plans at 65 km/wk (Int, 26%
    // under Pfitz 18/55's 88 km) and 87 km/wk (Adv, 23% under Pfitz
    // 18/70's 113 km). 1.20× closed half the gap; 1.25× lands Int ~76 km
    // (14% under) and Adv ~106 km (6% under) — Adv comfortably inside
    // Pfitz 18/70 range, Int still distinct from Cmp's 126 km. The bump
    // alone would kill marathonPace selection (selector preferred bigger
    // threshold workouts at higher loads); solved by the MP-forcing in
    // the threshold slot above — MP is now guaranteed on alternating
    // PEAK weeks regardless of the bump. 42K-gated to preserve the half
    // plans which are at or above their Pfitz half references.
    if config.distance >= 30000 {
        switch config.runnerLevel {
        case .intermediate: baseLoad *= 1.25
        case .advanced: baseLoad *= 1.25
        default: break
        }
    }

    // Sub-1:30 half: trim 25% off both baseLoad AND initial duration. The
    // .competitive baseLoad (20000) is calibrated for sub-3 marathon volume
    // (Pfitz 18/85 ≈ 137 km/wk peak). Applied unchanged to the half it ran
    // 119 km/wk peak — well above Pfitz's competitive half-marathon range
    // (82-101 km/wk).
    //
    // Two cuts together because the selector compensates for either alone:
    // when only baseLoad drops, the selector picks similar-duration workouts
    // (overshooting load slightly to hit duration target). When only duration
    // drops, it picks shorter quality workouts (overshooting load). Cutting
    // both anchors the selector to genuinely lower per-week targets. 0.75×
    // lands ~100 km/wk peak (top of Pfitz band), 6 days/wk preserved.
    // Marathon untouched.
    if config.runnerLevel == .competitive && config.distance == 21097 {
        baseLoad *= 0.75
        duration *= 0.75
    }

    // Competitive plans only: longer plans start LOWER and ramp up, not at
    // peak-fitness starting volume from W1. A runner who needs 28 weeks to
    // reach sub-3 is by definition LESS fit at W1 than someone doing 18w
    // (otherwise the longer plan wouldn't be necessary). Scale down both
    // initial duration and base load proportionally to plan length above
    // an 18w baseline.
    if config.runnerLevel == .competitive {
        let totalPlanWeeks = phaseDurations.values.reduce(0, +)
        let baselinePlanLength = 18
        if totalPlanWeeks > baselinePlanLength {
            let scale = Double(baselinePlanLength) / Double(totalPlanWeeks)
            duration *= scale
            baseLoad *= scale
        }
    }
    
    // Apply phase boost with smooth transitions
    var phaseBoost = 1.0
    var targetPhaseBoost = 1.0

    switch phase {
    case .base:
        targetPhaseBoost = 1.0
    case .speed:
        targetPhaseBoost = 1.35
    case .peak:
        targetPhaseBoost = 1.7
    case .taper:
        // Taper reduces from peak: 70% -> 50%
        let taperReduction = 0.7 - (0.2 * phaseProgression)
        targetPhaseBoost = 1.7 * taperReduction
    case .race:
        // Race week: 55% of peak load
        return WeeklyTargets(
            load: baseLoad * 1.7 * 0.55,
            duration: duration * 0.6,
            isDeloading: true,
            phaseProgression: 1.0
        )
    }

    // Smooth phase transitions: ramp up gradually over first 2 weeks
    //
    // Cmp 21K PEAK exception: skip the ramp. With only 5 PEAK weeks (5w PEAK
    // + 1w smooth ramp × 2 = 2 ramp weeks), the smooth ramp eats 40% of the
    // phase. By the time full boost lands at W13 there are only 2 weeks of
    // it before TAPER. Result: BASE peak min (565) > PEAK peak min (515) —
    // backwards from Pfitz/Daniels shape, and not deliberate Canova/Norwegian
    // either (just a side-effect of phase math). The marathon's 8-week PEAK
    // absorbs the ramp fine; the half doesn't have room. Competitive runners
    // at this gate level have the fitness to handle full PEAK boost in W1.
    let skipPeakSmoothRamp = phase == .peak
        && config.runnerLevel == .competitive
        && config.distance == 21097
    if phase != .base && phase != .race && !skipPeakSmoothRamp {
        let previousPhaseBoost: Double
        switch phase {
        case .speed:
            previousPhaseBoost = 1.0  // BASE boost
        case .peak:
            previousPhaseBoost = 1.35  // SPEED boost
        case .taper:
            previousPhaseBoost = 1.7  // PEAK boost
        default:
            previousPhaseBoost = targetPhaseBoost
        }

        if weekInPhase == 0 {
            // First week: 50% of increase
            phaseBoost = previousPhaseBoost + (targetPhaseBoost - previousPhaseBoost) * 0.5
        } else if weekInPhase == 1 {
            // Second week: 75% of increase
            phaseBoost = previousPhaseBoost + (targetPhaseBoost - previousPhaseBoost) * 0.75
        } else {
            // Week 3+: full target boost
            phaseBoost = targetPhaseBoost
        }
    } else {
        phaseBoost = targetPhaseBoost
    }
    
    // Check if deloading (end of phase)
    let isPhaseEndDeload = phaseProgression >= 0.8

    // Check if this is a mid-phase recovery week (every 4th week in build phases)
    // Mid-phase recovery cadence is phase-relative, not plan-relative.
    // 3:1 build:recovery within any phase >= 4 weeks. Skips race/taper
    // (already deloaded) and the smooth-transition ramp.
    //
    // Previous logic used `weekInPlan % 4 == 3` which placed recovery weeks
    // at random points within phases (and excluded BASE entirely — but a
    // long beginner BASE absolutely benefits from a cutback week).
    let isMidPhaseRecovery: Bool = {
        guard phase != .race, phase != .taper, !isPhaseEndDeload else { return false }
        guard phaseDuration >= 4 else { return false }   // Skip on short phases
        guard weekInPhase >= 2 else { return false }     // Skip during smooth-transition ramp
        return weekInPhase % 3 == 2                      // Every 3rd week within phase
    }()

    var isDeloading = isPhaseEndDeload || isMidPhaseRecovery

    let load: Double
    if phaseProgression >= 0.8 {
        // Phase-end deload - cap at 25%
        let deloadPercent = min(25.0, (config.phaseFinishDeloadPercent.lowerBound + config.phaseFinishDeloadPercent.upperBound) / 2)
        load = baseLoad * phaseBoost * (1.0 + 0.8 * phaseProgression) * (1.0 - deloadPercent / 100)
        duration = duration * phaseBoost * (1.0 + 0.7 * phaseProgression) * (1.0 - deloadPercent / 100)
    } else if isMidPhaseRecovery {
        // Mid-phase recovery week - 15% reduction (25% for competitive).
        // Competitive plans run higher absolute volume, so recovery needs to
        // be more pronounced to actually feel like recovery. At sub-3h
        // training loads a 15% drop is invisible; 25% is what Pfitz's
        // cutback weeks actually deliver.
        let increasePercent = (config.weeklyLoadIncreasePercent.lowerBound + config.weeklyLoadIncreasePercent.upperBound) / 2
        let progressionFactor = 1.0 + (phaseProgression * increasePercent / 100 * 5)
        let recoveryMult = config.runnerLevel == .competitive ? 0.75 : 0.85
        load = baseLoad * phaseBoost * progressionFactor * recoveryMult
        duration = duration * phaseBoost * progressionFactor * recoveryMult
    } else if phase == .taper {
        // Taper: pure phaseBoost-driven reduction within phase. Do NOT
        // apply progressionFactor — it grows with phaseProgression, which
        // for build phases means "more load as the phase ramps up" but in
        // a taper that's exactly the wrong signal. With progressionFactor
        // compounding upward, a 3-week taper's last week landed at 82%
        // of peak volume — Pfitz / Daniels target 50-55%. Removing the
        // factor lets phaseBoost (1.19 → 0.85 across the 3 weeks) do its
        // job: race-week ends up at the intended ~50% of peak.
        load = baseLoad * phaseBoost
        duration = duration * phaseBoost
        isDeloading = true  // every taper week is a deload by definition
    } else {
        // Normal progression
        let increasePercent = (config.weeklyLoadIncreasePercent.lowerBound + config.weeklyLoadIncreasePercent.upperBound) / 2
        let progressionFactor = 1.0 + (phaseProgression * increasePercent / 100 * 5)
        load = baseLoad * phaseBoost * progressionFactor
        duration = duration * phaseBoost * progressionFactor
    }

    return WeeklyTargets(load: load, duration: duration, isDeloading: isDeloading, phaseProgression: phaseProgression)
}

// MARK: - Workout Selection (mirrors select_workout_by_target)

public func selectWorkoutByTargetV3(workouts: [Workout], targetLoad: Double, targetDuration: Int,
                             usedIds: inout [String: Int], previousWorkout: Workout? = nil,
                             isDeloading: Bool = false, phaseJustStarted: Bool = false,
                             isMaintenance: Bool = false,
                             varietyBonusBoost: Double = 0.05) -> Workout? {
    guard !workouts.isEmpty else { return nil }

    var bestMatch: Workout? = nil
    var bestScore = Double.infinity

    for w in workouts {
        let workoutLoad = Double(w.trainingLoad)
        let workoutDuration = Double(w.duration) / 60.0  // Convert to minutes

        let safeTargetLoad = max(targetLoad, 1)
        let safeTargetDuration = max(Double(targetDuration), 1)

        let loadDiff = abs(workoutLoad - safeTargetLoad) / safeTargetLoad
        let durationDiff = abs(workoutDuration - safeTargetDuration) / safeTargetDuration

        // Base score from load/duration match
        var score = loadDiff * 0.3 + durationDiff * 0.2

        // Maintenance plan adjustments: favor easy/long/progression, penalize intense workouts
        if isMaintenance {
            if w.type == .easyRun || w.type == .longRun || w.type == .progressionRun {
                score *= 0.6  // Strong preference for these workout types
            } else if w.type == .intervalRun || w.type == .speedRun {
                score *= 1.8  // Penalize intense workouts
            } else if w.type == .thresholdRun || w.type == .fartlekRun {
                score *= 1.3  // Moderate penalty for threshold work
            }
        }
        
        // Variety bonus — penalty scales with how many times we've already
        // picked this workout this phase. Was a binary Set check (0.05 if
        // ever used) which went stale within ~5 weeks because every pool
        // member had been used at least once. Now usedIds is a counter
        // dict, so workouts used 5× incur a 0.25 penalty vs 0.05 for once
        // — meaningfully shifts the ranking even when "everything has
        // been used at least once" in long plans.
        let usage = usedIds[w.key, default: 0]
        if usage > 0 {
            score += Double(usage) * varietyBonusBoost
        }
        
        // VERY STRONG penalty for same workout as previous week
        if let prev = previousWorkout, w.key == prev.key {
            score += 2.0
        }
        // Title-based penalty. Catalog has e.g. "Hill Repeats (8 x 60s)" at
        // 3 different durations (40/42/44min) — all with different keys, so
        // the key-based penalty above doesn't stop the selector from picking
        // "Hill Repeats (8 x 60s)" 5 weeks in a row (different durations,
        // same workout from the runner's perspective). Title match captures
        // the runner-visible repetition.
        if let prev = previousWorkout, w.title == prev.title && w.key != prev.key {
            score += 0.8
        }
        
        // Progression-aware scoring for threshold/interval types
        if let prev = previousWorkout, prev.type.name == w.type.name {
            let prevRest = prev.restDuration
            let currRest = w.restDuration
            
            if isDeloading {
                // DELOAD: prefer same or LONGER rest
                if currRest >= prevRest {
                    score -= 0.1
                } else {
                    score += 0.15
                }
            } else {
                // BUILD week: prefer same or shorter rest
                if currRest == prevRest {
                    score -= 0.25
                } else if currRest < prevRest {
                    score -= 0.15
                } else {
                    // Increasing rest during build is bad
                    let restIncrease = Double(currRest - prevRest) / Double(max(prevRest, 60))
                    score += 0.4 + (restIncrease * 0.3)
                }
            }
        }
        
        // At phase start for intervals/threshold: prefer moderate rest (60-75s ideal)
        let isIntervalOrThreshold = w.type == .intervalRun || w.type == .thresholdRun
        
        if phaseJustStarted && isIntervalOrThreshold && !w.intervals.isEmpty {
            // Get rest per interval
            let restIntervals = w.intervals.filter { $0.type == .recovery }
            let restPerInterval = restIntervals.first?.duration ?? 0
            
            if restPerInterval > 0 && (previousWorkout == nil || previousWorkout?.type != w.type) {
                // First workout of this type - prefer moderate rest
                if restPerInterval < 45 {
                    score += 1.5
                } else if restPerInterval > 90 {
                    let excessRest = Double(restPerInterval - 90) / 90.0
                    score += 1.0 + (excessRest * 0.8)
                } else if restPerInterval >= 60 && restPerInterval <= 75 {
                    score -= 1.0  // Ideal range
                } else {
                    score -= 0.5
                }
            }
        }
        
        if score < bestScore {
            bestScore = score
            bestMatch = w
        }
    }
    
    // Mark as used — increment count, not just flag.
    if let match = bestMatch {
        usedIds[match.key, default: 0] += 1
    }
    
    return bestMatch
}

// MARK: - Filter by Subtype

public func filterWorkoutsBySubtypeV3(workouts: [Workout], subtypes: [WorkoutSubtype]) -> [Workout] {
    return workouts.filter { subtypes.contains($0.subtype) }
}

// MARK: - Main Plan Generation (mirrors simulate_plan)

/// `adaptive` controls whether paid-tier subtypes (raceRehearsalM/HM/10K,
/// timeTrial, mileRepeats, yasso800, marathonPace) are eligible for selection. Defaults
/// to `true` for back-compat — callers will start passing the entitlement
/// state once StoreKit lands. Per-distance eligibility (e.g. yasso 800s only
/// in marathon plans) applies regardless of this flag — see WorkoutSubtype
/// .eligibleDistances.
public func simulatePlanV3(config: PlanConfiguration, totalWeeks: Int, allWorkouts: [Workout], adaptive: Bool = true) -> [Int: [(type: String, workout: Workout)]] {
    // Calculate minimum required weeks
    let minRequiredWeeks = config.minBasePhaseWeeks + config.minSpeedPhaseWeeks + config.minPeakPhaseWeeks + config.minTaperPhaseWeeks
    
    // If user wants fewer weeks than minimum, generate full plan and trim from start
    let weeksToTrim: Int
    let actualWeeksToGenerate: Int
    if totalWeeks < minRequiredWeeks {
        weeksToTrim = minRequiredWeeks - totalWeeks
        actualWeeksToGenerate = minRequiredWeeks
    } else {
        weeksToTrim = 0
        actualWeeksToGenerate = totalWeeks
    }
    
    let phaseDurations = calculatePhaseDurations(config: config, totalWeeks: actualWeeksToGenerate)
    let baseDur = phaseDurations["base"] ?? 0
    let speedDur = phaseDurations["speed"] ?? 0
    let peakDur = phaseDurations["peak"] ?? 0
    let taperDur = phaseDurations["taper"] ?? 0
    
    // Subtype gating, two axes:
    //   1. Per-distance eligibility — `WorkoutSubtype.eligibleDistances`
    //      (marathonPace/yasso800/raceRehearsal: marathon-only; mileRepeats:
    //      10K+; etc.). Applies regardless of paywall — yasso 800s in a 5K
    //      plan would be nonsensical even for a paid user.
    //   2. Adaptive paywall — `WorkoutSubtype.isAdaptiveOnly`. Free plans
    //      skip the 5 paid-tier subtypes (raceRehearsal, timeTrial,
    //      mileRepeats, yasso800, marathonPace). Driven by the `adaptive`
    //      flag passed in, default true today.
    func isSubtypeEligible(_ subtype: WorkoutSubtype) -> Bool {
        if !adaptive && subtype.isAdaptiveOnly { return false }
        return subtype.eligibleDistances.contains(config.distance)
    }

    let intervalSubtypes: [WorkoutSubtype] = [
        .intervals, .pyramidIntervals, .ladderIntervals, .hillRepeats,
        .timeTrial, .yasso800, .fivekPace,
    ].filter(isSubtypeEligible)

    let thresholdSubtypes: [WorkoutSubtype] = [
        .threshold, .mileRepeats, .marathonPace, .tenkPace,
    ].filter(isSubtypeEligible)

    let longRunSubtypes: [WorkoutSubtype] = [
        .long, .steadyLong, .progressiveLong,
        .raceRehearsalM, .raceRehearsalHM, .raceRehearsal10K,
        .fastFinish,
    ].filter(isSubtypeEligible)

    // Easy pool intentionally includes mediumLong + recovery — these are
    // semantic splits of what was previously a single `easy` subtype
    // (recovery for ≤45min, easy for 46-80min, mediumLong for >80min).
    // The selector still chooses by load+duration target, so the right
    // bucket gets picked automatically. The split surfaces in UI titles
    // ("Recovery Run", "Easy Run", "Medium-Long Run") — runners see
    // the Pfitz/Daniels semantic category, not a generic "Easy Run".
    let easySubtypes: [WorkoutSubtype] = [.easy, .strides, .recovery, .mediumLong].filter(isSubtypeEligible)

    let intervals = filterWorkoutsBySubtypeV3(workouts: allWorkouts, subtypes: intervalSubtypes)
    let thresholds = filterWorkoutsBySubtypeV3(workouts: allWorkouts, subtypes: thresholdSubtypes)
    let longRuns = filterWorkoutsBySubtypeV3(workouts: allWorkouts, subtypes: longRunSubtypes)
    // Competitive (sub-3h / sub-1:30) plans require the Pfitz weekday MLR
    // pattern — easy days are 60-90min, not the 25-50min default. Filter
    // the `.easy` subtype to >= 60min for competitive runners; keep strides
    // intact (they're naturally shorter and serve a different purpose).
    let easyRuns: [Workout] = {
        let pool = filterWorkoutsBySubtypeV3(workouts: allWorkouts, subtypes: easySubtypes)
        if config.runnerLevel == .competitive {
            return pool.filter { w in
                w.subtype == .strides || w.duration >= 60 * 60
            }
        }
        return pool
    }()

    let isBeginner = config.runnerLevel == .beginner
    let isMaintenance = config.distance == 0  // Maintenance plans have no race target

    // Exclude short progression runs (< 40min) from race plans — they're maintenance-only
    let allWorkouts = isMaintenance ? allWorkouts : allWorkouts.filter {
        !($0.subtype == .progression && $0.duration < 40 * 60)
    }

    // Filter out HR zone 5 for beginners (helper function)
    func hasZone5(_ workout: Workout) -> Bool {
        for interval in workout.intervals {
            if interval.target == TargetRange.heartRateZone(zone: 5) {
                return true
            }
        }
        return false
    }
    
    var filteredIntervals = intervals
    var filteredThresholds = thresholds
    if isBeginner {
        if config.isVO2Max {
            // VO2 max fitness block — the entire point is the Z5 stimulus,
            // so the regular Beg "no Z5" rule is wrong here. Allow the
            // VO2-flavored subtypes (hillRepeats for strength/power,
            // fivekPace for short I-pace reps) through plus timeTrial as
            // a periodic benchmark. Threshold pool stays — it's the
            // aerobic foundation that VO2 work sits on. Plain `.intervals`
            // (3-5min I-pace reps) stay excluded; those are too punishing
            // without an aerobic base.
            let vo2BegIntervals: Set<WorkoutSubtype> = [.hillRepeats, .timeTrial, .fivekPace]
            filteredIntervals = intervals.filter { vo2BegIntervals.contains($0.subtype) }
            let vo2BegThresholds: Set<WorkoutSubtype> = [.threshold]
            filteredThresholds = thresholds.filter { vo2BegThresholds.contains($0.subtype) }
        } else {
            // Beginners avoid Z5 work in general (too anaerobic, injury-prone)
            // — but Time Trials are an exception: a sustained race effort over
            // 15-30min is conceptually a tune-up race, which beginners CAN
            // and should do. Exempt timeTrial from this filter.
            filteredIntervals = intervals.filter { $0.subtype == .timeTrial || !hasZone5($0) }
            filteredThresholds = thresholds.filter { !hasZone5($0) }
            // Higdon Novice 1 has ZERO quality workouts. Pfitz Just Finish has
            // marathon-pace work only. Our Beg plans were also pulling in
            // intervals, mile repeats, yasso 800s, 5K/10K pace work — that's
            // intermediate-level quality. For Beg, keep only hillRepeats and
            // timeTrial in the interval pool (hills build strength, TT is a
            // tune-up race), and threshold + marathonPace in the threshold pool
            // (the two pillars of marathon-specific quality).
            let begAllowedIntervals: Set<WorkoutSubtype> = [.hillRepeats, .timeTrial]
            let begAllowedThresholds: Set<WorkoutSubtype> = [.threshold, .marathonPace]
            filteredIntervals = filteredIntervals.filter { begAllowedIntervals.contains($0.subtype) }
            filteredThresholds = filteredThresholds.filter { begAllowedThresholds.contains($0.subtype) }
        }
    }
    
    var workoutsByWeek: [Int: [(type: String, workout: Workout)]] = [:]
    var usedIds: [String: Int] = [:]
    var prevInterval: Workout? = nil
    var prevThreshold: Workout? = nil
    var prevPhase: TrainingPhase? = nil
    // Track previous week's long-run duration in minutes so we can enforce
    // monotonic progression: long runs grow (or stay flat) in BASE/SPEED/PEAK
    // and shrink (or stay flat) in TAPER/RACE. Selector noise without this
    // produces W3→W4 regressions and W16→W17 long-run growth in taper.
    var prevLongRunMins: Int = 0
    
    // Determine surprise weeks for intermediate/advanced
    let surpriseProgressiveCount: Int
    switch config.distance {
    case 5000: surpriseProgressiveCount = 1
    case 10000: surpriseProgressiveCount = 2
    case 21097: surpriseProgressiveCount = 3
    default: surpriseProgressiveCount = 4
    }
    
    let totalSpeedPeakWeeks = speedDur + peakDur
    var surpriseWeeks: Set<Int> = []
    if totalSpeedPeakWeeks > 0 && !isBeginner {
        let intervalSize = max(1, totalSpeedPeakWeeks / (surpriseProgressiveCount + 1))
        let speedStart = baseDur
        for i in 1...surpriseProgressiveCount {
            let surpriseWeek = speedStart + (i * intervalSize)
            if surpriseWeek < actualWeeksToGenerate - 1 {
                surpriseWeeks.insert(surpriseWeek)
            }
        }
    }
    
    for week in 0..<actualWeeksToGenerate {
        let phaseInfo = determinePhaseV3(weekIndex: week, baseDur: baseDur, speedDur: speedDur, peakDur: peakDur, taperDur: taperDur)
        let phase = phaseInfo.phase
        let weekInPhase = phaseInfo.weekInPhase
        
        // Detect phase transition
        let phaseJustStarted = prevPhase != nil && phase != prevPhase!
        if phaseJustStarted {
            // Reset variety tracking at phase boundaries — encourages reuse
            // of pool workouts within each phase. Previously tried persisting
            // across phases for competitive to push variety harder, but
            // that interacted badly with the cumulative penalty: heavily-
            // penalized "good match" workouts gave way to short easies that
            // dragged total volume down (~5% drop for Cmp 42K rec). Keep
            // the per-phase reset; cumulative penalty within a phase is
            // enough.
            usedIds.removeAll()
        }
        prevPhase = phase
        
        // Calculate targets
        let targets = calculateWeeklyTargetsV3(weekInPlan: week, weekInPhase: weekInPhase, phase: phase, phaseDurations: phaseDurations, config: config)
        let isDeloading = targets.isDeloading
        
        var weekWorkouts: [(type: String, workout: Workout)] = []
        let targetLoad = targets.load
        let targetDuration = targets.duration
        
        let maxWorkoutsPerWeek = config.trainingDays.count
        
        // Filter intervals by max rest per runner level. Only applies to the
        // VO2max-style subtypes (intervals/pyramidIntervals/ladderIntervals)
        // that get their stimulus from short-rest density. Hill repeats,
        // yasso 800s, mile repeats, and time trials are designed with long
        // recoveries by construction — exempt them from this filter or they
        // get excluded for advanced runners (60s rest cap).
        let maxRestPerInterval = isBeginner ? 75 : 60
        let restGatedSubtypes: Set<WorkoutSubtype> = [.intervals, .pyramidIntervals, .ladderIntervals]
        func filterIntervalsByMaxRest(_ workouts: [Workout], maxRest: Int) -> [Workout] {
            workouts.filter { workout in
                guard restGatedSubtypes.contains(workout.subtype) else { return true }
                let restIntervals = workout.intervals.filter { $0.type == .recovery }
                if let firstRest = restIntervals.first {
                    return Int(firstRest.duration) <= maxRest
                }
                return true
            }
        }
        
        // Surprise weeks inject variety (shorter LR, threshold → progression
        // swap) to prevent staleness in long plans. For competitive plans
        // we suppress this — sub-3h / sub-1:30 athletes need consistent
        // progressive overload; variety comes from the workout selector's
        // duplicate penalty, not from disrupting the LR ladder.
        let isSurpriseWeek = surpriseWeeks.contains(week) && config.runnerLevel != .competitive

        // PEAK milestone cadence — computed at week scope so both the
        // pool gate AND the per-level selection logic below can read it.
        let milestoneCadence = max(3, peakDur / 2)
        let yassoWeek = phase == .peak && config.runnerLevel != .beginner && (weekInPhase % milestoneCadence) == 0
        let ttWeek    = phase == .peak && (weekInPhase % milestoneCadence) == milestoneCadence / 2

        let intervalPool: [Workout] = {
            var pool = filterIntervalsByMaxRest(filteredIntervals, maxRest: maxRestPerInterval)
            // Gate hill repeats: BASE and SPEED only (strength foundation,
            // then transition to race-specific). Skip the first week of
            // each phase so the runner adapts before adding hill stress.
            let hillsAllowed = (phase == .base || phase == .speed) && weekInPhase >= 1
            if !hillsAllowed {
                pool = pool.filter { $0.subtype != .hillRepeats }
            }

            // Gate Yasso 800s and Time Trials based on the milestone
            // cadence computed at week scope. Yasso is Int/Adv only;
            // TT runs for all levels. Cadence yields 2-3 of each per
            // PEAK cycle, never sharing a week.
            if !yassoWeek {
                pool = pool.filter { $0.subtype != .yasso800 }
            }
            if !ttWeek {
                pool = pool.filter { $0.subtype != .timeTrial }
            }

            // Minimum-duration floor by phase + level. Below the floor the
            // session is too short to engage VO2max/T-pace meaningfully
            // (Daniels: I-pace reps need 2-5min each; total session typically
            // 35-50min). Onboarding (BASE wks 0-2) gets the lighter floor;
            // race-PEAK pushes Int/Adv toward textbook 40-50min sessions.
            let isOnboarding = phase == .base && weekInPhase <= 1
            let minIntervalMinutes: Int = {
                if isMaintenance { return 20 }
                if isOnboarding { return 22 }
                switch (config.runnerLevel, phase) {
                case (.beginner, .base):    return 23
                case (.beginner, .speed):   return 28
                case (.beginner, .peak):    return 30
                case (.beginner, .taper):   return 25
                case (.intermediate, .base):  return 25
                case (.intermediate, .speed): return 32
                case (.intermediate, .peak):  return 38
                case (.intermediate, .taper): return 28
                case (.advanced, .base):    return 28
                case (.advanced, .speed):   return 38
                case (.advanced, .peak):    return 45
                case (.advanced, .taper):   return 30
                default: return 22
                }
            }()
            let filtered = pool.filter { $0.duration >= minIntervalMinutes * 60 }
            // Don't return an empty pool — fall back to full pool if the
            // floor excluded everything (catalog gap, not the user's
            // problem).
            return filtered.isEmpty ? pool : filtered
        }()
        
        // MAINTENANCE plan: dedicated gentle progression
        // Phases: Routine Setup → Base Building → Intensity Mix → Stability & Habit
        // Rules:
        //   - Easy runs start at 25min
        //   - No long runs first 4 weeks, no progression first 2 weeks
        //   - Long runs capped at 60min first 8 weeks, then very slowly grow (max ~90min, never 2h)
        //   - 1-2 easy intervals during first 8 weeks
        //   - Fewer progression runs overall
        //   - More interval/threshold variability in later stages
        if isMaintenance {
            // MAINTENANCE PLAN STRUCTURE
            //
            // Designed to (a) safely handle a runner coming off a marathon
            // block (post-race recovery) and (b) preserve race fitness
            // long-term (not just 2 easy runs/week).
            //
            // Weekly cadence:
            //   - Weeks 0-1: pure easy (recovery ramp from marathon, or
            //     "settle in" for fresh starts — harmless either way)
            //   - Every 4th week (weeks 5, 9, 13, ...): deload — easy only
            //   - All other weeks: 1 long + 1 quality (alternating
            //     interval/threshold) + easy fill, scaled to days/week
            //
            // Quality density: was 2-3 sessions per 12 weeks, now ~6-8
            // (every non-deload, non-recovery week gets quality + long).
            let isRecoveryRamp = week < 2
            let isDeloadWeek = week >= 4 && week % 4 == 1  // weeks 5, 9, 13, ...

            // Easy / progression duration progression
            let easyTargetMin = min(40, 25 + week / 6)
            let progTargetMin = min(50, 30 + week / 4)
            let progMaxMin = min(55, progTargetMin + 10)

            // Long run cap grows over time. Floor is 60min because the engine
            // enforces a 60min minimum on long runs catalog-wide; below that
            // we'd be filtering to an empty pool.
            let longRunMaxMinutes: Int
            if week < 4 {
                longRunMaxMinutes = 60
            } else if week < 8 {
                longRunMaxMinutes = 60 + (week - 4) * 3       // 60→72
            } else if week < 16 {
                longRunMaxMinutes = 75 + min((week - 8), 8)   // 75→83
            } else {
                longRunMaxMinutes = min(90, 83 + (week - 16) / 4)
            }

            let progressivePool = filterWorkoutsBySubtypeV3(workouts: allWorkouts, subtypes: [.progression])
                .filter { $0.duration >= 30 * 60 && $0.duration <= progMaxMin * 60 }
            let easyIntervalPool = intervalPool.filter { $0.duration <= 40 * 60 }
            let effectiveIntervalPool = easyIntervalPool.isEmpty ? intervalPool : easyIntervalPool
            let longPool = longRuns.filter { $0.duration >= 60 * 60 && $0.duration <= longRunMaxMinutes * 60 }

            if isRecoveryRamp {
                // Weeks 0-1: pure easy. Short durations. This doubles as
                // post-marathon recovery for runners coming off race blocks.
                for _ in 0..<maxWorkoutsPerWeek {
                    if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.4, targetDuration: 25, usedIds: &usedIds, isMaintenance: true) {
                        weekWorkouts.append(("easy_recovery", easy))
                    } else {
                        break
                    }
                }
            } else if isDeloadWeek {
                // Deload: easy runs only, no quality. Prevents accumulated
                // fatigue from the prior 3 quality weeks.
                for _ in 0..<maxWorkoutsPerWeek {
                    if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.35, targetDuration: easyTargetMin, usedIds: &usedIds, isMaintenance: true) {
                        weekWorkouts.append(("easy_deload", easy))
                    } else {
                        break
                    }
                }
            } else {
                // Regular maintenance week. Strategy depends on days/week:
                //
                // 2 days/wk (Beg): too few slots for long+quality same week.
                //   Alternate by week: odd = long+easy, even = quality+easy.
                //   Quality itself alternates interval/threshold week-to-week.
                //
                // 3+ days/wk (Int/Adv): 1 long + 1 quality + easy fill every
                //   regular week. Quality alternates interval/threshold.
                let useInterval = (week / 2) % 2 == 0  // alternate quality type per week
                let isLongWeek = week % 2 == 1          // for 2-day plans only

                let canFitBoth = maxWorkoutsPerWeek >= 3

                // LONG RUN
                let shouldAddLong = canFitBoth || isLongWeek
                if shouldAddLong, !longPool.isEmpty {
                    if let lr = selectWorkoutByTargetV3(workouts: longPool, targetLoad: targetLoad * 0.35, targetDuration: min(60, longRunMaxMinutes - 5), usedIds: &usedIds, isMaintenance: true) {
                        weekWorkouts.append(("long", lr))
                    }
                }

                // QUALITY (intervals or threshold)
                let shouldAddQuality = canFitBoth || !isLongWeek
                if shouldAddQuality, weekWorkouts.count < maxWorkoutsPerWeek {
                    if useInterval && !effectiveIntervalPool.isEmpty {
                        if let intv = selectWorkoutByTargetV3(workouts: effectiveIntervalPool, targetLoad: targetLoad * 0.3, targetDuration: 30, usedIds: &usedIds, previousWorkout: prevInterval, isDeloading: false, isMaintenance: true) {
                            weekWorkouts.append(("interval", intv))
                            prevInterval = intv
                        }
                    } else if !filteredThresholds.isEmpty {
                        if let th = selectWorkoutByTargetV3(workouts: filteredThresholds, targetLoad: targetLoad * 0.3, targetDuration: 35, usedIds: &usedIds, previousWorkout: prevThreshold, isDeloading: false, isMaintenance: true) {
                            weekWorkouts.append(("threshold", th))
                            prevThreshold = th
                        } else if let prog = selectWorkoutByTargetV3(workouts: progressivePool, targetLoad: targetLoad * 0.25, targetDuration: progTargetMin, usedIds: &usedIds, isMaintenance: true) {
                            // Threshold pool empty — fall back to progression
                            weekWorkouts.append(("progressive", prog))
                        }
                    }
                }

                // Optional progression slot for 3+ day weeks
                if maxWorkoutsPerWeek >= 3 && weekWorkouts.count < maxWorkoutsPerWeek {
                    if let prog = selectWorkoutByTargetV3(workouts: progressivePool, targetLoad: targetLoad * 0.25, targetDuration: progTargetMin, usedIds: &usedIds, isMaintenance: true) {
                        weekWorkouts.append(("progressive", prog))
                    }
                }
            }

            // Fill remaining slots with easy runs
            while weekWorkouts.count < maxWorkoutsPerWeek {
                if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.15, targetDuration: easyTargetMin, usedIds: &usedIds, isMaintenance: true) {
                    weekWorkouts.append(("easy_fill", easy))
                } else {
                    break
                }
            }

            // Cap strides at 1/week (same logic applied to race plans below)
            let stridesIdx = weekWorkouts.indices.filter { weekWorkouts[$0].workout.subtype == .strides }
            if stridesIdx.count > 1 {
                let plainEasy = easyRuns.filter { $0.subtype == .easy }
                for i in stridesIdx.dropFirst() {
                    let targetMin = Int(weekWorkouts[i].workout.duration / 60)
                    if let replacement = plainEasy.min(by: {
                        abs(Int($0.duration / 60) - targetMin) < abs(Int($1.duration / 60) - targetMin)
                    }) {
                        weekWorkouts[i] = (weekWorkouts[i].type, replacement)
                    }
                }
            }

            workoutsByWeek[week] = weekWorkouts
            continue
        }

        // RACE week: Skip quality workouts entirely.
        //
        // For plans with taperDur >= 2 (most 21K/42K plans), phase==.race is
        // explicitly returned for the last week of the plan. For shorter
        // plans (5K/10K) we keep taperDur=1 to preserve build time — there
        // the last week is technically phase==.taper, but it IS the race
        // week and needs the same hands-off treatment. Without this branch,
        // 5K/10K plans were ending with a 40min threshold or intervals
        // session 3-4 days before race day.
        let isLastWeekOfPlan = week == actualWeeksToGenerate - 1
        let isRaceWeek = phase == .race
            || (phase == .taper && isLastWeekOfPlan)
        if isRaceWeek {
            // Pfitz race week: 3-4 short sessions before race day, not 2.
            // 18/55 sub-3:00 race week: Tue 7mi tune-up, Wed 5mi w/MP repeats,
            // Thu 4mi easy, Fri 3mi easy, Sat 2mi shakeout, Sun RACE. That's
            // 4-5 sessions of running not counting the race. We compromise at
            // 3 sessions: 1 progression (tune-up), 1 easy + strides (Pfitz's
            // "MP repeats" idea), 1 short shakeout. Total ~120min — matches
            // Pfitz's ~25km race-week mileage at light pace.
            let numWorkouts = min(3, maxWorkoutsPerWeek)
            for i in 0..<numWorkouts {
                if i == 0 {
                    // First workout: progression run (short)
                    let progressivePool = filterWorkoutsBySubtypeV3(workouts: allWorkouts, subtypes: [.progression])
                        .filter { $0.duration >= 40 * 60 && $0.duration <= 50 * 60 }
                    if let progressive = selectWorkoutByTargetV3(workouts: progressivePool, targetLoad: targetLoad * 0.5, targetDuration: 45, usedIds: &usedIds, isMaintenance: isMaintenance) {
                        weekWorkouts.append(("progressive_race", progressive))
                    }
                } else if i == 2 {
                    // Final shakeout 1-2 days before race — short, very easy.
                    // Pfitz prescribes 20-30min of jogging + 4×100m strides.
                    let shakeoutPool = filterWorkoutsBySubtypeV3(workouts: allWorkouts, subtypes: easySubtypes)
                        .filter { $0.duration >= 20 * 60 && $0.duration <= 35 * 60 }
                    if let shakeout = selectWorkoutByTargetV3(workouts: shakeoutPool, targetLoad: targetLoad * 0.2, targetDuration: 25, usedIds: &usedIds, isMaintenance: isMaintenance) {
                        weekWorkouts.append(("shakeout_race", shakeout))
                    }
                } else {
                    // Second workout: easy run, hard-capped at 50min duration.
                    //
                    // The unbounded `targetDuration * 0.30` math works fine
                    // for shorter plans but for competitive 42K it lands
                    // around 90min — a 22km shake-out three days before a
                    // sub-3:00 marathon, which would crater the race itself.
                    // Pfitz 18/70 race week tops out at ~40min on its longest
                    // easy day.
                    //
                    // Two changes from a normal-week easy:
                    //   1. Pool: bypass the global competitive
                    //      `duration >= 60min` filter (which exists to enforce
                    //      the Pfitz MLR pattern in normal weeks). Race week
                    //      is the one place that filter is wrong.
                    //   2. Hard-filter the pool to `duration <= 50min` before
                    //      we hand it to the selector. Without this filter
                    //      the selector picks the 90-110min options because
                    //      they score better against the (still elevated)
                    //      race-week targetLoad — the duration target alone
                    //      doesn't win against load.
                    let raceEasyPool = filterWorkoutsBySubtypeV3(workouts: allWorkouts, subtypes: easySubtypes)
                        .filter { $0.duration <= 50 * 60 }
                    let raceEasyTarget = min(Int(targetDuration * 0.30), 40 * 60)
                    if let easy = selectWorkoutByTargetV3(workouts: raceEasyPool, targetLoad: targetLoad * 0.5, targetDuration: raceEasyTarget, usedIds: &usedIds, isMaintenance: isMaintenance) {
                        weekWorkouts.append(("easy_race", easy))
                    }
                }
            }
            // Skip all other workout selection for race week
            workoutsByWeek[week] = weekWorkouts
            continue
        }

        // INTERVALS & THRESHOLD
        var shouldAddIntervals = phase == .speed || phase == .peak || phase == .taper
        if !isBeginner && phase == .base {
            shouldAddIntervals = true // Intermediate/Advanced start intervals in Base
        }
        // TAPER: Still add intervals/threshold but at reduced intensity (handled by targetLoad)

        // Helper: Filter thresholds by progression (prefer shorter intervals early, longer later)
        func filterThresholdsByProgression(_ workouts: [Workout], week: Int, totalWeeks: Int) -> [Workout] {
            let progress = Double(week) / Double(max(totalWeeks - 1, 1))

            return workouts.filter { workout in
                let workIntervals = workout.intervals.filter { $0.type == .work }
                guard let firstWork = workIntervals.first else { return true }

                let intervalDuration = Int(firstWork.duration) / 60  // minutes
                let numIntervals = workIntervals.count

                // Early weeks (0-33%): Prefer 4-5 intervals of 6-8 mins
                if progress < 0.33 {
                    return numIntervals >= 4 && intervalDuration <= 8
                }
                // Mid weeks (33-66%): Prefer 3-4 intervals of 7-10 mins
                else if progress < 0.66 {
                    return numIntervals >= 3 && intervalDuration >= 7 && intervalDuration <= 10
                }
                // Late weeks (66%+): Prefer 2-3 intervals of 10-15 mins
                else {
                    return numIntervals <= 3 && intervalDuration >= 10
                }
            }
        }
        
        if shouldAddIntervals {
            if isBeginner {
                // Alternate: even weeks = intervals, odd = threshold.
                // On PEAK Time Trial weeks, prefer the TT subtype so the
                // selector doesn't lose it to standard intervals (Yasso
                // is gated out entirely for beginners).
                if week % 2 == 0 && !intervalPool.isEmpty {
                    let begPool: [Workout] = {
                        if phase == .peak && ttWeek {
                            let ttOnly = intervalPool.filter { $0.subtype == .timeTrial }
                            if !ttOnly.isEmpty { return ttOnly }
                        }
                        return intervalPool
                    }()
                    if let interval = selectWorkoutByTargetV3(workouts: begPool, targetLoad: targetLoad * 0.4, targetDuration: Int(targetDuration * 0.3), usedIds: &usedIds, previousWorkout: prevInterval, isDeloading: isDeloading, phaseJustStarted: phaseJustStarted, isMaintenance: isMaintenance) {
                        weekWorkouts.append(("interval", interval))
                        prevInterval = interval
                    }
                } else if !filteredThresholds.isEmpty {
                    // Apply progression filter to thresholds
                    let progressedThresholds = filterThresholdsByProgression(filteredThresholds, week: week, totalWeeks: actualWeeksToGenerate)
                    let thresholdPool = progressedThresholds.isEmpty ? filteredThresholds : progressedThresholds

                    if let threshold = selectWorkoutByTargetV3(workouts: thresholdPool, targetLoad: targetLoad * 0.4, targetDuration: Int(targetDuration * 0.35), usedIds: &usedIds, previousWorkout: prevThreshold, isDeloading: isDeloading, phaseJustStarted: phaseJustStarted, isMaintenance: isMaintenance) {
                        weekWorkouts.append(("threshold", threshold))
                        prevThreshold = threshold
                    }
                }
            } else {
                // Intermediate/Advanced: Always add intervals.
                //
                // BASE phase prefers hill repeats (Higdon Advanced 1 / Lydiard
                // strength foundation): hills build leg strength + power
                // without VO2max stress. Falls back to plain intervals if
                // no hills available. Hills alternate with other interval
                // work across BASE weeks for all non-beginner tiers — five
                // consecutive weeks of the same hill template reads as a
                // single workout on rotate, regardless of which methodology
                // we cite. The methodology citations (Higdon for Adv,
                // Pfitz for Cmp) survive at the level of "hills are in the
                // mix"; they do not require every BASE week to be hills.
                //   Int / Adv / Cmp: alternating BASE weeks.
                //   Beg:             no hills.
                let preferHillsThisWeek: Bool = {
                    guard phase == .base, weekInPhase >= 1 else { return false }
                    switch config.runnerLevel {
                    case .advanced, .competitive, .intermediate:
                        return weekInPhase % 2 == 1  // alternating
                    case .beginner:
                        return false
                    }
                }()
                let preferredPool: [Workout] = {
                    // PEAK milestone weeks: if the pool has the milestone
                    // subtype, prefer it so it doesn't lose the load
                    // competition to ladders/hills and get under-picked.
                    //
                    // Time Trials: ALL LEVELS. A race-effort fitness check
                    // is something beginners can absolutely do (tune-up
                    // 5K is standard advice).
                    //
                    // Yasso 800s: Int/Adv ONLY. 10×800m at I-pace with
                    // full recovery is hard interval work — Higdon Novice
                    // plans don't prescribe it because at beginner fitness
                    // the recovery between reps is brutal.
                    if phase == .peak && yassoWeek && config.runnerLevel != .beginner {
                        let yassosOnly = intervalPool.filter { $0.subtype == .yasso800 }
                        if !yassosOnly.isEmpty { return yassosOnly }
                    }
                    if phase == .peak && ttWeek {
                        let ttOnly = intervalPool.filter { $0.subtype == .timeTrial }
                        if !ttOnly.isEmpty { return ttOnly }
                    }
                    if preferHillsThisWeek {
                        let hillsOnly = intervalPool.filter { $0.subtype == .hillRepeats }
                        return hillsOnly.isEmpty ? intervalPool : hillsOnly
                    }
                    // BASE off-weeks (Int / Adv / Cmp): actively exclude
                    // hill repeats so the load-target selector doesn't keep
                    // picking them out of the unfiltered pool. Without
                    // exclusion hills win the off-weeks too (they score
                    // cleanly against BASE load targets), and the
                    // "alternating" rule is meaningless. This is what
                    // actually forces variety on the off-weeks.
                    let excludesHillsOnOffWeek = phase == .base
                        && config.runnerLevel != .beginner
                    if excludesHillsOnOffWeek {
                        let withoutHills = intervalPool.filter { $0.subtype != .hillRepeats }
                        if !withoutHills.isEmpty { return withoutHills }
                    }
                    return intervalPool
                }()

                if !preferredPool.isEmpty {
                    if let interval = selectWorkoutByTargetV3(workouts: preferredPool, targetLoad: targetLoad * 0.3, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, previousWorkout: prevInterval, isDeloading: isDeloading, phaseJustStarted: phaseJustStarted, isMaintenance: isMaintenance) {
                        weekWorkouts.append(("interval", interval))
                        prevInterval = interval
                    }
                }
                
                // Threshold in SPEED/PEAK only (not BASE)
                if phase == .speed || phase == .peak {
                    // Determine variation type for this week
                    let weekVariation = week % 5  // Cycle every 5 weeks for variety

                    if isSurpriseWeek {
                        // Surprise week: Replace threshold with progression run (intensity drop)
                        var progressivePool = filterWorkoutsBySubtypeV3(workouts: allWorkouts, subtypes: [.progression])
                            .filter { $0.duration >= 40 * 60 }
                        if config.distance < 42000 {
                            progressivePool = progressivePool.filter { $0.duration <= 70 * 60 }  // Cap at 1h10m for <42K
                        }
                        if let progressive = selectWorkoutByTargetV3(workouts: progressivePool, targetLoad: targetLoad * 0.25, targetDuration: Int(targetDuration * 0.30), usedIds: &usedIds, isMaintenance: isMaintenance) {
                            weekWorkouts.append(("progressive_surprise", progressive))
                        }
                    } else if weekVariation == 3 && !intervalPool.isEmpty {
                        // Every 5th week (week % 5 == 3): Double intervals instead of threshold.
                        // Exclude milestones (Yasso/TT) from the second slot so we
                        // don't end up with two milestone workouts in the same week —
                        // those are meant to be standalone benchmarks. Also exclude
                        // the subtype already picked in the first interval slot —
                        // doubling up on e.g. hill repeats in one week stacks the
                        // same fibres; variety is the whole reason we run two
                        // intervals here instead of interval+threshold.
                        let firstIntervalSubtype = weekWorkouts.last(where: { $0.type == "interval" })?.workout.subtype
                        let secondSlotPool = intervalPool.filter {
                            $0.subtype != .yasso800 &&
                            $0.subtype != .timeTrial &&
                            $0.subtype != firstIntervalSubtype
                        }
                        let pool2 = secondSlotPool.isEmpty ? intervalPool : secondSlotPool
                        if let interval2 = selectWorkoutByTargetV3(workouts: pool2, targetLoad: targetLoad * 0.25, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, previousWorkout: prevInterval, isDeloading: isDeloading, isMaintenance: isMaintenance) {
                            weekWorkouts.append(("interval2", interval2))
                        }
                    } else if !filteredThresholds.isEmpty {
                        // Normal week: Add threshold
                        let progressedThresholds = filterThresholdsByProgression(filteredThresholds, week: week, totalWeeks: actualWeeksToGenerate)
                        var thresholdPool = progressedThresholds.isEmpty ? filteredThresholds : progressedThresholds

                        // Competitive marathon PEAK weeks will fire a dedicated
                        // mp_quality slot below (the Pfitz Wednesday MP run).
                        // `.marathonPace` is also a member of `thresholdSubtypes`,
                        // so without this filter the threshold slot would
                        // happily pick a second MP workout — giving us two MP
                        // sessions plus the LR-with-MP in the same week, which
                        // is way over Pfitz's quality budget for peak. Drop MP
                        // from the threshold pool when the dedicated slot is
                        // about to fire, so the threshold slot picks a real
                        // threshold (or mile repeats, or 10K pace).
                        let mpQualitySlotWillFire = config.runnerLevel == .competitive
                            && phase == .peak
                            && config.distance >= 30000
                            && !isDeloading
                        if mpQualitySlotWillFire {
                            let withoutMP = thresholdPool.filter { $0.subtype != .marathonPace }
                            if !withoutMP.isEmpty { thresholdPool = withoutMP }
                        }

                        // Cmp 21K Pfitz LT-interval preference: on alternating
                        // SPEED/PEAK weeks, restrict the threshold pool to
                        // mileRepeats. Pfitz's signature sub-1:30 LT workout is
                        // 4-6 × 1mi @ HMP — the selector at default threshold
                        // targets tends to pick "Threshold Run (3 × 10min)"
                        // (continuous) over mileRepeats (interval). Result was
                        // 1 mile-rep session in 18 weeks; Pfitz prescribes 4-6.
                        // Forcing alternation gives Pfitz-style interval LT
                        // exposure on ~50% of SPEED/PEAK weeks, with
                        // continuous LT runs on the other half. Marathon Cmp
                        // unaffected (Pfitz 18/85 uses continuous tempo more
                        // than the half).
                        //
                        // Note: filterThresholdsByProgression excludes
                        // mileRepeats after ~33% of the plan (its 5min work
                        // intervals don't match the 7-15min late-phase
                        // preference). When forcing mileRepeats, bypass the
                        // progression filter and pull from the unfiltered
                        // `filteredThresholds` pool instead.
                        let preferMileRepeats = config.runnerLevel == .competitive
                            && config.distance == 21097
                            && (phase == .speed || phase == .peak)
                            && (week % 2 == 0)
                        if preferMileRepeats {
                            let mileRepsOnly = filteredThresholds.filter { $0.subtype == .mileRepeats }
                            if !mileRepsOnly.isEmpty { thresholdPool = mileRepsOnly }
                        }

                        // Int/Adv 42K Pfitz MP-volume preference: on alternating
                        // PEAK weeks, force marathonPace in the threshold slot.
                        // Pfitz 18/55 and 18/70 prescribe two MP exposures per
                        // PEAK week — one LR-with-MP, one dedicated MP run.
                        // Default selector at Int's baseLoad (8000) picked
                        // bigger threshold/mileRepeats over marathonPace
                        // (which has Z3 load values below threshold workouts).
                        // Adv: same issue — the dedicated "12mi @ MP" Pfitz
                        // workout never appeared, only the LR-with-MP carried
                        // MP volume. Forcing alternation gives Pfitz's two-MP-
                        // per-week pattern in PEAK without inventing a 3rd
                        // quality slot (back-to-back hard days problem). MP
                        // catalog entries are continuous (1 work interval) so
                        // they fail the progression filter — bypass that by
                        // pulling from `filteredThresholds`.
                        let preferMP = (config.runnerLevel == .intermediate
                                || config.runnerLevel == .advanced)
                            && config.distance == 42195
                            && phase == .peak
                            && (week % 2 == 0)
                        if preferMP {
                            let mpOnly = filteredThresholds.filter { $0.subtype == .marathonPace }
                            if !mpOnly.isEmpty { thresholdPool = mpOnly }
                        }

                        if let threshold = selectWorkoutByTargetV3(workouts: thresholdPool, targetLoad: targetLoad * 0.25, targetDuration: Int(targetDuration * 0.3), usedIds: &usedIds, previousWorkout: prevThreshold, isDeloading: isDeloading, phaseJustStarted: phaseJustStarted, isMaintenance: isMaintenance) {
                            weekWorkouts.append(("threshold", threshold))
                            prevThreshold = threshold
                        }
                    }
                }

                // Competitive marathon PEAK previously added a 3rd "mp_quality"
                // slot for dedicated 60-100min MP volume on top of the LR-
                // with-MP. With the PEAK MP-segment alternation (raceRehearsalM
                // every other week, lines ~1140-1170) the LR already carries
                // that MP volume on alternating weeks. Stacking a 3rd hard
                // session on top forces 3 quality workouts into a 5-day non-
                // long-run window — there is no placement that avoids back-
                // to-back hard days. Pfitz 18/55 and 18/85 both prescribe
                // 2 quality + LR-with-MP, not 3 + 1. Slot removed.
            }
        }

        // LONG RUN
        var shouldAddLong = true
        var longRunTypes: [WorkoutSubtype] = [.long, .steadyLong]

        if config.distance == 5000 {
            // 5K: Beg/Int get no long runs (5K is too short to warrant
            // marathon-style endurance work, and these tiers don't have
            // the aerobic base to absorb a weekly 75min LR).
            // Adv 5K: Daniels' Phase II prescribes optional ~75min long
            // runs on Sundays — pure aerobic base for the speed work.
            // Schedule LR in BASE/SPEED only; PEAK stays sharp/speed-focused.
            if config.runnerLevel == .advanced {
                longRunTypes = [.long, .steadyLong]
                shouldAddLong = (phase == .base || phase == .speed)
            } else {
                shouldAddLong = false
            }
        } else if config.distance == 10000 {
            if isBeginner {
                // 10K Beginner: weekly long run.
                // Older logic alternated (every other week) which reads as
                // missing-long-run-this-week noise in the calendar. Pfitz
                // and Higdon's beginner 10K plans both have weekly longs —
                // just shorter on cutback weeks. We get the cutback effect
                // naturally via phaseProgression / surprise weeks, so just
                // always schedule a long run in BASE/SPEED/PEAK.
                longRunTypes = [.long, .steadyLong]
                shouldAddLong = phase == .base || phase == .speed || phase == .peak
            } else {
                // 10K Intermediate/Advanced: regular long runs
                longRunTypes = [.long, .steadyLong]
                if phase == .base { shouldAddLong = true }
            }
        } else if config.distance >= 21000 {
            // 21K+ Beginner: all long run types, every week
            if isBeginner {
                longRunTypes = [.long, .steadyLong]
                shouldAddLong = phase == .base || phase == .speed || phase == .peak
            }
        }

        // SPEED + PEAK: add progressiveLong to the pool for variety.
        // progressiveLong workouts start at Z2 (aerobic) and finish at Z3 (MP)
        // — Pfitz's standard "progressive long run" prescription. Mixed into
        // the normal long-run rotation, they break up the wall-of-aerobic
        // pattern that pure steadyLong selection creates. BASE stays pure
        // aerobic per polarized-base methodology.
        //
        // Intermediate/Advanced/Competitive SPEED: on EVERY OTHER SPEED week
        // (even speedWeekIndex) force progressiveLong selection by removing
        // steadyLong/long from the pool. Three failure modes this prevents:
        //   1. Int half plans: at Int's low baseLoad (8000), the selector
        //      preferred light steadyLong workouts over progressives EVERY
        //      week. Result was 100% aerobic long runs — Int half runner
        //      never did any HMP work, ever. Pfitz Int half explicitly
        //      prescribes progressive long runs / tune-up races.
        //   2. Cmp build-band plans (eg. max, 36w): baseLoad scaled by
        //      18/totalWeeks dropped SPEED targets below where progressives
        //      match. Same symptom as Int.
        //   3. Any plan where SPEED target load happens to fall between
        //      catalog steadyLong and progressiveLong loads — selector
        //      defaults to steady.
        // Beg gets no forcing — Pfitz Beg "Just Finish" half IS pure-aerobic
        // by design (the runner can't yet handle race-pace volume).
        if phase == .speed || phase == .peak {
            longRunTypes.append(.progressiveLong)
            let needsSpeedProgressiveForcing = config.runnerLevel == .competitive
                || config.runnerLevel == .advanced
                || config.runnerLevel == .intermediate
            if phase == .speed && needsSpeedProgressiveForcing {
                let speedWeekIndex = week - baseDur
                if speedWeekIndex % 2 == 0 {
                    longRunTypes.removeAll { $0 == .steadyLong || $0 == .long }
                }
            }
        }

        // PEAK weeks: open the long-run pool to include the race-rehearsal
        // flavor matching the plan distance (10K → raceRehearsal10K,
        // 21K → raceRehearsalHM, 42K → raceRehearsalM). Each subtype's
        // eligibleDistances pins it to one race, so we just look up the
        // first matching subtype.
        if phase == .peak {
            for rehearsal: WorkoutSubtype in [.raceRehearsalM, .raceRehearsalHM, .raceRehearsal10K]
            where rehearsal.eligibleDistances.contains(config.distance) {
                longRunTypes.append(rehearsal)
            }
            // fastFinish: universal — long-ish easy + race-pace tail. The
            // catalog mixes 5K/10K/MP tails; load+duration matching picks
            // the right one for each plan. Skipped for competitive plans:
            // fastFinish caps at 100min, which is way short of the 160-200min
            // peak LR target competitive needs. Letting it into the pool
            // means the selector picks it as the "LR" because its load
            // matches better than a true 150-200min steadyLong, undercutting
            // peak volume — Pfitz never uses sub-100min LRs in marathon peak.
            if WorkoutSubtype.fastFinish.eligibleDistances.contains(config.distance)
                && config.runnerLevel != .competitive {
                longRunTypes.append(.fastFinish)
            }
            // Late PEAK for competitive: alternate MP-segment vs steady long
            // runs. Pfitz schedules 2-3 race rehearsals across a cycle, not
            // every PEAK week — pure exclusion of steadyLong starves the
            // selector and produces 5+ consecutive race rehearsals. Even
            // peakWeekIndex gets MP-segment (preferred); odd gets steady or
            // progressive (recovery aerobic week between hard race-pace
            // efforts). First PEAK week is always MP-segment.
            let peakWeekIndex = week - baseDur - speedDur
            if config.runnerLevel == .competitive && peakDur >= 3 {
                let isMPSegmentWeek = peakWeekIndex % 2 == 0 || peakWeekIndex == peakDur - 1
                if isMPSegmentWeek {
                    // Drop plain steady — force a race-rehearsal-style pick.
                    longRunTypes.removeAll { $0 == .steadyLong || $0 == .long }
                } else {
                    // Recovery aerobic week: drop the race-rehearsal types so
                    // selector picks plain steady (or progressive at most).
                    longRunTypes.removeAll {
                        $0 == .raceRehearsalM || $0 == .raceRehearsalHM || $0 == .raceRehearsal10K
                    }
                }
            } else if config.distance == 10000
                && (config.runnerLevel == .intermediate || config.runnerLevel == .advanced)
                && peakDur >= 2 {
                // Int/Adv 10K: alternate raceRehearsal10K (tune-up race
                // simulation) with plain steady in PEAK. Daniels and Pfitz
                // both prescribe a 5K tune-up race during 10K Phase II /
                // peak training. raceRehearsal10K exists in the catalog but
                // selector at default Int/Adv loads picks plain steadyLong
                // (or fastFinish — both have closer load matches) every
                // week. Forcing alternation guarantees the tune-up exposure.
                // First PEAK week is always tune-up; alternates thereafter.
                // Must also remove fastFinish from the pool on MP-segment
                // weeks — otherwise selector picks it over raceRehearsal10K
                // (similar load values, fastFinish has duration closer to
                // a typical 10K LR target).
                let isMPSegmentWeek = peakWeekIndex % 2 == 0
                if isMPSegmentWeek {
                    longRunTypes.removeAll {
                        $0 == .steadyLong || $0 == .long
                        || $0 == .progressiveLong || $0 == .fastFinish
                    }
                }
            } else if isBeginner && config.distance >= 21000 && peakDur >= 2 {
                // Beg 21K/42K: schedule one race rehearsal in mid-PEAK.
                // Pfitz "Just Finish" prescribes 1-2 race-pace tune-ups in
                // PEAK so the runner doesn't arrive at race day having never
                // run at goal pace. Without this, the selector picks steady
                // aerobic every week (load match dominates) and the runner
                // never gets a race-pace exposure. One rehearsal at the
                // midpoint is conservative — Pfitz Just Finish has more.
                let rehearsalWeekIdx = max(1, (peakDur - 1) / 2)
                if peakWeekIndex == rehearsalWeekIdx {
                    longRunTypes.removeAll { $0 == .steadyLong || $0 == .long || $0 == .progressiveLong }
                }
            }
        }
        
        // Surprise week: for short-race plans (5K/10K/21K) replace the long
        // run with an easy "surprise" run. For marathon, the user needs every
        // long run they can get in SPEED+PEAK — instead of skipping, just
        // shorten the long run cap so it still happens but lighter.
        var addedEasySurprise = false
        let isMarathon = config.distance >= 30000
        if isSurpriseWeek && !isBeginner && !isMarathon {
            if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.12, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, isMaintenance: isMaintenance) {
                weekWorkouts.append(("easy_surprise", easy))
                addedEasySurprise = true
            }
            shouldAddLong = false
        }
        
        if shouldAddLong && !longRuns.isEmpty {
            var pool = filterWorkoutsBySubtypeV3(workouts: longRuns, subtypes: longRunTypes)

            // Duration caps. Marathon/Half caps scale with level — Pfitzinger
            // 18/55 peaks at 22mi long runs; Higdon Int 1 marathon at 20mi.
            var maxDurationMins: Int
            switch config.distance {
            case 0: maxDurationMins = 90       // Maintenance: cap at 1h30m
            case 5000:
                // Adv 5K only — Beg/Int don't get LRs at all so cap is moot.
                // Daniels Phase II Adv 5K: ~75min Sunday long run.
                maxDurationMins = 75
            case 10000:
                // Per-tier 10K LR caps. Higdon Novice 10K LR ≈ 4 miles
                // (40-50 min); Higdon Int 10K ≈ 6 miles (~55-65 min);
                // Daniels/Pfitz Adv 10K ≈ 8-9 miles (~75-85 min).
                // Previous flat 80min was Higdon-Adv level for everyone —
                // way too long for a beginner (160% of Higdon Novice prescription).
                switch config.runnerLevel {
                // 60 is the floor — catalog's shortest long-run workout is
                // 60min. Below that the pool empties and the runner gets
                // zero LRs (breaks the "long run every build week" invariant).
                case .beginner: maxDurationMins = 60   // Higdon Novice 10K (real prescription is 40-50min, capped at catalog floor)
                case .intermediate: maxDurationMins = 75  // Higdon Int 10K
                case .advanced: maxDurationMins = 90   // Daniels/Pfitz Adv 10K (bumped to give visible step over 5K)
                case .competitive: maxDurationMins = 90
                }
            case 21097:
                // Pfitz half-specific LR caps. Half-marathoners don't need
                // 25-30km long runs (that's marathon-distance Daniels/Canova
                // endurance base). Pfitz tops each tier at:
                //   Just Finish (Beg):  10mi  = 16km = ~90min
                //   12-wk Int:          12mi  = 19km = ~100min
                //   12/47 high-mile:    13mi  = 21km = ~105min
                //   sub-1:30 elite:     14-15mi = 22-24km = ~110-115min
                switch config.runnerLevel {
                case .beginner: maxDurationMins = 90   // Pfitz Just Finish HM
                case .intermediate: maxDurationMins = 100  // Pfitz 12-wk HM
                case .advanced: maxDurationMins = 105  // Pfitz 12/47 HM
                case .competitive: maxDurationMins = 115  // Pfitz sub-1:30 HM
                }
            default:
                // Marathon long-run pool caps — keyed off the progression
                // peak targets (180/185/195/220) with ~10min slack to absorb
                // selector tolerance. Higdon Novice 1 peaks at 20mi (~180min),
                // Pfitz 18/55 at 22mi (~195min), Pfitz 18/70 at 22mi+,
                // Pfitz 18/85 (sub-3h) at 22mi (~220min).
                switch config.runnerLevel {
                case .beginner: maxDurationMins = 190
                case .intermediate: maxDurationMins = 200
                case .advanced: maxDurationMins = 210
                case .competitive: maxDurationMins = 220  // sub-3h: peak LR 32-36km (Pfitz 22-mile)
                }
            }
            // Marathon surprise weeks: shorten the long run instead of skipping
            // it (5d). 90min keeps the aerobic stimulus without the recovery cost.
            if isSurpriseWeek && isMarathon {
                maxDurationMins = min(maxDurationMins, 90)
            }
            pool = pool.filter { $0.duration <= maxDurationMins * 60 }

            // .competitive: filter out the lightest progressives. The catalog
            // has progressiveLong variants with Z3 work-interval content
            // ranging from 12% to 47%. At sub-3 / sub-1:30 training the
            // load+duration matcher tends to pick the LIGHTEST variants
            // (12-18% Z3) for SPEED-phase workouts, which leaves the total
            // long-run aerobic share around 85%. Pfitz competitive long runs
            // prescribe 25-40% MP volume per workout, not 12-18%. Excluding
            // the lightest variants forces the selector toward Pfitz-style
            // progressives, dropping aerobic share to ~80% by HR-zone time.
            // Other tiers keep the full pool (they need the lighter options).
            if config.runnerLevel == .competitive {
                pool = pool.filter { w in
                    if w.subtype != .progressiveLong { return true }
                    var workSec: Double = 0
                    var hardSec: Double = 0
                    for iv in w.intervals where iv.type == .work {
                        workSec += iv.duration
                        switch iv.target {
                        case .heartRateZone(let zone) where zone >= 3:
                            hardSec += iv.duration
                        case .paceTarget(_, let rel) where rel < 1.10:
                            hardSec += iv.duration
                        default:
                            break
                        }
                    }
                    return workSec > 0 && (hardSec / workSec) >= 0.25
                }
            }

            // Filter: ALL long runs (including progressive) must be >= 60 minutes
            let minLongRunMins = 60
            pool = pool.filter { workout in
                return workout.duration >= minLongRunMins * 60
            }

            // Progressive long-run target by distance + level + phase.
            //
            // Higdon Novice 1 marathon peaks at 20mi (~200min). Higdon Intermediate 1
            // marathon: 8→20mi. Pfitzinger 18/55: 16→22mi. We mirror this with
            // (start, peak) anchors per level — Beg/Int top out at 180/200, Adv at
            // 200 (catalog cap). Without explicit per-level targets, the load-
            // dominated workout selector picks short LRs even when targetDuration
            // is high (load match overrides duration match in selectWorkoutByTargetV3).
            let longRunTargetMins: Int
            let targetLongRunMins: Int

            // (basePhaseStart, speedPhaseEnd, peakPhaseEnd, taperVal)
            // nil = use initialLongRunDuration / non-progressive logic
            let progression: (base: Int, speed: Int, peak: Int, taper: Int)?
            if config.distance >= 30000 {
                // Marathon long-run peaks (per level):
                //   Higdon Novice 1 peaks at 20mi → ~180min for Beg
                //   Pfitz 18/55 peaks at 22mi    → ~195min for Int
                //   Pfitz 18/70 peaks at 22mi+   → ~210min for Adv
                //   Pfitz 18/85 (sub-3h)         → ~220min for Cmp (≈ Pfitz 22mi LR)
                // Earlier caps (150/165/180) were below Daniels' 150min novice
                // ceiling-style guidance but undershot Higdon/Pfitz references
                // we explicitly cite. Bumped to match: Beg→180, Int→185,
                // Adv→195, Cmp unchanged at 210.
                switch config.runnerLevel {
                case .beginner:     progression = (80, 120, 180, 90)
                case .intermediate: progression = (85, 130, 185, 95)
                case .advanced:     progression = (90, 140, 195, 105)
                case .competitive:  progression = (100, 160, 210, 110)  // sub-3h: peak 210min ≈ 22mi Pfitz LR
                }
            } else if config.distance >= 21000 {
                // Half marathon
                switch config.runnerLevel {
                case .beginner:     progression = (60, 90, 120, 60)
                case .intermediate: progression = (70, 100, 135, 70)
                case .advanced:     progression = (80, 110, 145, 80)
                // sub-1:30 HM: peak 145min — matches catalog ceiling for
                // raceRehearsalHM / progressiveLong (both max ~145m). 160m
                // was over Pfitz 12/47 peak (14mi ≈ 115m) anyway, just
                // produced a 15m monotonic regression at last PEAK week.
                case .competitive:  progression = (85, 125, 145, 90)
                }
            } else if config.distance >= 10000 {
                // 10K — competitive not offered, falls through to advanced.
                switch config.runnerLevel {
                case .beginner:     progression = (60, 70, 80, 60)
                case .intermediate: progression = (60, 70, 80, 60)
                case .advanced, .competitive: progression = (70, 75, 80, 70)
                }
            } else {
                // 5K and maintenance: keep prior behavior
                progression = nil
            }

            if let p = progression {
                switch phase {
                case .base:
                    targetLongRunMins = p.base
                case .speed:
                    let speedWeekIndex = week - baseDur
                    let speedProgress = Double(speedWeekIndex) / Double(max(speedDur - 1, 1))
                    targetLongRunMins = p.base + Int(Double(p.speed - p.base) * speedProgress)
                case .peak:
                    let peakWeekIndex = week - baseDur - speedDur
                    let peakProgress = Double(peakWeekIndex) / Double(max(peakDur - 1, 1))
                    targetLongRunMins = p.speed + Int(Double(p.peak - p.speed) * peakProgress)
                case .taper, .race:
                    targetLongRunMins = p.taper
                }
                longRunTargetMins = targetLongRunMins
                let toleranceMins = 15
                let filteredByTarget = pool.filter { abs(Int($0.duration) / 60 - targetLongRunMins) <= toleranceMins }
                if !filteredByTarget.isEmpty {
                    pool = filteredByTarget
                }
            } else {
                // 5K / maintenance: use initial range or weekly duration percentage
                if isBeginner {
                    longRunTargetMins = Int.random(in: config.initialLongRunDuration)
                } else {
                    longRunTargetMins = Int(targetDuration * 0.50)
                }
            }

            // LR load multiplier — bumped for competitive so the selector
            // prefers the 150-200min steadyLong / raceRehearsalM in PEAK
            // over shorter alternatives whose load happens to match the
            // default 0.35 multiplier. Without this, a 85min fastFinish
            // (load ~10700) wins against a 150min steadyLong (load ~14500)
            // even when the duration target is 160min.
            let lrLoadMult: Double = config.runnerLevel == .competitive ? 0.50 : 0.35
            // Monotonic enforcement. BASE/SPEED/PEAK: this week's LR may not
            // be meaningfully shorter than last week's (5min slack absorbs
            // selector noise / phase-target movement). TAPER + RACE: must
            // not be longer than last week's. First long run of plan skips.
            if prevLongRunMins > 0 {
                let monotonicPool: [Workout]
                switch phase {
                case .base, .speed, .peak:
                    let floor = max(0, prevLongRunMins - 5)
                    monotonicPool = pool.filter { Int($0.duration / 60) >= floor }
                case .taper, .race:
                    let ceiling = prevLongRunMins + 5
                    monotonicPool = pool.filter { Int($0.duration / 60) <= ceiling }
                }
                // Fall back to the unconstrained pool if the monotonic filter
                // empties it (catalog limit / aggressive phase target).
                if !monotonicPool.isEmpty { pool = monotonicPool }
            }
            if let longRun = selectWorkoutByTargetV3(workouts: pool, targetLoad: targetLoad * lrLoadMult, targetDuration: longRunTargetMins, usedIds: &usedIds, isMaintenance: isMaintenance) {
                weekWorkouts.append(("long", longRun))
                prevLongRunMins = Int(longRun.duration / 60)
            }
        }

        // Track if we added a long run
        let hasLongRun = weekWorkouts.contains { $0.workout.subtype == .long || $0.workout.subtype == .steadyLong }
        
        // EASY RUN (fills remaining slots)
        //
        // Daniels' rule of thumb: 70-80% of weekly volume should be easy. With
        // a 3-day/wk beginner plan that means 1 hard + 1 long + 1 EASY. The
        // previous logic defaulted this third slot to a progression run for
        // most level/distance combos, which collapsed the easy share to ~10%
        // empirically (per PLAN_GENERATION_ANALYSIS_2026.md). Flipped to
        // easy-by-default; progression is the occasional ~30% variant.
        if weekWorkouts.count < maxWorkoutsPerWeek {
            // Roughly 30% of weeks get progression instead of easy, so the
            // overall E:P split sits around 70/30 in line with Daniels.
            let progressionWeek = (week % 3 == 0)

            if config.distance == 5000 && config.runnerLevel == .advanced {
                // 5K Advanced: easy in BASE; SPEED/PEAK alternates ~70% easy / 30% progression.
                if phase == .base || !progressionWeek {
                    if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.15, targetDuration: Int(targetDuration * 0.30), usedIds: &usedIds, isMaintenance: isMaintenance) {
                        weekWorkouts.append(("easy", easy))
                    }
                } else {
                    let progressivePool = filterWorkoutsBySubtypeV3(workouts: allWorkouts, subtypes: [.progression])
                        .filter { $0.duration >= 40 * 60 }
                    if let progressive = selectWorkoutByTargetV3(workouts: progressivePool, targetLoad: targetLoad * 0.20, targetDuration: Int(targetDuration * 0.35), usedIds: &usedIds, isMaintenance: isMaintenance) {
                        weekWorkouts.append(("progressive", progressive))
                    } else if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.15, targetDuration: Int(targetDuration * 0.30), usedIds: &usedIds, isMaintenance: isMaintenance) {
                        weekWorkouts.append(("easy", easy))
                    }
                }
            } else if config.runnerLevel == .advanced {
                // Non-5K Advanced: easy by default; progression every 3rd week.
                if !progressionWeek {
                    if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.15, targetDuration: Int(targetDuration * 0.30), usedIds: &usedIds, isMaintenance: isMaintenance) {
                        weekWorkouts.append(("easy", easy))
                    }
                } else {
                    var progressivePool = filterWorkoutsBySubtypeV3(workouts: allWorkouts, subtypes: [.progression])
                        .filter { $0.duration >= 40 * 60 }
                    if config.distance < 42000 {
                        progressivePool = progressivePool.filter { $0.duration <= 70 * 60 }
                    }
                    if let progressive = selectWorkoutByTargetV3(workouts: progressivePool, targetLoad: targetLoad * 0.20, targetDuration: Int(targetDuration * 0.30), usedIds: &usedIds, isMaintenance: isMaintenance) {
                        weekWorkouts.append(("progressive", progressive))
                    } else if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.15, targetDuration: Int(targetDuration * 0.30), usedIds: &usedIds, isMaintenance: isMaintenance) {
                        weekWorkouts.append(("easy", easy))
                    }
                }
            } else if !easyRuns.isEmpty {
                // Intermediate / Beginner: easy by default. Intermediates get
                // an occasional progression in SPEED/PEAK for variety.
                if config.runnerLevel == .intermediate && (phase == .speed || phase == .peak) && progressionWeek {
                    var progressivePool = filterWorkoutsBySubtypeV3(workouts: allWorkouts, subtypes: [.progression])
                        .filter { $0.duration >= 40 * 60 }
                    if config.distance < 42000 {
                        progressivePool = progressivePool.filter { $0.duration <= 70 * 60 }
                    }
                    if let progressive = selectWorkoutByTargetV3(workouts: progressivePool, targetLoad: targetLoad * 0.18, targetDuration: Int(targetDuration * 0.30), usedIds: &usedIds, isMaintenance: isMaintenance) {
                        weekWorkouts.append(("progressive_variety", progressive))
                    } else if !addedEasySurprise, let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.15, targetDuration: Int(targetDuration * 0.30), usedIds: &usedIds, isMaintenance: isMaintenance) {
                        weekWorkouts.append(("easy", easy))
                    }
                } else if config.distance >= 10000 && isBeginner && progressionWeek {
                    // 10K+ beginner: progression every 3rd week with growing
                    // duration — non-progression weeks fall through to easy.
                    let progressionTargetMins: Int
                    if config.distance >= 21000 {
                        // 21K+: Progress from 40 → 90 mins (can go up to 3 hours)
                        switch phase {
                        case .base:
                            progressionTargetMins = 40
                        case .speed:
                            let speedWeekIndex = week - baseDur
                            let speedProgress = Double(speedWeekIndex) / Double(max(speedDur - 1, 1))
                            progressionTargetMins = 40 + Int(25.0 * speedProgress)  // 40→65
                        case .peak:
                            let peakWeekIndex = week - baseDur - speedDur
                            let peakProgress = Double(peakWeekIndex) / Double(max(peakDur - 1, 1))
                            progressionTargetMins = 65 + Int(25.0 * peakProgress)  // 65→90
                        case .taper, .race:
                            progressionTargetMins = 40
                        }
                    } else {
                        // 10K: Progress from 40 → 50 mins
                        switch phase {
                        case .base:
                            progressionTargetMins = 40
                        case .speed, .peak:
                            let progressWeek = week - baseDur
                            let totalProgressWeeks = speedDur + peakDur
                            let progress = Double(progressWeek) / Double(max(totalProgressWeeks - 1, 1))
                            progressionTargetMins = 40 + Int(10.0 * progress)
                        case .taper, .race:
                            progressionTargetMins = 40
                        }
                    }

                    // Filter for progression runs within ±10 mins of target, minimum 40 mins
                    var progressivePool = filterWorkoutsBySubtypeV3(workouts: allWorkouts, subtypes: [.progression])
                        .filter { $0.duration >= 40 * 60 }  // Minimum 40 mins
                        .filter { abs(Int($0.duration) / 60 - progressionTargetMins) <= 10 }
                    if config.distance < 42000 {
                        progressivePool = progressivePool.filter { $0.duration <= 70 * 60 }  // Cap at 1h10m for <42K
                    }
                    if let progressive = selectWorkoutByTargetV3(workouts: progressivePool, targetLoad: targetLoad * 0.18, targetDuration: progressionTargetMins, usedIds: &usedIds, isMaintenance: isMaintenance) {
                        weekWorkouts.append(("progressive_beginner", progressive))
                    } else if !addedEasySurprise, let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.15, targetDuration: Int(targetDuration * 0.30), usedIds: &usedIds, isMaintenance: isMaintenance) {
                        weekWorkouts.append(("easy", easy))
                    }
                } else if config.distance == 5000 && isBeginner {
                    // 5K beginner: Add short progression runs in week 2 and second half
                    let shouldAddProgression = (week == 1) || (week >= actualWeeksToGenerate / 2 && week % 3 == 0)
                    if shouldAddProgression {
                        // Short progression runs (40-50 mins)
                        let progressivePool = filterWorkoutsBySubtypeV3(workouts: allWorkouts, subtypes: [.progression])
                            .filter { $0.duration >= 40 * 60 && $0.duration <= 50 * 60 }
                        if let progressive = selectWorkoutByTargetV3(workouts: progressivePool, targetLoad: targetLoad * 0.15, targetDuration: 45, usedIds: &usedIds, isMaintenance: isMaintenance) {
                            weekWorkouts.append(("progressive_5k_beginner", progressive))
                        } else if !addedEasySurprise, let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.15, targetDuration: Int(targetDuration * 0.30), usedIds: &usedIds, isMaintenance: isMaintenance) {
                            weekWorkouts.append(("easy", easy))
                        }
                    } else {
                        // Regular easy run
                        if !addedEasySurprise, let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.15, targetDuration: Int(targetDuration * 0.30), usedIds: &usedIds, isMaintenance: isMaintenance) {
                            weekWorkouts.append(("easy", easy))
                        }
                    }
                } else {
                    // Default: easy run (fill remaining slots).
                    // Competitive plans bump the load multiplier from 0.15
                    // to 0.30 so the selector targets ~6000 load (matches
                    // 80-90min easies) instead of ~3000 (matches the now-
                    // filtered-out 60min easies). Without this, every
                    // competitive PEAK week was picking the same 60min
                    // easy 5+ times despite having longer options.
                    //
                    // TAPER + RACE override: competitive plans should drop
                    // to short easy runs (30-50min) — Pfitz tapers easy-day
                    // duration along with everything else. Without this
                    // override, the >= 60min filter forces 80-110min easies
                    // through to race week, blowing past the taper target
                    // (W17 was landing at ~510min vs ~370min target).
                    let isTaperingDown = config.runnerLevel == .competitive
                        && (phase == .taper || phase == .race)
                    let easyLoadMult: Double
                    let easyPool: [Workout]
                    let easyTargetDur: Int
                    if isTaperingDown {
                        let taperCapMins = phase == .race ? 35 : 50
                        easyLoadMult = 0.10
                        easyPool = filterWorkoutsBySubtypeV3(workouts: allWorkouts, subtypes: easySubtypes)
                            .filter { $0.duration <= taperCapMins * 60 }
                        easyTargetDur = phase == .race ? 25 : 40
                    } else if config.runnerLevel == .competitive {
                        easyLoadMult = 0.30
                        easyPool = easyRuns
                        easyTargetDur = Int(targetDuration * 0.30)
                    } else {
                        easyLoadMult = 0.15
                        easyPool = easyRuns
                        easyTargetDur = Int(targetDuration * 0.30)
                    }

                    // Force mediumLong on alternating midweek slots for Pfitz-
                    // style plans. Without this, the generator picks generic
                    // `easy` (60-80min) over `mediumLong` (85-110min) because
                    // of duration matching at lower target loads. Pfitz 18/55
                    // (marathon) and the HM 47-63 / 63-77 mi/wk plans both
                    // explicitly prescribe a Wed/Thu Medium-Long Run; we
                    // guarantee at least one per fortnight in serious plans.
                    // Marathon + half-marathon, Int/Adv/Cmp tiers. Beg plans
                    // excluded (Higdon Novice doesn't prescribe MLR). 10K/5K
                    // excluded (pool is 85+min, too long for those targets).
                    let isMarathonOrHM = (config.distance == 42195 || config.distance == 21097)
                    let isIntOrAbove = (config.runnerLevel == .intermediate
                                        || config.runnerLevel == .advanced
                                        || config.runnerLevel == .competitive)
                    let prefersMediumLong = isMarathonOrHM && isIntOrAbove
                        && phase != .taper && phase != .race
                        && week % 2 == 0
                    var finalPool = easyPool
                    if prefersMediumLong {
                        let mlOnly = easyPool.filter { $0.subtype == .mediumLong }
                        if !mlOnly.isEmpty { finalPool = mlOnly }
                    }

                    if let easy = selectWorkoutByTargetV3(workouts: finalPool, targetLoad: targetLoad * easyLoadMult, targetDuration: easyTargetDur, usedIds: &usedIds, isMaintenance: isMaintenance) {
                        weekWorkouts.append(("easy", easy))
                    }
                }
            }
        }
        
        // BASE phase extra workout
        if phase == .base && weekWorkouts.count < maxWorkoutsPerWeek {
            if config.runnerLevel == .advanced {
                if config.distance == 5000 {
                    // 5K Advanced: Add progression run in BASE (no long runs for 5K)
                    let progressivePool = filterWorkoutsBySubtypeV3(workouts: allWorkouts, subtypes: [.progression])
                        .filter { $0.duration >= 40 * 60 && $0.duration <= 50 * 60 }
                    if let progressive = selectWorkoutByTargetV3(workouts: progressivePool, targetLoad: targetLoad * 0.15, targetDuration: 45, usedIds: &usedIds, isMaintenance: isMaintenance) {
                        weekWorkouts.append(("progressive_base_5k", progressive))
                    }
                } else if config.distance >= 21000 {
                    // 21K+ Advanced: Add progression or easy (NOT long run - max 1 per week)
                    if !hasLongRun {
                        // Only add a long run if we don't already have one
                        let filteredLong = filterWorkoutsBySubtypeV3(workouts: allWorkouts, subtypes: [.long, .steadyLong])
                            .filter { $0.duration >= 60 * 60 && $0.duration <= 80 * 60 }
                        if let longRun = selectWorkoutByTargetV3(workouts: filteredLong, targetLoad: targetLoad * 0.15, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, isMaintenance: isMaintenance) {
                            weekWorkouts.append(("long_base", longRun))
                        }
                    } else {
                        // Already have a long run, add progression instead
                        let progressivePool = filterWorkoutsBySubtypeV3(workouts: allWorkouts, subtypes: [.progression])
                            .filter { $0.duration >= 40 * 60 && $0.duration <= 70 * 60 }
                        if let progressive = selectWorkoutByTargetV3(workouts: progressivePool, targetLoad: targetLoad * 0.15, targetDuration: 50, usedIds: &usedIds, isMaintenance: isMaintenance) {
                            weekWorkouts.append(("progressive_base", progressive))
                        } else if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.15, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, isMaintenance: isMaintenance) {
                            weekWorkouts.append(("easy_base", easy))
                        }
                    }
                } else {
                    // 10K Advanced: Add easy or progression (NOT long run - max 1 per week)
                    let progressivePool = filterWorkoutsBySubtypeV3(workouts: allWorkouts, subtypes: [.progression])
                        .filter { $0.duration >= 40 * 60 && $0.duration <= 70 * 60 }  // Cap at 1h10m
                    if let progressive = selectWorkoutByTargetV3(workouts: progressivePool, targetLoad: targetLoad * 0.15, targetDuration: 50, usedIds: &usedIds, isMaintenance: isMaintenance) {
                        weekWorkouts.append(("progressive_base", progressive))
                    } else if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.15, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, isMaintenance: isMaintenance) {
                        weekWorkouts.append(("easy_base", easy))
                    }
                }
            } else if config.runnerLevel == .intermediate {
                // Add progression run (40+ mins, cap at 1h10m for <42K)
                var progressivePool = filterWorkoutsBySubtypeV3(workouts: allWorkouts, subtypes: [.progression])
                    .filter { $0.duration >= 40 * 60 }
                if config.distance < 42000 {
                    progressivePool = progressivePool.filter { $0.duration <= 70 * 60 }
                }
                if let progressive = selectWorkoutByTargetV3(workouts: progressivePool, targetLoad: targetLoad * 0.15, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, isMaintenance: isMaintenance) {
                    weekWorkouts.append(("progressive_base", progressive))
                }
            } else if config.runnerLevel == .competitive {
                // Competitive: add a medium-long easy (60-90min) for Pfitz-style
                // weekly volume. The beginner fallback below targets load * 0.10
                // (~2000) which pulls in short strides instead of long easies.
                // Competitive needs the higher load target.
                if !addedEasySurprise, let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.25, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, isMaintenance: isMaintenance) {
                    weekWorkouts.append(("easy", easy))
                }
            } else {
                // Beginner: add easy run
                if !addedEasySurprise, let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.10, targetDuration: Int(targetDuration * 0.20), usedIds: &usedIds, isMaintenance: isMaintenance) {
                    weekWorkouts.append(("easy", easy))
                }
            }
        }

        // Fill remaining slots for advanced runners (5 workouts for 21K+, 4 for others)
        while weekWorkouts.count < maxWorkoutsPerWeek {
            if config.runnerLevel == .advanced {
                if config.distance == 5000 {
                    // 5K Advanced: Add easy run
                    if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.10, targetDuration: Int(targetDuration * 0.20), usedIds: &usedIds, isMaintenance: isMaintenance) {
                        weekWorkouts.append(("easy_fill", easy))
                    } else {
                        break  // No more workouts available
                    }
                } else if config.distance >= 21000 {
                    // 21K+ Advanced: Alternate between progression and easy
                    if weekWorkouts.count % 2 == 1 {
                        var progressivePool = filterWorkoutsBySubtypeV3(workouts: allWorkouts, subtypes: [.progression])
                            .filter { $0.duration >= 40 * 60 }
                        // Cap progressions for all distances
                        if config.distance < 42000 {
                            progressivePool = progressivePool.filter { $0.duration <= 70 * 60 }  // 1h10m max for 21K
                        }
                        if let progressive = selectWorkoutByTargetV3(workouts: progressivePool, targetLoad: targetLoad * 0.10, targetDuration: 50, usedIds: &usedIds, isMaintenance: isMaintenance) {
                            weekWorkouts.append(("progressive_fill", progressive))
                        } else if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.10, targetDuration: Int(targetDuration * 0.20), usedIds: &usedIds, isMaintenance: isMaintenance) {
                            weekWorkouts.append(("easy_fill", easy))
                        } else {
                            break
                        }
                    } else {
                        if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.10, targetDuration: Int(targetDuration * 0.20), usedIds: &usedIds, isMaintenance: isMaintenance) {
                            weekWorkouts.append(("easy_fill", easy))
                        } else {
                            break
                        }
                    }
                } else {
                    // 10K Advanced: Add easy run
                    if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.10, targetDuration: Int(targetDuration * 0.20), usedIds: &usedIds, isMaintenance: isMaintenance) {
                        weekWorkouts.append(("easy_fill", easy))
                    } else {
                        break
                    }
                }
            } else {
                // Beginner / Intermediate: fill remaining trainingDays with
                // easy runs. Used to bail here, leaving days unscheduled —
                // major reason marathon plans were ~30% under Higdon volume.
                //
                // For 21K+ we prefer a longer easy ("medium-long" Pfitz-style)
                // for the first fill slot so weekly volume actually grows
                // when trainingDays.count is 4+.
                let isLongRace = config.distance >= 21000
                let isFirstFill = !weekWorkouts.contains { $0.type.contains("fill") }
                let isCompetitive = config.runnerLevel == .competitive
                // Competitive plans drop the Pfitz-MLR sizing in TAPER + RACE.
                // The weekday MLR pattern is correct for BASE/SPEED/PEAK
                // (sub-3 fitness comes from total easy volume), but tapering
                // means shorter easy runs all around — Pfitz's race week
                // easies are 30-45min, not 80-110.
                let isTaperingDown = isCompetitive && (phase == .taper || phase == .race)
                let easyTargetMin: Int = {
                    if isTaperingDown {
                        return phase == .race ? 30 : 40
                    } else if isLongRace && isFirstFill {
                        return min(90, max(60, Int(targetDuration * 0.30)))
                    } else if isCompetitive {
                        return min(90, max(60, Int(targetDuration * 0.25)))
                    } else {
                        return min(60, max(35, Int(targetDuration * 0.22)))
                    }
                }()
                // Per-slot LOAD multipliers determine which workout the
                // selector picks (load match dominates the score). Defaults
                // (0.18 MLR, 0.12 fill) target ~3600 / ~2400 load — which
                // for a sub-3h runner matches 50min / 25min easies, not the
                // 60-90min Pfitz MLR pattern. Competitive scales these up
                // so the selector lands on the long easies the catalog has.
                let mlrLoadMult = isCompetitive ? 0.33 : 0.18
                let fillLoadMult = isCompetitive ? 0.23 : 0.12
                let easyTargetLoad: Double
                if isTaperingDown {
                    easyTargetLoad = targetLoad * 0.08
                } else {
                    easyTargetLoad = targetLoad * (isLongRace && isFirstFill ? mlrLoadMult : fillLoadMult)
                }
                // Hard-cap easy duration for tapering competitive plans
                // so the selector can't pick a 60-90min MLR-sized workout
                // even when load scoring would otherwise prefer it.
                let easyPool: [Workout]
                if isTaperingDown {
                    let taperCapMins = phase == .race ? 35 : 50
                    easyPool = filterWorkoutsBySubtypeV3(workouts: allWorkouts, subtypes: easySubtypes)
                        .filter { $0.duration <= taperCapMins * 60 }
                } else {
                    easyPool = easyRuns
                }
                if let easy = selectWorkoutByTargetV3(workouts: easyPool, targetLoad: easyTargetLoad, targetDuration: easyTargetMin, usedIds: &usedIds, isMaintenance: isMaintenance) {
                    weekWorkouts.append((isLongRace && isFirstFill ? "medium_long_fill" : "easy_fill", easy))
                } else {
                    break  // Catalog exhausted
                }
            }
        }

        // Cap strides at 1/week — Daniels prescribes ~2/week max but with
        // 5-day plans that becomes excessive. Replace any extra strides with
        // the closest-duration plain easy run. Use the UNFILTERED easy pool
        // here — the competitive >= 60min filter applied to `easyRuns` would
        // otherwise force taper strides to be replaced with 60min easies,
        // wrecking the taper volume target.
        let stridesIndices = weekWorkouts.indices.filter { weekWorkouts[$0].workout.subtype == .strides }
        if stridesIndices.count > 1 {
            let plainEasy = filterWorkoutsBySubtypeV3(workouts: allWorkouts, subtypes: [.easy])
            for i in stridesIndices.dropFirst() {
                let targetMin = Int(weekWorkouts[i].workout.duration / 60)
                if let replacement = plainEasy.min(by: {
                    abs(Int($0.duration / 60) - targetMin) < abs(Int($1.duration / 60) - targetMin)
                }) {
                    weekWorkouts[i] = (weekWorkouts[i].type, replacement)
                }
            }
        }

        workoutsByWeek[week] = weekWorkouts
    }

    // Trim early weeks if plan was too short
    if weeksToTrim > 0 {
        var trimmedPlan: [Int: [(type: String, workout: Workout)]] = [:]
        for (week, workouts) in workoutsByWeek {
            if week >= weeksToTrim {
                trimmedPlan[week - weeksToTrim] = workouts
            }
        }
        return trimmedPlan
    }
    
    return workoutsByWeek
}

// MARK: - Integration with existing createMarathonPlan

public func createMarathonPlanV3(startDate: Date, raceDate: Date, from workouts: [Workout], planId: UUID, config: PlanConfiguration) -> [WorkoutEvent] {
    let calendar = Calendar.current
    let normalizedStartDate = calendar.startOfDay(for: startDate)
    let normalizedRaceDate = calendar.startOfDay(for: raceDate)
    
    let components = calendar.dateComponents([.day], from: normalizedStartDate, to: normalizedRaceDate)
    guard let days = components.day, days > 0 else {
        return []
    }
    
    let totalWeeks = Int(max(1, ceil(Double(days) / 7)))
    
    // Generate plan using Python-ported logic
    let planByWeek = simulatePlanV3(config: config, totalWeeks: totalWeeks, allWorkouts: workouts)
    
    var events: [WorkoutEvent] = []
    
    // Convert to WorkoutEvents
    for (weekIndex, weekWorkouts) in planByWeek.sorted(by: { $0.key < $1.key }) {
        let weekStartDate = calendar.date(byAdding: .weekOfYear, value: weekIndex, to: normalizedStartDate)!

        // Assign workouts to training days
        let trainingDays = config.trainingDays.sorted()

        // Sort workouts: long runs on longestWorkoutDay, others distributed
        var assignedWorkouts: [(workout: Workout, dayOfWeek: Int)] = []
        var remainingDays = trainingDays
        var remainingWorkouts = weekWorkouts

        // Assign long run to longest day
        if let longIndex = remainingWorkouts.firstIndex(where: { $0.type.contains("long") }) {
            let longRun = remainingWorkouts.remove(at: longIndex)
            assignedWorkouts.append((workout: longRun.workout, dayOfWeek: config.longestWorkoutDay))
            remainingDays.removeAll { $0 == config.longestWorkoutDay }
        }

        // Smart workout assignment: interleave hard and easy workouts
        // Key insight: Speed workouts (intervals, threshold) should have easy workouts between them
        // Pattern: Intervals → Easy → Threshold → Long Run

        // Helper to check if a workout is "hard" (speed/quality work).
        // Slot types come from per-week scheduling above; must include EVERY
        // physiologically-quality slot label or the day scheduler will place
        // it next to other hard sessions. Marathon-pace sustained efforts
        // (`mp_quality` slot, also `marathonPace` if it appears in titles)
        // count as quality even though they sit at Z3 rather than Z4-Z5.
        func isHardWorkout(_ tuple: (type: String, workout: Workout)) -> Bool {
            tuple.type.contains("interval") ||
            tuple.type.contains("threshold") ||
            tuple.type.contains("speed") ||
            tuple.type.contains("tempo") ||
            tuple.type.contains("mp_quality") ||
            tuple.type.contains("yasso") ||
            tuple.type.contains("time_trial") ||
            tuple.type.contains("mile_repeats") ||
            tuple.type.contains("hill")
        }

        // Split workouts into hard and easy categories
        var hardWorkouts = remainingWorkouts.filter { isHardWorkout($0) }
        var easyWorkouts = remainingWorkouts.filter { !isHardWorkout($0) }

        // Sort remaining days chronologically
        let sortedDays = remainingDays.sorted()

        // Build interleaved pattern: alternate hard and easy workouts
        // This ensures speed workouts are spread out with recovery between them
        var interleaved: [(type: String, workout: Workout)] = []

        if hardWorkouts.count >= easyWorkouts.count {
            // More or equal hard than easy: H, E, H, E, H...
            while !hardWorkouts.isEmpty || !easyWorkouts.isEmpty {
                if !hardWorkouts.isEmpty {
                    interleaved.append(hardWorkouts.removeFirst())
                }
                if !easyWorkouts.isEmpty {
                    interleaved.append(easyWorkouts.removeFirst())
                }
            }
        } else {
            // More easy than hard: E, H, E, H, E...
            while !hardWorkouts.isEmpty || !easyWorkouts.isEmpty {
                if !easyWorkouts.isEmpty {
                    interleaved.append(easyWorkouts.removeFirst())
                }
                if !hardWorkouts.isEmpty {
                    interleaved.append(hardWorkouts.removeFirst())
                }
            }
        }

        // Assign interleaved workouts to sorted days.
        //
        // 5e: avoid scheduling a hard workout on the day immediately before
        // or after the long run. The interleaved order may put a hard
        // workout in a slot adjacent to the long-run day; if so, swap it
        // with the next non-adjacent day. This prevents back-to-back
        // hard/long sessions which compromise long-run quality and recovery.
        //
        // For maintenance plans: also rotate which day gets the hard workout
        // each week so intervals/thresholds don't always land on the same weekday.
        var dayToWorkout: [Int: (type: String, workout: Workout)] = [:]
        let isMaintPlan = config.distance == 0
        let longRunDay = config.longestWorkoutDay
        let adjacentDays: Set<Int> = [longRunDay - 1, longRunDay + 1]

        let dayOrder: [Int]
        if isMaintPlan && sortedDays.count > 1 {
            dayOrder = Array(sortedDays.suffix(from: weekIndex % sortedDays.count))
                     + Array(sortedDays.prefix(weekIndex % sortedDays.count))
        } else {
            dayOrder = sortedDays
        }

        // First pass: place workouts in their interleaved slots.
        for (index, day) in dayOrder.enumerated() where index < interleaved.count {
            dayToWorkout[day] = interleaved[index]
        }

        // Second pass: if a hard workout landed adjacent to the long-run day
        // try to swap it with a far easy workout. But the swap must NOT
        // create a new consecutive-hard-days pair — moving a hard workout
        // off Sat onto Wed when Thu is already hard would put two hard days
        // back-to-back, which is exactly the placement we are trying to avoid.
        // So we test each candidate easy-day before swapping.
        if assignedWorkouts.contains(where: { $0.dayOfWeek == longRunDay }) {
            let hardOnAdjacentDay = dayToWorkout.first { day, tuple in
                adjacentDays.contains(day) && isHardWorkout(tuple)
            }
            if let (adjDay, adjTuple) = hardOnAdjacentDay {
                // Helper: would moving `tuple` to `targetDay` create a hard-
                // hard adjacency? (Checks targetDay-1 and targetDay+1.)
                func wouldCreateConsecutiveHard(targetDay: Int, movingHard: (type: String, workout: Workout)) -> Bool {
                    let neighbors = [targetDay - 1, targetDay + 1]
                    for n in neighbors where n != adjDay {  // adjDay will become easy after swap
                        if let nTuple = dayToWorkout[n], isHardWorkout(nTuple) {
                            return true
                        }
                    }
                    return false
                }
                // Find a far easy day whose swap doesn't create consecutive hard.
                let safeFarEasy = dayToWorkout.first { day, tuple in
                    !adjacentDays.contains(day)
                        && day != adjDay
                        && !isHardWorkout(tuple)
                        && !wouldCreateConsecutiveHard(targetDay: day, movingHard: adjTuple)
                }
                if let (farDay, farTuple) = safeFarEasy {
                    dayToWorkout[adjDay] = farTuple
                    dayToWorkout[farDay] = adjTuple
                }
                // If no safe swap exists, leave the hard adjacent to long —
                // it's a less-bad outcome than 3 consecutive hard days.
            }
        }

        // Convert to assigned workouts list
        for (day, workoutTuple) in dayToWorkout {
            assignedWorkouts.append((workout: workoutTuple.workout, dayOfWeek: day))
        }
        
        // Create events
        for (workout, dayOfWeek) in assignedWorkouts {
            if let workoutDate = getDateForWeekday(weekStartDate: weekStartDate, weekdayIndex: dayOfWeek) {
                if workoutDate >= normalizedStartDate && workoutDate < normalizedRaceDate {
                    events.append(WorkoutEvent(workout: workout, planId: planId, date: workoutDate))
                }
            }
        }
    }
    
    // Add race day (skip for maintenance plans — no race target)
    // Race day workout only for real race plans. distance == 0 is maintenance,
    // and VO2 max plans use distance == 5000 internally (5K routing) but
    // shouldn't end with a race — gated by isVO2Max.
    let actualRaceDistances: Set<Int64> = [5000, 10000, 21097, 42195]
    if !config.isVO2Max,
       actualRaceDistances.contains(config.distance),
       let raceWorkout = createRaceWorkout(level: config.runnerLevel, distance: config.distance) {
        events.append(WorkoutEvent(workout: raceWorkout, planId: planId, date: normalizedRaceDate))
    }
    
    return events.sorted { $0.date < $1.date }
}
