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

    public init(seed: UInt64) {
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
    var taper = config.minTaperPhaseWeeks
    // Marathon taper floor: a 3-week Pfitzinger ramp-down. The long-run
    // progression peaks at the last PEAK week and can only step down in taper
    // (monotonic build), so a 2-week taper lands the longest run just 2 weeks
    // out — too close to absorb. Floor marathon tapers at 3 so the peak long
    // run sits ~3 weeks from race day. Half/shorter keep shorter tapers (less
    // volume to shed); Cmp marathons already ship 3.
    if config.distance >= 30000 {
        taper = max(taper, 3)
    }
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
    public let load: Double
    public let duration: Double
    public let isDeloading: Bool
    public let phaseProgression: Double
}

func calculateWeeklyTargetsV3(weekInPlan: Int, weekInPhase: Int, phase: TrainingPhase,
                              phaseDurations: [String: Int], config: PlanConfiguration) -> WeeklyTargets {
    // Calculate phase progression percentage
    let phaseDuration = phaseDurations[phase.rawValue.lowercased()] ?? 1
    let safePhasePhase = max(1, phaseDuration)
    let phaseProgression = min(1.0, Double(weekInPhase) / Double(safePhasePhase))
    
    // Starting weekly load + duration come straight from the plan's config — the
    // generator no longer switches on level/distance to shape them (each plan
    // declares its own baseLoad, with all the level×distance shaping folded in).
    var baseLoad = config.baseLoad
    var duration = Double(config.initialWeeklyDuration)

    // The one runtime piece: plans that opt into length-scaling (config-declared
    // loadScaleBaselineWeeks, e.g. competitive) start proportionally LOWER when
    // longer than the baseline — a longer plan means a less-fit week 1. Driven by
    // the config flag, not a "which plan is this?" check.
    if let baselineWeeks = config.loadScaleBaselineWeeks {
        let totalPlanWeeks = phaseDurations.values.reduce(0, +)
        if totalPlanWeeks > baselineWeeks {
            let scale = Double(baselineWeeks) / Double(totalPlanWeeks)
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
        let recoveryMult = config.profile.recoveryWeekLoadMultiplier
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

func selectWorkoutByTargetV3(workouts: [Workout], targetLoad: Double, targetDuration: Int,
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

func filterWorkoutsBySubtypeV3(workouts: [Workout], subtypes: [WorkoutSubtype]) -> [Workout] {
    return workouts.filter { subtypes.contains($0.subtype) }
}

// MARK: - Main Plan Generation (mirrors simulate_plan)

/// `adaptive` controls whether paid-tier subtypes (raceRehearsalM/HM/10K,
/// timeTrial, mileRepeats, yasso800, marathonPace) are eligible for selection. Defaults
/// to `true` for back-compat — callers will start passing the entitlement
/// state once StoreKit lands. Per-distance eligibility (e.g. yasso 800s only
/// in marathon plans) applies regardless of this flag — see WorkoutSubtype
/// .eligibleDistances.
/// Base plan generator. Holds the generic skeleton (phase math, pools, the
/// week loop, finalization) shared by every plan type. Per-type generators
/// subclass this and override only the parts that differ — no cross-type
/// `if isBeginner` / `if competitive` branches in the base.
class PlanGeneratorV3 {
    let config: PlanConfiguration
    let totalWeeks: Int
    let allWorkouts: [Workout]
    let adaptive: Bool

    init(config: PlanConfiguration, totalWeeks: Int, allWorkouts: [Workout], adaptive: Bool) {
        self.config = config
        self.totalWeeks = totalWeeks
        self.allWorkouts = allWorkouts
        self.adaptive = adaptive
    }

    /// Routes a config to its per-type generator. The single dispatch point.
    static func make(config: PlanConfiguration, totalWeeks: Int, allWorkouts: [Workout], adaptive: Bool) -> PlanGeneratorV3 {
        PlanGeneratorV3(config: config, totalWeeks: totalWeeks, allWorkouts: allWorkouts, adaptive: adaptive)
    }

    func generate() -> [Int: [(type: String, workout: Workout)]] {
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

        let isMaintenance = config.distance == 0  // no race target
        // Exclude short progression runs (<40min) from race plans (maintenance-only).
        let allWorkouts = isMaintenance ? self.allWorkouts : self.allWorkouts.filter {
            !($0.subtype == .progression && $0.duration < 40 * 60)
        }
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

        // Filter out HR zone 5 for beginners (helper function)
        func hasZone5(_ workout: Workout) -> Bool {
            for interval in workout.intervals {
                if interval.target == TargetRange.heartRateZone(zone: 5) {
                    return true
                }
            }
            return false
        }
        
        // Each plan type narrows its own quality pools (default: keep everything).
        let (filteredIntervals, filteredThresholds) = config.profile.qualityPools(
            intervals: intervals, thresholds: thresholds, allWorkouts: allWorkouts,
            isVO2Max: config.isVO2Max, hasZone5: hasZone5)
        
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
        if totalSpeedPeakWeeks > 0 && config.profile.hasSurpriseProgressiveWeeks {
            let intervalSize = max(1, totalSpeedPeakWeeks / (surpriseProgressiveCount + 1))
            let speedStart = baseDur
            for i in 1...surpriseProgressiveCount {
                let surpriseWeek = speedStart + (i * intervalSize)
                if surpriseWeek < actualWeeksToGenerate - 1 {
                    surpriseWeeks.insert(surpriseWeek)
                }
            }
        }
        
        // Z5 frequency guard (injury-conscious intensity policy). A "real" Z5
        // session is any workout with a work interval targeting HR zone 5;
        // strides are exempt (short neuromuscular reps, not VO2 stress).
        // Race plans (VO2 blocks are exempt — Z5 is their entire point):
        //   - no Z5 in BASE (aerobic foundation) or TAPER (sharpen, don't dig)
        //   - at most one Z5 session per week
        //   - 21K/42K: no Z5 in consecutive weeks (these distances are
        //     threshold/MP-dominant; Pfitz runs ~5-6 VO2 sessions per cycle)
        func isRealZ5(_ w: Workout) -> Bool {
            w.subtype != .strides && hasZone5(w)
        }
        var lastWeekHadZ5 = false
        // ACWR ramp-cap state: rolling window of the last 3 weeks' (capped) durations.
        var recentDur: [Double] = []

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
            let rawTargets = calculateWeeklyTargetsV3(weekInPlan: week, weekInPhase: weekInPhase, phase: phase, phaseDurations: phaseDurations, config: config)
            // ACWR ramp cap (DURATION): a week's volume may not exceed 1.25× the
            // highest of the last 3 weeks — kills back-loaded single-week spikes
            // (e.g. the 5K peak-finish week leaping +44% off a ~250min plateau) while
            // letting post-deload weeks rebound to the recent high. Load scales with
            // the cut so intensity/min is preserved. Caps VOLUME only, so load-
            // balanced builds (marathon) with no duration spike are untouched.
            let targets: WeeklyTargets = {
                guard let maxDur = recentDur.max() else { return rawTargets }
                let capDur = maxDur * 1.25
                guard rawTargets.duration > capDur, rawTargets.duration > 0 else { return rawTargets }
                let scale = capDur / rawTargets.duration
                return WeeklyTargets(load: rawTargets.load * scale,
                                     duration: capDur,
                                     isDeloading: rawTargets.isDeloading,
                                     phaseProgression: rawTargets.phaseProgression)
            }()
            recentDur.append(targets.duration); if recentDur.count > 3 { recentDur.removeFirst() }
            let isDeloading = targets.isDeloading
            
            var weekWorkouts: [(type: String, workout: Workout)] = []
            var z5UsedThisWeek = false
            let targetLoad = targets.load
            let targetDuration = targets.duration
            
            let maxWorkoutsPerWeek = config.trainingDays.count
            
            // Filter intervals by max rest per runner level. Only applies to the
            // VO2max-style subtypes (intervals/pyramidIntervals/ladderIntervals)
            // that get their stimulus from short-rest density. Hill repeats,
            // yasso 800s, mile repeats, and time trials are designed with long
            // recoveries by construction — exempt them from this filter or they
            // get excluded for advanced runners (60s rest cap).
            let maxRestPerInterval = config.profile.intervalRestCapSeconds
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
            // Time trials: a recalibration checkpoint mid-plan (SPEED phase) so the
            // runner re-measures fitness with most of the plan still ahead to act on
            // it, PLUS the original late PEAK tune-up (also breaks up PEAK ladder/
            // interval repetition and holds peak load). Was PEAK-only, which buried
            // the sole TT near ~80% of the plan. Recalib falls back to the last BASE
            // week if a plan has no SPEED phase.
            let recalibTTWeek = (speedDur > 0)
                ? (phase == .speed && weekInPhase == speedDur / 2)
                : (phase == .base && weekInPhase == baseDur - 1)
            // Late PEAK tune-up TT only for the longer plans (half+, 12-20 wk), which
            // benefit from a periodic ~4-week TT cadence and where it also breaks PEAK
            // ladder repetition. 5K/10K (6-10 wk) keep just the single mid-plan
            // recalibration TT — one race-effort check is plenty for a short block.
            // Skip the PEAK week the beginner half/marathon forces a race rehearsal
            // onto (see long-run section) so a TT + a race-pace rehearsal don't stack
            // into one brutal week — they sit in separate weeks instead.
            let rehearsalWeekInPhase = (config.runnerLevel == .beginner && config.distance >= 21000 && peakDur >= 2)
                ? max(1, (peakDur - 1) / 2) : -1
            // Competitive forces a race rehearsal onto even (and the last) PEAK weeks
            // (mirrors the long-run section's isMPSegmentWeek). Don't also drop a PEAK
            // time-trial there: the rehearsal already IS the race-effort check, so a
            // TT + a race-pace rehearsal would stack into one brutal week. Keep the
            // TT and the rehearsal in separate weeks (the rehearsal is the learning
            // point; the mid-plan recalibration TT still satisfies "half has a TT").
            let peakWeekIndex = week - baseDur - speedDur
            let competitiveRehearsalWeek = config.runnerLevel == .competitive && peakDur >= 3
                && (peakWeekIndex % 2 == 0 || peakWeekIndex == peakDur - 1)
            let peakTTWeek = config.distance >= 21000 && phase == .peak
                && (weekInPhase % milestoneCadence) == milestoneCadence / 2
                && weekInPhase != rehearsalWeekInPhase
                && !competitiveRehearsalWeek
            let ttWeek = recalibTTWeek || peakTTWeek

            // Climb one variant per ~2 plan weeks (load-sorted) across BASE+SPEED so
            // the load-target selector can't park on the cheapest template. Absolute
            // week (not weekInPhase) so the ramp continues base → speed. Applied to
            // BOTH hills and ladders — both have many same-subtype catalog variants.
            func rampVariantsByPlanWeek(_ pool: [Workout]) -> [Workout] {
                var byTitle: [String: Workout] = [:]
                for w in pool where byTitle[w.title] == nil { byTitle[w.title] = w }
                let variants = byTitle.values.sorted { $0.trainingLoad < $1.trainingLoad }
                guard variants.count >= 2 else { return pool }
                let idx = min(week / 2, variants.count - 1)
                let titles = Set(variants[idx...min(idx + 1, variants.count - 1)].map { $0.title })
                return pool.filter { titles.contains($0.title) }
            }

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
                    return config.profile.minIntervalMinutes(phase: phase)
                }()
                let filtered = pool.filter { $0.duration >= minIntervalMinutes * 60 }
                // Don't return an empty pool — fall back to full pool if the
                // floor excluded everything (catalog gap, not the user's
                // problem).
                var result = filtered.isEmpty ? pool : filtered
                // 5K/10K: the lead SPEED/VO2 session must be true VO2 (Z5). The catalog
                // tags ~half of intervals/ladderIntervals templates Z4 (LT cruise work)
                // — correct on half/marathon (LT-dominant BY DESIGN) but on 5K/10K,
                // where race ≈ 5K speed, a Z4 "VO2" session renders SLOWER than race
                // (inversion: the "fast" work reads as threshold/race-pace cruise).
                // Drop the Z4-only VO2-family templates when true-Z5 ones exist; hills
                // / mile-reps (strength / LT) are left untouched for variety.
                if config.distance < 21000 {
                    for vsub in [WorkoutSubtype.intervals, .ladderIntervals, .pyramidIntervals] {
                        if result.contains(where: { $0.subtype == vsub && isRealZ5($0) }) {
                            result = result.filter { !($0.subtype == vsub && !isRealZ5($0)) }
                        }
                    }
                }
                for rampSub in [WorkoutSubtype.hillRepeats, .ladderIntervals] {
                    let variants = result.filter { $0.subtype == rampSub }
                    if variants.count > 1 {
                        let ramped = rampVariantsByPlanWeek(variants)
                        if !ramped.isEmpty {
                            result = result.filter { $0.subtype != rampSub } + ramped
                        }
                    }
                }
                return result
            }()
            
            // MAINTENANCE: indefinite fitness upkeep, no race target. Safely
            // handles a post-marathon runner AND preserves fitness long-term.
            // Cadence: weeks 0-1 easy ramp; every 4th week deload; all other
            // weeks get 1 long + 1 quality (alternating interval/threshold) +
            // easy fill, scaled to days/week.
            if isMaintenance {
                let isRecoveryRamp = week < 2
                let isDeloadWeek = week >= 4 && week % 4 == 1  // weeks 5, 9, 13, ...

                // Easy / progression duration progression
                let easyTargetMin = min(40, 25 + week / 6)
                let progTargetMin = min(50, 30 + week / 4)
                let progMaxMin = min(55, progTargetMin + 10)

                // Long-run cap grows over time; floor 60min (engine enforces a
                // catalog-wide 60min long-run minimum — below it the pool is empty).
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
                    // Weeks 0-1: pure easy — doubles as post-marathon recovery.
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
            if config.profile.startsIntervalsInBase && phase == .base {
                shouldAddIntervals = true // fitter tiers start intervals in Base
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
                    // On a Time Trial week, take the interval branch (even if it would
                    // otherwise be a threshold/odd week) and prefer the TT subtype so
                    // the recalibration checkpoint isn't lost to standard intervals
                    // (Yasso is gated out entirely for beginners).
                    if (week % 2 == 0 || ttWeek) && !intervalPool.isEmpty {
                        let begPool: [Workout] = {
                            if ttWeek {
                                let ttOnly = intervalPool.filter { $0.subtype == .timeTrial }
                                if !ttOnly.isEmpty { return ttOnly }
                            }
                            // PEAK = race sharpening. Bias 5K/10K beginners toward
                            // race-specific neuromuscular work (strides @ ~5K pace)
                            // and the tune-up time-trial; drop hill repeats, which
                            // are a BASE-phase strength stimulus. Sustained race-pace
                            // intervals (fivekPace, ~12k load) are intentionally NOT
                            // in the beginner pool — too heavy for a ~9k-load week,
                            // and the catalog has no beginner-dosed variant. Strides
                            // are the injury-safe way a novice rehearses fast running
                            // (Daniels/Higdon). Other distances keep the full pool.
                            if phase == .peak && config.distance <= 10000 {
                                let raceSpecific = intervalPool.filter { $0.subtype != .hillRepeats }
                                if !raceSpecific.isEmpty { return raceSpecific }
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
                        // fitter tiers alternate a milestone subtype in BASE; beginners stay plain
                        return config.profile.alternatesMilestoneInBase && weekInPhase % 2 == 1
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
                        if ttWeek {
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

                    // Z5 policy: blocked in BASE/TAPER, and on the week after a
                    // Z5 week for 21K/42K. VO2 blocks are exempt.
                    // Note `week == weeksToTrim`: short plans are generated at
                    // recommended length and trimmed from the front, so the
                    // runner's first week can land mid-SPEED — it still must not
                    // open with a VO2 session.
                    let z5Blocked = !config.isVO2Max && (
                        phase == .base || phase == .taper
                        || week == weeksToTrim
                        || (config.distance >= 21000 && lastWeekHadZ5))
                    if z5Blocked {
                        let noZ5 = preferredPool.filter { !isRealZ5($0) }
                        // Competitive/advanced BASE otherwise collapses to all-ladders
                        // on the hill off-weeks (the load selector parks on ladders;
                        // intervals/pyramids are real-Z5 and blocked in BASE). Rotate
                        // an LT (threshold) session into every other off-week so BASE
                        // carries 3 quality types (hill / ladder / LT) instead of 2.
                        // Daniels' base quality IS the LT run — the fallback below
                        // already allows it; this just makes it deliberate. Off-weeks
                        // are even weekInPhase; %4==2 picks 2,6,10,… (skip wk-0).
                        let baseLTWeek = phase == .base && weekInPhase % 4 == 2
                            && (config.runnerLevel == .competitive || config.runnerLevel == .advanced)
                        if baseLTWeek,
                           let threshold = selectWorkoutByTargetV3(workouts: filteredThresholds, targetLoad: targetLoad * 0.3, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, previousWorkout: prevThreshold, isDeloading: isDeloading, phaseJustStarted: phaseJustStarted, isMaintenance: isMaintenance) {
                            weekWorkouts.append(("threshold", threshold))
                            prevThreshold = threshold
                        } else if let interval = selectWorkoutByTargetV3(workouts: noZ5, targetLoad: targetLoad * 0.3, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, previousWorkout: prevInterval, isDeloading: isDeloading, phaseJustStarted: phaseJustStarted, isMaintenance: isMaintenance) {
                            weekWorkouts.append(("interval", interval))
                            prevInterval = interval
                        } else if let threshold = selectWorkoutByTargetV3(workouts: filteredThresholds, targetLoad: targetLoad * 0.3, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, previousWorkout: prevThreshold, isDeloading: isDeloading, phaseJustStarted: phaseJustStarted, isMaintenance: isMaintenance) {
                            // No sub-Z5 interval template exists for this distance
                            // (5K pools are mostly I-pace). Use a threshold session
                            // as the week's quality instead of breaking the policy —
                            // Daniels' BASE-phase quality IS the LT run.
                            weekWorkouts.append(("threshold", threshold))
                            prevThreshold = threshold
                        }
                    } else if !preferredPool.isEmpty {
                        if let interval = selectWorkoutByTargetV3(workouts: preferredPool, targetLoad: targetLoad * 0.3, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, previousWorkout: prevInterval, isDeloading: isDeloading, phaseJustStarted: phaseJustStarted, isMaintenance: isMaintenance) {
                            weekWorkouts.append(("interval", interval))
                            prevInterval = interval
                            if isRealZ5(interval) { z5UsedThisWeek = true }
                        }
                    }
                    
                    // Threshold in SPEED/PEAK only (not BASE).
                    //
                    // Quality cap for low-day plans: a 2nd quality session here
                    // (slot-1 already placed one) is right for 4+ day weeks, but on
                    // a 3-day week it leaves zero easy days (quality + quality +
                    // long). The accessible 3-day plans are meant to be the GENTLER
                    // option, not the same load crammed into fewer days — so cap
                    // them at one quality/week and let the freed day fill with easy/
                    // long aerobic running. Textbook non-beginner plans are all 4+
                    // days, so this only relaxes the accessible 3-day tier; the
                    // Pfitz MP/mile forcing below (42K/Cmp, all 5+ days) is untouched.
                    if (phase == .speed || phase == .peak) && config.trainingDays.count >= 4 {
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
                        } else if weekVariation == 3 && !intervalPool.isEmpty && config.distance < 21097 {
                            // Every 5th week (week % 5 == 3): Double intervals instead
                            // of threshold — 5K/10K ONLY. Doubling VO2 in a week suits
                            // a speed race, but a half/marathon is LT- and MP-dominant
                            // (Pfitzinger): no VO2-doubling weeks. 21K/42K fall through
                            // to the threshold (LT) slot below instead.
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
                            let pool2base = secondSlotPool.isEmpty ? intervalPool : secondSlotPool
                            // Weekly Z5 cap + phase/cadence policy for the second
                            // slot: one Z5 session per week is the ceiling (Adv
                            // VO2 blocks excepted). No unfiltered fallback here —
                            // if no sub-Z5 candidate exists, skip the second
                            // interval; the week keeps its slot-1 quality.
                            let blockZ5Second = z5Blocked
                                || (z5UsedThisWeek && !(config.isVO2Max && config.runnerLevel == .advanced))
                            let pool2: [Workout] = blockZ5Second
                                ? pool2base.filter { !isRealZ5($0) }
                                : pool2base
                            if let interval2 = selectWorkoutByTargetV3(workouts: pool2, targetLoad: targetLoad * 0.25, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, previousWorkout: prevInterval, isDeloading: isDeloading, isMaintenance: isMaintenance) {
                                weekWorkouts.append(("interval2", interval2))
                                if isRealZ5(interval2) { z5UsedThisWeek = true }
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
                where rehearsal.eligibleDistances.contains(config.distance)
                    // 10K-pace rehearsal is a quality session — Int/Adv only.
                    && !(isBeginner && rehearsal == .raceRehearsal10K) {
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
                        // Also drop fastFinish: at the half's shorter peak-LR target it
                        // out-matches raceRehearsalHM on load/duration and wins every
                        // time, so the half never got a rehearsal (the marathon's longer
                        // LR picks raceRehearsalM regardless). Removing it forces the
                        // race-pace rehearsal for both distances.
                        longRunTypes.removeAll {
                            $0 == .steadyLong || $0 == .long || $0 == .progressiveLong || $0 == .fastFinish
                        }
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
                // Longest-run cap is declared per-plan on the config as one readable
                // (distance, level) table — see PlanConfiguration.maxLongRunMinutes.
                var maxDurationMins = config.maxLongRunMinutes
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
                // Long-run duration ramp is declared per-plan — see
                // PlanConfiguration.longRunProgression (nil for 5K / maintenance).
                let progression = config.longRunProgression

                if let p = progression {
                    switch phase {
                    case .base:
                        // Ramp the long run UP across BASE toward p.base instead of
                        // holding it flat. Anchored at the LAST base week (= p.base),
                        // stepping down 2min/week earlier, floored at 0.80×base.
                        // Short plans (base ≤ 4w) don't reach the floor so they're
                        // unchanged; long builds (36w marathon, base = 16w) get a real
                        // progressive build instead of a 16-week plateau at p.base.
                        // The 0.80 floor matches where the unconstrained week-1 pick
                        // lands, so the run never descends out of the gate.
                        let weeksFromBaseEnd = max(0, baseDur - 1 - week)
                        let floorMins = Int(Double(p.base) * 0.80)
                        targetLongRunMins = max(floorMins, p.base - 2 * weeksFromBaseEnd)
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
                    // Low-mileage short races only: the long-run load budget sits
                    // below even the shortest run, so the load pick freezes the long
                    // run at the minimum (Beg 10K stuck at 60). Snap to the nearest-
                    // target AEROBIC run. (Half/marathon clear it — left alone, so
                    // their MP-segment peak runs stay intact.)
                    let snapLoadMult = config.profile.longRunSnapLoadFraction
                    let snapMinLoad = pool.map { Double($0.trainingLoad) }.min() ?? 0
                    if config.distance < 21000,
                       Double(targetLoad) * snapLoadMult < snapMinLoad {
                        let aerobic = pool.filter {
                            $0.subtype == .steadyLong || $0.subtype == .long || $0.subtype == .progressiveLong
                        }
                        let base = aerobic.isEmpty ? pool : aerobic
                        if let nearest = base.min(by: {
                            abs(Int($0.duration) / 60 - targetLongRunMins)
                                < abs(Int($1.duration) / 60 - targetLongRunMins)
                        }) {
                            let nd = Int(nearest.duration) / 60
                            let snapped = base.filter { abs(Int($0.duration) / 60 - nd) <= 2 }
                            if !snapped.isEmpty { pool = snapped }
                        }
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
                let lrLoadMult = config.profile.longRunSnapLoadFraction
                // Monotonic enforcement. BASE/SPEED/PEAK: this week's LR may not
                // be meaningfully shorter than last week's (5min slack absorbs
                // selector noise / phase-target movement). TAPER + RACE: must
                // not be longer than last week's. First long run of plan skips.
                if prevLongRunMins > 0 {
                    let monotonicPool: [Workout]
                    switch phase {
                    case .base:
                        // Strict non-decreasing in BASE. The early-base ramp sets a
                        // gently rising target, but the load selector (which favours
                        // shorter runs while early targetLoad is low) would otherwise
                        // drift the long run DOWN within the 5min slack — a visible
                        // backward step at plan start. No slack here.
                        monotonicPool = pool.filter { Int($0.duration / 60) >= prevLongRunMins }
                    case .speed, .peak:
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
                    // BEGINNER 5K/10K/21K + INTERMEDIATE: the 3rd slot is ALWAYS pure
                    // easy. On a 2-3 day week (long + quality + maybe a 3rd) a progression
                    // in the last slot leaves zero recovery whenever the quality slot is
                    // hard — audit: Beg 10K W4 and Beg 21K rehearsal weeks ran threshold +
                    // race-rehearsal-long + progression (3 hard, no easy). At 4 days/wk
                    // Int already carries 2 quality + a race-pace long, same problem.
                    // Variety comes from the rotating long-run type + quality slots.
                    // ONLY Beginner 42K (4 days) gets an occasional 3rd-slot progression —
                    // its 4th slot stays easy, preserving a recovery day (TT weeks too).
                    if config.distance >= 42000 && isBeginner && progressionWeek && !ttWeek {
                        // 21K+: Progress from 40 → 90 mins (can go up to 3 hours)
                        let progressionTargetMins: Int
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
                            // Already have a long run — BASE wants easy aerobic
                            // volume here, not a 2nd Z3 progression. The every-3rd-
                            // week progression (slot above) already supplies the
                            // controlled tempo touch; stacking another keeps Adv in
                            // the gray zone (~50% easy) instead of polarized (~80%,
                            // like the Cmp tier). Default this base slot to easy.
                            if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.15, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, isMaintenance: isMaintenance) {
                                weekWorkouts.append(("easy_base", easy))
                            }
                        }
                    } else {
                        // 10K Advanced: BASE wants easy aerobic volume (polarized
                        // base) — the every-3rd-week progression already covers tempo.
                        if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.15, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, isMaintenance: isMaintenance) {
                            weekWorkouts.append(("easy_base", easy))
                        }
                    }
                } else if config.runnerLevel == .intermediate {
                    // BASE wants easy aerobic volume, not a 2nd Z3 progression — keep
                    // the base polarized (the every-3rd-week SPEED/PEAK progression
                    // already supplies tempo variety for intermediates).
                    if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.15, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, isMaintenance: isMaintenance) {
                        weekWorkouts.append(("easy_base", easy))
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
                        // 21K+ Advanced: fill volume with EASY aerobic running.
                        // (Previously alternated progression/easy here, which — on top
                        // of the every-3rd-week progression and the long run — left
                        // the half/marathon Adv plans ~50% easy. The endurance base
                        // for a 21K+/Adv plan wants easy volume, not more Z3 fill.)
                        if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.10, targetDuration: Int(targetDuration * 0.20), usedIds: &usedIds, isMaintenance: isMaintenance) {
                            weekWorkouts.append(("easy_fill", easy))
                        } else {
                            break
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

            // Peak-volume soft cap (marathon Adv/Cmp). Pfitz 18/70 and 18/85 push
            // 9-10h weeks at peak — faithful to the books, but above what most
            // amateurs choosing these plans can absorb without breaking down. Shed
            // the excess from the largest aerobic FILL (medium-long / easy) only —
            // never the long run, the quality session, or MP work — and let the
            // freed day become recovery. Halves and shorter never approach the cap.
            let weeklyCapMinutes: Int = {
                guard config.distance >= 42195 else { return .max }
                switch config.runnerLevel {
                case .competitive: return 540   // ~9.0h ceiling (was up to 10.1h)
                case .advanced:    return 480   // ~8.0h ceiling (was up to 8.4h)
                default:           return .max  // Beg/Int already sit well below
                }
            }()
            if weeklyCapMinutes != .max {
                let trimmable: Set<WorkoutSubtype> = [.mediumLong, .easy]
                func weekMins() -> Int { weekWorkouts.reduce(0) { $0 + Int($1.workout.duration) / 60 } }
                // Drop the largest aerobic fill until under the cap (keep >= 4
                // sessions so a 6-day peak week never collapses below a real week).
                while weekMins() > weeklyCapMinutes && weekWorkouts.count > 4 {
                    let cands = weekWorkouts.enumerated().filter { trimmable.contains($0.element.workout.subtype) }
                    guard let victim = cands.max(by: { Int($0.element.workout.duration) < Int($1.element.workout.duration) }) else { break }
                    weekWorkouts.remove(at: victim.offset)
                }
            }

            lastWeekHadZ5 = weekWorkouts.contains { isRealZ5($0.workout) }
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
}

/// Free-function entry point kept for callers (API, CLI, createMarathonPlanV3).
/// Delegates to the per-type generator chosen by `make`.
public func generatePlanV3(config: PlanConfiguration, totalWeeks: Int, allWorkouts: [Workout], adaptive: Bool = true) -> [Int: [(type: String, workout: Workout)]] {
    PlanGeneratorV3.make(config: config, totalWeeks: totalWeeks, allWorkouts: allWorkouts, adaptive: adaptive).generate()
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
    let planByWeek = generatePlanV3(config: config, totalWeeks: totalWeeks, allWorkouts: workouts)
    
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
