//
//  PlanGeneratorV3.swift
//  RunPlan
//
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
    // Marathon: floor the taper at 3 weeks. Long runs build monotonically and
    // peak at the last PEAK week, so a 2-week taper lands the longest run only
    // ~2 weeks out — too close to absorb. (Half/shorter shed less; keep theirs.)
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

// MARK: - Plan Generators

/// Base plan generator. Holds the generic skeleton (phase math, pools, the
/// week loop, finalization) shared by every plan type. Per-type generators
/// subclass this and override only the parts that differ — no cross-type
/// `if isBeginner` / `if competitive` branches in the base.
class PlanGeneratorV3 {
    let config: PlanConfiguration
    let totalWeeks: Int
    let allWorkouts: [Workout]
    let adaptive: Bool

    // MARK: - Per-run generation state (single-use generator)
    // Cross-week mutable accumulators. The generator is single-use (one
    // generate() call), so empty/nil/0 initial values suffice; generate()
    // also resets them up front to be safe.
    var workoutsByWeek: [Int: [(type: String, workout: Workout)]] = [:]
    var usedIds: [String: Int] = [:]
    var prevInterval: Workout? = nil
    var prevThreshold: Workout? = nil
    var prevPhase: TrainingPhase? = nil
    var prevLongRunMins: Int = 0
    var lastWeekHadZ5 = false
    var recentDur: [Double] = []

    // Loop-invariant setup (phase math, pools, gating constants). Assigned in
    // generate() before the week loop; read by buildWeek via implicit self.
    var weeksToTrim: Int = 0
    var actualWeeksToGenerate: Int = 0
    var phaseDurations: [String: Int] = [:]
    var baseDur: Int = 0
    var speedDur: Int = 0
    var peakDur: Int = 0
    var taperDur: Int = 0
    var isMaintenance: Bool = false
    // Progression-filtered catalog pool (the former hoisted local `allWorkouts`).
    // Renamed so it never shadows the ctor-input stored `allWorkouts`.
    var workoutPool: [Workout] = []
    var easySubtypes: [WorkoutSubtype] = []
    var longRuns: [Workout] = []
    var easyRuns: [Workout] = []
    var filteredIntervals: [Workout] = []
    var filteredThresholds: [Workout] = []
    var surpriseWeeks: Set<Int> = []
    let restGatedSubtypes: Set<WorkoutSubtype> = [.intervals, .pyramidIntervals, .ladderIntervals]


    init(config: PlanConfiguration, totalWeeks: Int, allWorkouts: [Workout], adaptive: Bool) {
        self.config = config
        self.totalWeeks = totalWeeks
        self.allWorkouts = allWorkouts
        self.adaptive = adaptive
    }

    /// Routes a config to its per-type generator. The single dispatch point.
    static func make(config: PlanConfiguration, totalWeeks: Int, allWorkouts: [Workout], adaptive: Bool) -> PlanGeneratorV3 {
        // Maintenance (distance 0) is cross-level; otherwise dispatch by level.
        // VO2 plans are a level's 5K block + flag, so they ride the level generator.
        if config.distance == 0 {
            return MaintenancePlanGenerator(config: config, totalWeeks: totalWeeks, allWorkouts: allWorkouts, adaptive: adaptive)
        }
        switch config.runnerLevel {
        case .beginner:     return BeginnerPlanGenerator(config: config, totalWeeks: totalWeeks, allWorkouts: allWorkouts, adaptive: adaptive)
        case .intermediate: return IntermediatePlanGenerator(config: config, totalWeeks: totalWeeks, allWorkouts: allWorkouts, adaptive: adaptive)
        case .advanced:     return AdvancedPlanGenerator(config: config, totalWeeks: totalWeeks, allWorkouts: allWorkouts, adaptive: adaptive)
        case .competitive:  return CompetitivePlanGenerator(config: config, totalWeeks: totalWeeks, allWorkouts: allWorkouts, adaptive: adaptive)
        }
    }


    // MARK: - Helpers (moved from generate(); read instance/config state)

    // Two gates: per-distance eligibility (`eligibleDistances` — e.g.
    // marathonPace/yasso800 are marathon-only) and the adaptive paywall
    // (`isAdaptiveOnly` — free plans skip the 5 paid subtypes when !adaptive).
    func isSubtypeEligible(_ subtype: WorkoutSubtype) -> Bool {
        if !adaptive && subtype.isAdaptiveOnly { return false }
        return subtype.eligibleDistances.contains(config.distance)
    }

    // True if any work interval targets HR zone 5.
    func hasZone5(_ workout: Workout) -> Bool {
        for interval in workout.intervals {
            if interval.target == TargetRange.heartRateZone(zone: 5) {
                return true
            }
        }
        return false
    }

    // A "real" Z5 session is any non-stride workout with a Z5 work interval.
    func isRealZ5(_ w: Workout) -> Bool {
        w.subtype != .strides && hasZone5(w)
    }

    // Rest cap applies only to density-dependent VO2 subtypes (intervals/
    // pyramid/ladder). Hills/yasso/mile-reps/TTs use long recoveries by
    // design — exempt, or they'd vanish under the 60s advanced cap.
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

    // Ramp one load-sorted variant per ~2 plan weeks (absolute week, BASE+
    // SPEED) so the selector can't park on the cheapest hill/ladder template.
    func rampVariantsByPlanWeek(_ pool: [Workout], week: Int) -> [Workout] {
        var byTitle: [String: Workout] = [:]
        for w in pool where byTitle[w.title] == nil { byTitle[w.title] = w }
        let variants = byTitle.values.sorted { $0.trainingLoad < $1.trainingLoad }
        guard variants.count >= 2 else { return pool }
        let idx = min(week / 2, variants.count - 1)
        let titles = Set(variants[idx...min(idx + 1, variants.count - 1)].map { $0.title })
        return pool.filter { titles.contains($0.title) }
    }

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

    func generate() -> [Int: [(type: String, workout: Workout)]] {
        // Reset per-run state (defensive: this type is single-use today).
        workoutsByWeek = [:]
        usedIds = [:]
        prevInterval = nil
        prevThreshold = nil
        prevPhase = nil
        prevLongRunMins = 0
        lastWeekHadZ5 = false
        recentDur = []

        // Calculate minimum required weeks
        let minRequiredWeeks = config.minBasePhaseWeeks + config.minSpeedPhaseWeeks + config.minPeakPhaseWeeks + config.minTaperPhaseWeeks

        // If user wants fewer weeks than minimum, generate full plan and trim from start
        if totalWeeks < minRequiredWeeks {
            weeksToTrim = minRequiredWeeks - totalWeeks
            actualWeeksToGenerate = minRequiredWeeks
        } else {
            weeksToTrim = 0
            actualWeeksToGenerate = totalWeeks
        }

        phaseDurations = calculatePhaseDurations(config: config, totalWeeks: actualWeeksToGenerate)
        baseDur = phaseDurations["base"] ?? 0
        speedDur = phaseDurations["speed"] ?? 0
        peakDur = phaseDurations["peak"] ?? 0
        taperDur = phaseDurations["taper"] ?? 0

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

        // Easy pool spans recovery/easy/mediumLong (semantic splits of `easy`
        // by duration); the selector picks the right bucket by load+duration.
        easySubtypes = [.easy, .strides, .recovery, .mediumLong].filter(isSubtypeEligible)

        isMaintenance = config.distance == 0  // no race target
        // Exclude short progression runs (<40min) from race plans (maintenance-only).
        workoutPool = isMaintenance ? self.allWorkouts : self.allWorkouts.filter {
            !($0.subtype == .progression && $0.duration < 40 * 60)
        }
        let intervals = filterWorkoutsBySubtypeV3(workouts: workoutPool, subtypes: intervalSubtypes)
        let thresholds = filterWorkoutsBySubtypeV3(workouts: workoutPool, subtypes: thresholdSubtypes)
        longRuns = filterWorkoutsBySubtypeV3(workouts: workoutPool, subtypes: longRunSubtypes)
        // Competitive (sub-3h / sub-1:30) plans require the Pfitz weekday MLR
        // pattern — easy days are 60-90min, not the 25-50min default. Filter
        // the `.easy` subtype to >= 60min for competitive runners; keep strides
        // intact (they're naturally shorter and serve a different purpose).
        easyRuns = {
            let pool = filterWorkoutsBySubtypeV3(workouts: workoutPool, subtypes: easySubtypes)
            if config.runnerLevel == .competitive {
                return pool.filter { w in
                    w.subtype == .strides || w.duration >= 60 * 60
                }
            }
            return pool
        }()


        // Each plan type narrows its own quality pools (default: keep everything).
        (filteredIntervals, filteredThresholds) = config.profile.qualityPools(
            intervals: intervals, thresholds: thresholds, allWorkouts: workoutPool,
            isVO2Max: config.isVO2Max, hasZone5: hasZone5)

        // Determine surprise weeks for intermediate/advanced
        let surpriseProgressiveCount: Int
        switch config.distance {
        case 5000: surpriseProgressiveCount = 1
        case 10000: surpriseProgressiveCount = 2
        case 21097: surpriseProgressiveCount = 3
        default: surpriseProgressiveCount = 4
        }

        let totalSpeedPeakWeeks = speedDur + peakDur
        surpriseWeeks = []
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

        for week in 0..<actualWeeksToGenerate {
            buildWeek(week: week)
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

    /// Abstract seam: each plan type overrides this. The base is never
    /// instantiated (make() always returns a per-type subclass), so this stub
    /// never runs — it exists only so generate()'s loop can call buildWeek.
    func buildWeek(week: Int) {
        fatalError("PlanGeneratorV3.buildWeek is abstract — call make() for a per-type generator")
    }

}

/// Free-function entry point kept for callers (API, CLI, createMarathonPlanV3).
/// Delegates to the per-type generator chosen by `make`. `adaptive` (default
/// true) gates the 5 paid-tier subtypes; per-distance eligibility applies regardless.
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
