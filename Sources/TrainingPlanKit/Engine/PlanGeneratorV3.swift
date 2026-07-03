//
//  PlanGeneratorV3.swift
//  RunPlan
//
//  Created by AI on 28/12/2024.
//

import Foundation

// MARK: - Training Model Constants
//
// The periodization model read by `calculateWeeklyTargetsV3`: phase boosts,
// taper/race shaping, deload thresholds, and the progression amplifier — the
// numbers that define the *shape* of every plan's weekly load/duration ramp.
enum TrainingModel {
    /// Per-phase load/duration multiplier over the config baseLoad.
    /// base = baseline; speed = +35%; peak = +70% above base.
    /// Single source of truth for BOTH the target boost AND the previous-phase
    /// boost used by the smooth ramp (they read the same ladder via `phaseBoost`).
    static let baseBoost = 1.0
    static let speedBoost = 1.35
    static let peakBoost = 1.7

    /// Boost for the named phase (base/speed/peak). Taper/race shape off peakBoost
    /// directly and are handled inline, so they're not part of this ladder.
    static func phaseBoost(for phase: TrainingPhase) -> Double {
        switch phase {
        case .speed: return speedBoost
        case .peak:  return peakBoost
        default:     return baseBoost   // base (and any non-ramped phase)
        }
    }

    /// Taper reduces peak: 0.7 → 0.5 across the phase, i.e. `taperReductionStart
    /// - taperReductionSpan * phaseProgression`. Applied as `peakBoost * reduction`.
    static let taperReductionStart = 0.7
    static let taperReductionSpan = 0.2

    /// Race week: cut to `peakBoost * raceLoadFraction` load (55% of peak) and
    /// `raceDurationFraction` duration (60%).
    static let raceLoadFraction = 0.55
    static let raceDurationFraction = 0.6

    /// At/after this phase-progression fraction the phase enters its end deload.
    static let phaseEndDeloadThreshold = 0.8

    /// Phase-end deload growth coefficients: load grows with
    /// `1 + loadProgressionCoeff * phaseProgression`, duration with
    /// `1 + durationProgressionCoeff * phaseProgression` (before the deload cut).
    static let phaseEndDeloadLoadProgressionCoeff = 0.8
    static let phaseEndDeloadDurationProgressionCoeff = 0.7

    /// Amplifies the per-week % load increase into the progression factor:
    /// `1 + phaseProgression * increasePercent/100 * progressionAmplifier`.
    static let progressionAmplifier = 5.0

    /// On recovery/deload weeks, cut the long-run duration target ~20% (Pfitz
    /// cutback weeks drop the long run too, not just the quality).
    static let recoveryLongRunCutback = 0.80
}

// MARK: - Selector Weights
//
// Scoring policy for `selectWorkoutByTargetV3`. Lower score = better pick.
// Variety/recency penalties (sameWorkoutPenalty 2.0, sameTitlePenalty 0.8)
// dominate the load/duration match terms (0.3/0.2) by design — week-to-week
// novelty outranks a marginally tighter target match.
enum SelectorWeights {
    /// Base match cost: weighted relative load + duration error.
    static let loadDiffWeight = 0.3
    static let durationDiffWeight = 0.2

    /// Maintenance plans reshape the pick: favor easy/long/progression (×0.6),
    /// penalize hard intervals/speed (×1.8), moderately penalize threshold/fartlek (×1.3).
    static let maintenanceEasyMultiplier = 0.6
    static let maintenanceIntenseMultiplier = 1.8
    static let maintenanceThresholdMultiplier = 1.3

    /// Strong anti-repetition penalties (these dominate the match terms).
    static let sameWorkoutPenalty = 2.0   // exact same workout key as last week
    static let sameTitlePenalty = 0.8     // same title, different key (e.g. same hill repeats, other duration)

    /// Rest-progression nudges when this week repeats last week's workout TYPE.
    /// Deload: reward same-or-longer rest, penalize shorter.
    static let deloadLongerRestBonus = -0.1
    static let deloadShorterRestPenalty = 0.15
    /// Build: reward same/shorter rest, penalize increasing rest (base + slope × rest growth).
    static let buildSameRestBonus = -0.25
    static let buildShorterRestBonus = -0.15
    static let buildLongerRestPenalty = 0.4
    static let buildLongerRestPenaltySlope = 0.3
}

// MARK: - Phase Duration Calculation (mirrors calculate_phase_durations)

public func calculatePhaseDurations(config: PlanConfiguration, totalWeeks: Int) -> [String: Int] {
    // Taper is fixed — longer plans get more training, not more taper
    var taper = config.minTaperPhaseWeeks
    // Marathon: floor the taper at 3 weeks. The long run peaks at the last PEAK
    // week, so a 2-week taper lands it only ~2 weeks out — too close to absorb.
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

    // Final pass: cap PEAK at 8 weeks for competitive (Pfitz peak windows are
    // 6-8w; longer = overtraining). Excess moves to BASE where VDOT growth happens.
    if config.runnerLevel == .competitive && peak > 8 {
        let excess = peak - 8
        peak = 8
        base += excess
    }

    return ["base": base, "speed": speed, "peak": peak, "taper": taper]
}

// MARK: - Phase Determination (mirrors determine_phase)

public func determinePhaseV3(weekIndex: Int, baseDur: Int, speedDur: Int, peakDur: Int, taperDur: Int) -> (phase: TrainingPhase, weekInPhase: Int) {
    // Week ordering: BASE -> SPEED -> PEAK -> TAPER -> RACE (last week).
    // Race week is distinct from taper: it cuts to ~50% of peak rather than the
    // taper ramp-down. Only splits off when taper >= 2 (a 1-week taper IS race week).
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
        targetPhaseBoost = TrainingModel.baseBoost
    case .speed:
        targetPhaseBoost = TrainingModel.speedBoost
    case .peak:
        targetPhaseBoost = TrainingModel.peakBoost
    case .taper:
        // Taper reduces from peak: 70% -> 50%
        let taperReduction = TrainingModel.taperReductionStart - (TrainingModel.taperReductionSpan * phaseProgression)
        targetPhaseBoost = TrainingModel.peakBoost * taperReduction
    case .race:
        // Race week: 55% of peak load
        return WeeklyTargets(
            load: baseLoad * TrainingModel.peakBoost * TrainingModel.raceLoadFraction,
            duration: duration * TrainingModel.raceDurationFraction,
            isDeloading: true,
            phaseProgression: 1.0
        )
    }

    // Smooth phase transitions: ramp up gradually over first 2 weeks.
    //
    // Cmp 21K PEAK exception: skip the ramp. With only 5 PEAK weeks the ramp eats
    // 40% of the phase, leaving BASE peak > PEAK peak (backwards). The marathon's
    // 8-week PEAK absorbs the ramp fine; the half doesn't have room, and these
    // runners can handle full PEAK boost in W1.
    let skipPeakSmoothRamp = phase == .peak
        && config.runnerLevel == .competitive
        && config.distance == 21097
    if phase != .base && phase != .race && !skipPeakSmoothRamp {
        // Interpolate from the predecessor phase's boost up to this phase's,
        // reading both off the same TrainingModel.phaseBoost ladder.
        let previousPhaseBoost: Double
        switch phase {
        case .speed: previousPhaseBoost = TrainingModel.phaseBoost(for: .base)
        case .peak:  previousPhaseBoost = TrainingModel.phaseBoost(for: .speed)
        case .taper: previousPhaseBoost = TrainingModel.phaseBoost(for: .peak)
        default:     previousPhaseBoost = targetPhaseBoost
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
    
    // Phase-end deload: ONLY the final week of a build phase, and only when the
    // phase is long enough to earn one (its last week crosses the threshold).
    // Was: every week with phaseProgression >= 0.8 — which stacked 2-3 trailing
    // deloads on phases >= 10 weeks. Gating to the last week alone keeps the
    // single trailing deload, de-stagnates the base, and stops wasting peak-load
    // weeks; the peak week is unaffected. The threshold gate keeps short phases
    // (<=4w, e.g. a 1-week PEAK) deload-free exactly as before.
    let isBuildPhase = phase == .base || phase == .speed || phase == .peak
    let isPhaseEndDeload = isBuildPhase
        && weekInPhase == phaseDuration - 1
        && phaseProgression >= TrainingModel.phaseEndDeloadThreshold

    // Does this build phase earn a trailing phase-end deload at all? (Its last
    // week must cross the threshold — true for phases >= 5w, false for <= 4w.)
    let lastWeekProgression = Double(phaseDuration - 1) / Double(safePhasePhase)
    let phaseHasEndDeload = isBuildPhase
        && lastWeekProgression >= TrainingModel.phaseEndDeloadThreshold

    // Mid-phase recovery: phase-relative 3:1 build:recovery within any phase
    // >= 4 weeks. Skips race/taper (already deloaded) and the smooth-transition ramp.
    let isMidPhaseRecovery: Bool = {
        guard phase != .race, phase != .taper, !isPhaseEndDeload else { return false }
        guard phaseDuration >= 4 else { return false }   // Skip on short phases
        guard weekInPhase >= 2 else { return false }     // Skip during smooth-transition ramp
        // Suppress the 3:1 when this phase's trailing deload lands on the very
        // next week — a phase emits at most one trailing deload, never two
        // back-to-back. (No-op when the phase has no end deload, e.g. <=4w.)
        if phaseHasEndDeload && weekInPhase == phaseDuration - 2 { return false }
        return weekInPhase % 3 == 2                      // Every 3rd week within phase
    }()

    var isDeloading = isPhaseEndDeload || isMidPhaseRecovery

    let load: Double
    if isPhaseEndDeload {
        // Phase-end deload - cap at 25%
        let deloadPercent = min(25.0, (config.phaseFinishDeloadPercent.lowerBound + config.phaseFinishDeloadPercent.upperBound) / 2)
        load = baseLoad * phaseBoost * (1.0 + TrainingModel.phaseEndDeloadLoadProgressionCoeff * phaseProgression) * (1.0 - deloadPercent / 100)
        duration = duration * phaseBoost * (1.0 + TrainingModel.phaseEndDeloadDurationProgressionCoeff * phaseProgression) * (1.0 - deloadPercent / 100)
    } else if isMidPhaseRecovery {
        // Mid-phase recovery week: 15% reduction (25% for competitive, whose higher
        // absolute volume makes a 15% drop invisible).
        let increasePercent = (config.weeklyLoadIncreasePercent.lowerBound + config.weeklyLoadIncreasePercent.upperBound) / 2
        // Anchor the cut to the PRIOR week's progression when the profile asks for
        // an explicit dip — else a steady ramp climbs straight through the cut and
        // the cutback is invisible. Fitter tiers keep the trajectory-relative cut.
        let refWeekInPhase = config.profile.cutbackDipsBelowPriorWeek
            ? Double(max(0, weekInPhase - 1)) : Double(weekInPhase)
        let refProgression = min(1.0, refWeekInPhase / Double(safePhasePhase))
        let progressionFactor = 1.0 + (refProgression * increasePercent / 100 * TrainingModel.progressionAmplifier)
        let recoveryMult = config.profile.recoveryWeekLoadMultiplier
        load = baseLoad * phaseBoost * progressionFactor * recoveryMult
        duration = duration * phaseBoost * progressionFactor * recoveryMult
    } else if phase == .taper {
        // Taper: pure phaseBoost-driven reduction. Do NOT apply progressionFactor —
        // it grows with phaseProgression (right for build phases, exactly wrong for
        // a taper), pushing the last taper week to ~82% of peak vs the 50-55% target.
        load = baseLoad * phaseBoost
        duration = duration * phaseBoost
        isDeloading = true  // every taper week is a deload by definition
    } else {
        // Normal progression
        let increasePercent = (config.weeklyLoadIncreasePercent.lowerBound + config.weeklyLoadIncreasePercent.upperBound) / 2
        let progressionFactor = 1.0 + (phaseProgression * increasePercent / 100 * TrainingModel.progressionAmplifier)
        load = baseLoad * phaseBoost * progressionFactor
        duration = duration * phaseBoost * progressionFactor
    }

    // Maintenance runs its OWN recovery cadence (opening easy ramp + every-4th-week
    // cutback) for workout selection, decoupled from the periodization's phase-end/
    // mid-phase deloads. Align the delivered `isDeloading` flag (and thus the dump's
    // [deload] label) with that real cadence, so the tag marks the genuinely light
    // weeks instead of the heavy periodization-deload weeks.
    if config.distance == 0 {
        isDeloading = MaintenancePlanGenerator.isLightWeek(week: weekInPlan)
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
        var score = loadDiff * SelectorWeights.loadDiffWeight + durationDiff * SelectorWeights.durationDiffWeight

        // Maintenance plan adjustments: favor easy/long/progression, penalize intense workouts
        if isMaintenance {
            if w.type == .easyRun || w.type == .longRun || w.type == .progressionRun {
                score *= SelectorWeights.maintenanceEasyMultiplier  // Strong preference for these workout types
            } else if w.type == .intervalRun || w.type == .speedRun {
                score *= SelectorWeights.maintenanceIntenseMultiplier  // Penalize intense workouts
            } else if w.type == .thresholdRun || w.type == .fartlekRun {
                score *= SelectorWeights.maintenanceThresholdMultiplier  // Moderate penalty for threshold work
            }
        }
        
        // Variety penalty scales with how many times this workout was already
        // picked this phase (usedIds is a counter, not a flag) — so a 5×-used
        // workout still ranks below a 1×-used one in long plans.
        let usage = usedIds[w.key, default: 0]
        if usage > 0 {
            score += Double(usage) * varietyBonusBoost
        }
        
        // VERY STRONG penalty for same workout as previous week
        if let prev = previousWorkout, w.key == prev.key {
            score += SelectorWeights.sameWorkoutPenalty
        }
        // Title penalty: the catalog has one title at several durations (distinct
        // keys), so the key penalty above won't stop the same runner-visible
        // workout repeating week after week. Title match catches that.
        if let prev = previousWorkout, w.title == prev.title && w.key != prev.key {
            score += SelectorWeights.sameTitlePenalty
        }
        
        // Progression-aware scoring for threshold/interval types
        if let prev = previousWorkout, prev.type.name == w.type.name {
            let prevRest = prev.restDuration
            let currRest = w.restDuration
            
            if isDeloading {
                // DELOAD: prefer same or LONGER rest
                if currRest >= prevRest {
                    score += SelectorWeights.deloadLongerRestBonus
                } else {
                    score += SelectorWeights.deloadShorterRestPenalty
                }
            } else {
                // BUILD week: prefer same or shorter rest
                if currRest == prevRest {
                    score += SelectorWeights.buildSameRestBonus
                } else if currRest < prevRest {
                    score += SelectorWeights.buildShorterRestBonus
                } else {
                    // Increasing rest during build is bad
                    let restIncrease = Double(currRest - prevRest) / Double(max(prevRest, 60))
                    score += SelectorWeights.buildLongerRestPenalty + (restIncrease * SelectorWeights.buildLongerRestPenaltySlope)
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
    /// BUILD-phase deload week indices (taper excluded), in the RETURNED plan's indexing.
    /// Surfaced so the render can clamp deload long runs to ~0.80x the prior delivered run.
    var deloadWeeks: Set<Int> = []
    /// TAPER/race week indices, in the RETURNED plan's indexing. Surfaced so the render
    /// suppresses the km-floor there (else the first taper week inflates to floor distance).
    var taperWeeks: Set<Int> = []
    var usedIds: [String: Int] = [:]
    /// A PEAK rehearsal slot suppressed by a deload week; the next non-deload peak
    /// week takes it, so short plans don't lose ladder rungs to the 3:1 cadence.
    var pendingRehearsalSlot = false
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

    // Total Z5 work minutes in a workout (the VO2 "dose" — what actually
    // develops VO2max, independent of the session's easy WU/CD bulk).
    func z5DoseMinutes(_ w: Workout) -> Int {
        var secs = 0.0
        for iv in w.intervals where iv.type == .work
            && iv.target == TargetRange.heartRateZone(zone: 5) {
            secs += iv.duration
        }
        return Int(secs / 60)
    }

    // Week-indexed VO2 Z5-dose target (minutes) for an 8-week-ish VO2 block.
    // The headline VO2 fix: the dose must RAMP (~12→30+), not pin at one value.
    // Ramps linearly with the week's position in the block; injury-sane (opens
    // low, never front-loads). A deload week still touches Z5 but at a reduced
    // dose (~75% of the ramp, floored at the VO2 minimum) — a recovery cut that
    // keeps the stimulus rather than stripping it.
    func vo2Z5DoseTarget(week: Int, isDeloading: Bool = false) -> Int {
        let span = max(1, actualWeeksToGenerate - 1)
        let frac = Double(min(week, span)) / Double(span)   // 0…1 across the block
        let lo = 12.0, hi = 32.0
        let target = lo + (hi - lo) * frac
        return Int((isDeloading ? max(lo, target * 0.75) : target).rounded())
    }

    // From a candidate pool, return the true-Z5 workout whose Z5 dose is closest
    // to `targetMinutes` (ties → larger total = more variety). Used by VO2 blocks
    // so the lead quality lands a week-indexed dose instead of whatever total-
    // duration scoring happens to pick (which parked on the fixed-20min fivekPace).
    func vo2DoseMatched(_ pool: [Workout], targetMinutes: Int) -> [Workout] {
        let z5 = pool.filter { isRealZ5($0) }
        guard !z5.isEmpty else { return [] }
        let bestDose = z5.map { z5DoseMinutes($0) }
            .min(by: { abs($0 - targetMinutes) < abs($1 - targetMinutes) })!
        // Keep every template at the chosen dose (all durations/segment counts)
        // so the week-to-week variety + same-workout penalties still operate.
        return z5.filter { z5DoseMinutes($0) == bestDose }
    }

    // Stride rep count = number of Z5 work intervals (the fast finishers) in an
    // "Easy + Strides" workout. Beginners need 4-6 reps (standard 4-8); the
    // 2-rep templates are too few.
    func stridesRepCount(_ w: Workout) -> Int {
        w.intervals.filter {
            $0.type == .work && $0.target == TargetRange.heartRateZone(zone: 5)
        }.count
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

    // Marathon-pace minutes in a workout (sum of Z3 work-interval durations).
    func marathonPaceMinutes(_ w: Workout) -> Int {
        var secs: Double = 0
        for iv in w.intervals where iv.type == .work
            && iv.target == TargetRange.heartRateZone(zone: 3) {
            secs += iv.duration
        }
        return Int(secs / 60)
    }

    // Canonical marathon-rehearsal MP-segment ladder (minutes). The PEAK
    // rehearsal steps UP this ladder so the MP block progresses 60→75→90(→105),
    // Pfitz-style, instead of parking on the largest rung every rehearsal week.
    static let rehearsalMPLadder = [60, 70, 90, 105]  // 3-occurrence plans climb 60/70/90;
    // the 105 rung snaps to the catalog's 90 (no bigger template exists yet), so
    // 4-occurrence Cmp plans top out 60/70/90/90 — a real 4th rung needs a
    // ~100min raceRehearsalM template added to the catalog.

    // Half / 10K rehearsal race-pace-segment ladders (minutes). Same idea, scaled
    // to the shorter race: the HMP block builds toward ~30min, the 10KP toward
    // ~20min, stepping up by occurrence so the segment ramps and never regresses.
    static let rehearsalHMPLadder = [20, 25, 30]
    static let rehearsal10KLadder = [10, 15, 20]

    // The race-pace (goal-effort) block in a rehearsal: Z4 for the 10K rehearsal
    // (its 10KP block is threshold-zone), Z3 for the marathon/half (MP/HMP block).
    static func rehearsalSegmentZone(_ subtype: WorkoutSubtype) -> Int {
        subtype == .raceRehearsal10K ? 4 : 3
    }

    static func rehearsalSegmentLadder(_ subtype: WorkoutSubtype) -> [Int] {
        switch subtype {
        case .raceRehearsalHM: return rehearsalHMPLadder
        case .raceRehearsal10K: return rehearsal10KLadder
        default:                return rehearsalMPLadder
        }
    }

    // Race-pace-segment minutes for a rehearsal of the given subtype (sum of the
    // segment-zone work-interval durations). Generalizes marathonPaceMinutes.
    func rehearsalSegmentMinutes(_ w: Workout, subtype: WorkoutSubtype) -> Int {
        let zone = PlanGeneratorV3.rehearsalSegmentZone(subtype)
        var secs: Double = 0
        for iv in w.intervals where iv.type == .work
            && iv.target == TargetRange.heartRateZone(zone: zone) {
            secs += iv.duration
        }
        return Int(secs / 60)
    }

    // Every race-rehearsal subtype. eligibleDistances pins at most one of these to
    // a given plan, so "the plan's rehearsal" is well-defined.
    static let rehearsalSubtypes: Set<WorkoutSubtype> = [
        .raceRehearsalM, .raceRehearsalHM, .raceRehearsal10K,
    ]

    // The rehearsal subtype present in a pool (M/HM/10K), or nil. At most one
    // exists per plan (distance-pinned), so first match is unambiguous.
    func rehearsalSubtype(in pool: [Workout]) -> WorkoutSubtype? {
        pool.first { PlanGeneratorV3.rehearsalSubtypes.contains($0.subtype) }?.subtype
    }

    // Count of prior PEAK weeks that already carry a race rehearsal (any
    // M/HM/10K) — the occurrence index used to step the segment ladder. Reads the
    // weeks built so far (buildWeek runs sequentially, writing workoutsByWeek).
    func priorPeakRehearsalCount(beforeWeek week: Int, baseDur: Int, speedDur: Int) -> Int {
        var count = 0
        for w in (baseDur + speedDur)..<week {
            if let wk = workoutsByWeek[w],
               wk.contains(where: { PlanGeneratorV3.rehearsalSubtypes.contains($0.workout.subtype) }) {
                count += 1
            }
        }
        return count
    }

    // Number of MP-rehearsal weeks placed at the end of PEAK (Pfitz runs 3-4 MP
    // long runs in the final build block). Bounded so the segment can ramp across
    // distinct ladder rungs without a long peak stacking many identical rungs.
    static let peakRehearsalWeeks = 4

    // Ramp the Race-Rehearsal race-pace segment UP its ladder by occurrence (M:
    // 60→75→90→105; HM: 15→20→25→30; 10K: 10→15→20; then hold) so it doesn't park
    // on the largest rung — nor REGRESS — every rehearsal week; occurrence is
    // monotonic ⇒ the segment is non-decreasing. Auto-detects the plan's rehearsal
    // subtype (M/HM/10K). `force`: make the occurrence rung THIS week's long run
    // (else a small early rung loses on duration) — Int/Adv/Cmp; Beginner stays
    // force=false (one aerobic-tier rehearsal, more race-pace crashes its share).
    // `windowGate`: force only in the last `peakRehearsalWeeks`, dropping earlier
    // emergent rehearsals (Int/Adv) — Competitive gates its own weeks so passes
    // false. No-op unless a rehearsal subtype is in the pool.
    func rampRehearsalMPSegment(_ pool: [Workout], peakWeekIndex: Int, peakDur: Int,
                                priorRehearsalCount: Int, force: Bool, windowGate: Bool,
                                isDeloading: Bool = false) -> [Workout] {
        guard let sub = rehearsalSubtype(in: pool) else { return pool }
        // Deload week: never force (or keep) a rehearsal — the down week runs a plain
        // aerobic long. The rung ladder resumes on the next build week.
        if isDeloading {
            let plain = pool.filter { $0.subtype != sub }
            return plain.isEmpty ? pool : plain
        }
        let rehearsals = pool.filter { $0.subtype == sub }
        let available = Array(Set(rehearsals.map { rehearsalSegmentMinutes($0, subtype: sub) })).sorted()
        guard available.count >= 2 else { return pool }
        let ladder = PlanGeneratorV3.rehearsalSegmentLadder(sub)
        let ladderTarget = ladder[min(priorRehearsalCount, ladder.count - 1)]
        // Snap the ladder target to the nearest available catalog rung.
        guard let targetSize = available.min(by: {
            abs($0 - ladderTarget) < abs($1 - ladderTarget)
        }) else { return pool }
        if windowGate {
            let firstRehearsalWeek = max(0, peakDur - PlanGeneratorV3.peakRehearsalWeeks)
            if peakWeekIndex < firstRehearsalWeek {
                // Before the window: drop rehearsals (plain aerobic LR) so they don't
                // fire early and inflate the occurrence index.
                let plain = pool.filter { $0.subtype != sub }
                return plain.isEmpty ? pool : plain
            }
        }
        if force {
            // FORCE the occurrence-rung rehearsal as this week's long run.
            let forced = pool.filter {
                $0.subtype == sub && rehearsalSegmentMinutes($0, subtype: sub) == targetSize
            }
            return forced.isEmpty ? pool : forced
        }
        // Beginner (force=false): cap an emergent rehearsal's rung, keep plain longs.
        return pool.filter { $0.subtype != sub || rehearsalSegmentMinutes($0, subtype: sub) == targetSize }
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

    /// On recovery/deload weeks, cut the long-run duration target so the week's
    /// dominant load chunk actually dips (the weekly recoveryMult never reaches it).
    /// Build phases only — taper/race long runs are already shaped by their own logic.
    func recoveryLongRunTarget(_ mins: Int, isDeloading: Bool, phase: TrainingPhase) -> Int {
        guard isDeloading, phase == .base || phase == .speed || phase == .peak else { return mins }
        return max(60, Int((Double(mins) * TrainingModel.recoveryLongRunCutback).rounded()))
    }

    // Long-run monotonic constraint, returning the narrowed pool.
    // BASE/SPEED/PEAK: not meaningfully shorter than last week's (5min slack).
    // TAPER/RACE: not longer than last week's.
    // Deloading BUILD weeks are the exception (see below).
    func applyLongRunMonotonic(pool: [Workout], phase: TrainingPhase, prevLongRunMins: Int, isDeloading: Bool) -> [Workout] {
        guard prevLongRunMins > 0 else { return pool }
        // Deloading BUILD week: allow the dip. The non-decreasing rule below would
        // pin the LR flat, so floor at the cutback target (~80% of prev) instead —
        // the down-week LR drops but stays continuous.
        if isDeloading, phase == .base || phase == .speed || phase == .peak {
            let floor = recoveryLongRunTarget(prevLongRunMins, isDeloading: true, phase: phase)
            // Deload long run is plain aerobic: no race-rehearsal / fast-finish on a
            // down week — those repeat the prior week's key session as a lighter copy
            // (classics cut the stressor; a rehearsal IS the stressor).
            let rehearsals: Set<WorkoutSubtype> = [.raceRehearsalM, .raceRehearsalHM, .raceRehearsal10K, .fastFinish]
            let aerobic = pool.filter { !rehearsals.contains($0.subtype) }
            let candidates = aerobic.isEmpty ? pool : aerobic
            let floored = candidates.filter { Int($0.duration / 60) >= floor }
            return floored.isEmpty ? candidates : floored
        }
        let monotonicPool: [Workout]
        switch phase {
        case .base:
            monotonicPool = pool.filter { Int($0.duration / 60) >= prevLongRunMins }
        case .speed, .peak:
            let floor = max(0, prevLongRunMins - 5)
            monotonicPool = pool.filter { Int($0.duration / 60) >= floor }
        case .taper, .race:
            let ceiling = prevLongRunMins + 5
            let capped = pool.filter { Int($0.duration / 60) <= ceiling }
            return capped.isEmpty ? pool : capped
        }
        if !monotonicPool.isEmpty { return monotonicPool }
        // Strict floor emptied the pool. In BUILD phases keep a continuous long run
        // by flooring at 65% of the prior (≈peak) LR, not the 60min minimum.
        let cutbackFloor = Int(Double(prevLongRunMins) * 0.65)
        let floored = pool.filter { Int($0.duration / 60) >= cutbackFloor }
        return floored.isEmpty ? pool : floored
    }

    /// Recovery-week reshaping, by training frequency (cutting the deload LR alone
    /// isn't enough — a down week removes real load). >=5 sessions: drop one;
    /// <=4: keep the days but swap the heaviest quality for easy/progression.
    /// Then a neighbor-aware post-condition: the week must actually DIP below its
    /// predecessor, never strand the week quality-less. BUILD phases only; runs
    /// last in every build generator's buildWeek (so `workoutsByWeek[week-1]` is set).
    func applyDeloadReshaping(_ week: inout [(type: String, workout: Workout)],
                              weekIndex: Int, phase: TrainingPhase, isDeloading: Bool) {
        guard isDeloading, phase == .base || phase == .speed || phase == .peak else { return }

        let aerobicFill: Set<WorkoutSubtype> = [.mediumLong, .easy]
        let qualityTypes: Set<WorkoutType> = [.intervalRun, .speedRun, .thresholdRun, .fartlekRun]
        let longRunSubtypes: Set<WorkoutSubtype> = [
            .long, .steadyLong, .progressiveLong,
            .raceRehearsalM, .raceRehearsalHM, .raceRehearsal10K, .fastFinish,
        ]
        func load(_ wk: [(type: String, workout: Workout)]) -> Int64 {
            wk.reduce(0) { $0 + $1.workout.trainingLoad }
        }

        // VO2 block: the deload already arrives at a REDUCED Z5 dose (the selector
        // cut it ~25%) — preserve that stimulus rather than stripping it to
        // progression/easy. The week still dips via aerobic-fill drop / LR trim
        // below; the Z5 session is just protected from the quality-lighten passes.
        func protectedFromLighten(_ w: Workout) -> Bool { config.isVO2Max && isRealZ5(w) }

        // STEP 1 — differentiated initial reshape (unchanged behavior).
        // High-frequency: drop the largest-duration aerobic fill (never the long
        // run, never quality), keeping the week at >= 4 sessions — a real rest day.
        if week.count >= 5 {
            let cands = week.enumerated().filter { aerobicFill.contains($0.element.workout.subtype) }
            if let victim = cands.max(by: { $0.element.workout.duration < $1.element.workout.duration }) {
                week.remove(at: victim.offset)
            }
        } else {
            // Low-frequency: keep the days, drop the intensity — replace the heaviest
            // quality with an easy/progression of similar duration. Guard B: if that
            // quality is the week's ONLY quality, keep a quality body (progression),
            // never strip it to easy.
            let qualityCands = week.enumerated()
                .filter { qualityTypes.contains($0.element.workout.type) && !protectedFromLighten($0.element.workout) }
            if let heaviest = qualityCands.max(by: { $0.element.workout.trainingLoad < $1.element.workout.trainingLoad }) {
                let targetMins = Int(heaviest.element.workout.duration / 60)
                let soleQuality = qualityCands.count == 1
                let progressionPool = filterWorkoutsBySubtypeV3(workouts: workoutPool, subtypes: [.progression])
                    .filter { abs(Int($0.duration / 60) - targetMins) <= 12 }
                if let prog = progressionPool.min(by: {
                    abs(Int($0.duration / 60) - targetMins) < abs(Int($1.duration / 60) - targetMins)
                }) {
                    week[heaviest.offset] = ("deload_progression", prog)
                } else if !soleQuality,
                          let easy = selectWorkoutByTargetV3(workouts: easyRuns,
                                              targetLoad: Double(heaviest.element.workout.trainingLoad) * 0.6,
                                              targetDuration: targetMins, usedIds: &usedIds,
                                              isMaintenance: false) {
                    // Easy-strip only when other quality remains. Sole quality with no
                    // progression available stays put (a light quality beats none).
                    week[heaviest.offset] = ("deload_easy", easy)
                }
            }
        }

        // STEP 2 — Guard A (neighbor-aware): a recovery week must actually DIP below
        // its predecessor. While still >= prev, shed in order: drop the largest
        // aerobic fill, else lighten the heaviest quality body, else trim the long
        // run deeper. Floors: keep the long run and >= 1 quality body; keep >= 4
        // sessions on a >=5-day plan (>= 3 on a <=4-day plan — a deload sheds a day).
        guard let prev = workoutsByWeek[weekIndex - 1], !prev.isEmpty else { return }
        let prevLoad = load(prev)
        // A "quality body" = an interval/threshold quality OR a progression — keep
        // at least one so a recovery week is never left fully aerobic.
        func isQualityBody(_ w: Workout) -> Bool {
            qualityTypes.contains(w.type) || w.subtype == .progression
        }
        let recoveryDay: Set<WorkoutSubtype> = [.easy, .strides, .recovery]
        let sessionFloor = config.trainingDays.count >= 5 ? 4 : 3
        var iterations = 0  // bounded: each pass removes or shrinks one element
        while load(week) >= prevLoad && iterations < 10 {
            iterations += 1
            // 2a. Drop the largest aerobic fill (above the session floor), but always
            // keep >= 1 easy/strides/recovery day — a build week needs a rest day.
            if week.count > sessionFloor {
                let recoveryDays = week.filter { recoveryDay.contains($0.workout.subtype) }.count
                let fills = week.enumerated().filter { aerobicFill.contains($0.element.workout.subtype) }
                    .filter { !recoveryDay.contains($0.element.workout.subtype) || recoveryDays > 1 }
                if let victim = fills.max(by: { $0.element.workout.duration < $1.element.workout.duration }) {
                    week.remove(at: victim.offset)
                    continue
                }
            }
            // 2b. Lighten the heaviest quality body that HAS a lighter, duration-matched
            // progression (keeps a stimulus, sheds intensity). Replacing with a
            // progression always preserves a quality body, so the floor is never broken.
            // VO2 blocks protect the (already-reduced) Z5 dose from this pass.
            let qIdxs = week.indices.filter { isQualityBody(week[$0].workout) && !protectedFromLighten(week[$0].workout) }
            let progressionPool = filterWorkoutsBySubtypeV3(workouts: workoutPool, subtypes: [.progression])
            var lightenedQuality = false
            for qIdx in qIdxs.sorted(by: { week[$0].workout.trainingLoad > week[$1].workout.trainingLoad }) {
                let q = week[qIdx].workout
                let qMins = Int(q.duration / 60)
                if let pick = progressionPool
                    .filter({ abs(Int($0.duration / 60) - qMins) <= 12 && $0.trainingLoad < q.trainingLoad })
                    .min(by: { abs(Int($0.duration / 60) - qMins) < abs(Int($1.duration / 60) - qMins) }) {
                    week[qIdx] = ("deload_progression", pick)
                    lightenedQuality = true
                    break
                }
            }
            if lightenedQuality { continue }
            // 2c. Trim the long run toward a deeper cut. Re-pick a shorter long run of
            // the same subtype (>= 65% of the current LR; never strip it entirely).
            guard let lrIdx = week.indices
                .filter({ longRunSubtypes.contains(week[$0].workout.subtype) })
                .max(by: { week[$0].workout.duration < week[$1].workout.duration }) else { break }
            let curLR = week[lrIdx].workout
            let curMins = Int(curLR.duration / 60)
            let floorMins = max(60, Int(Double(curMins) * 0.65))
            let sameSubtypeShorter = longRuns
                .filter { Int($0.duration / 60) < curMins && Int($0.duration / 60) >= floorMins
                          && $0.subtype == curLR.subtype }
            // For a marathon race rehearsal, PREFER a shorter-total variant with the
            // SAME MP minutes (trim the easy lead/trail, keep the MP block) so the
            // PEAK MP ramp stays non-decreasing. Fall back to any shorter rehearsal
            // if the catalog has no same-MP variant — a deload must still be able to
            // dip rather than get stuck on a too-heavy long run.
            let curMP = curLR.subtype == .raceRehearsalM ? marathonPaceMinutes(curLR) : -1
            let sameMP = sameSubtypeShorter.filter { curMP < 0 || marathonPaceMinutes($0) == curMP }
            let candidates = sameMP.isEmpty ? sameSubtypeShorter : sameMP
            let shorter = candidates.max(by: { $0.duration < $1.duration })
            guard let pick = shorter, pick.trainingLoad < curLR.trainingLoad else { break }
            week[lrIdx] = (week[lrIdx].type, pick)
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
        // Drop strides sessions whose rep is <20s — too short to be a real
        // neuromuscular stride (20-30s is the standard). All tiers. The stride
        // rep is the short Z5 work segment (the easy warm-up is Z2).
        let stridesFiltered = self.allWorkouts.filter { w in
            if Self.hasShortStrideRep(w) { return false }            // <15s rep
            // 2-rep strides are negligible stimulus — floor race-plan strides at 3
            // reps (3-6 allowed). Maintenance keeps the fuller variety.
            if !isMaintenance, w.subtype == .strides, stridesRepCount(w) < 3 { return false }
            return true
        }
        // Exclude short progression runs (<40min) from race plans (maintenance-only).
        workoutPool = isMaintenance ? stridesFiltered : stridesFiltered.filter {
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
            isVO2Max: config.isVO2Max, isMaintenance: isMaintenance, hasZone5: hasZone5)

        for week in 0..<actualWeeksToGenerate {
            buildWeek(week: week)
        }

        // Capture the REAL build-phase deload weeks (taper excluded) + the taper/race weeks,
        // so the render can clamp deload long runs and suppress the km-floor in taper.
        // Mirrors each buildWeek's own determinePhaseV3 + calculateWeeklyTargetsV3;
        // re-indexed to the trimmed plan below.
        var rawDeloads = Set<Int>()
        var rawTaper = Set<Int>()
        for week in 0..<actualWeeksToGenerate {
            let pi = determinePhaseV3(weekIndex: week, baseDur: baseDur, speedDur: speedDur, peakDur: peakDur, taperDur: taperDur)
            if pi.phase == .taper || pi.phase == .race { rawTaper.insert(week); continue }
            guard pi.phase == .base || pi.phase == .speed || pi.phase == .peak else { continue }
            if calculateWeeklyTargetsV3(weekInPlan: week, weekInPhase: pi.weekInPhase, phase: pi.phase,
                                        phaseDurations: phaseDurations, config: config).isDeloading {
                rawDeloads.insert(week)
            }
        }
        func reindexTrimmed(_ s: Set<Int>) -> Set<Int> {
            weeksToTrim > 0 ? Set(s.compactMap { $0 >= weeksToTrim ? $0 - weeksToTrim : nil }) : s
        }
        deloadWeeks = reindexTrimmed(rawDeloads)
        taperWeeks = reindexTrimmed(rawTaper)

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

    /// True if this strides workout has a stride rep shorter than 15s. The rep is
    /// a short (<60s) Z5 work segment; the easy warm-up portion is Z2, so it's not
    /// mistaken for a rep. Non-strides workouts are never flagged.
    static func hasShortStrideRep(_ w: Workout) -> Bool {
        guard w.subtype == .strides else { return false }
        return w.intervals.contains { iv in
            iv.type == .work && iv.target == .heartRateZone(zone: 5)
                && iv.duration < 15
        }
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

/// Like `generatePlanV3` but also returns the build-phase deload week indices + the
/// taper/race week indices, so the caller can tag each event's `isDeloadWeek` /
/// `isTaperWeek` for the render's deload clamp + taper floor suppression.
public func generatePlanV3WithDeloads(config: PlanConfiguration, totalWeeks: Int, allWorkouts: [Workout], adaptive: Bool = true) -> (plan: [Int: [(type: String, workout: Workout)]], deloadWeeks: Set<Int>, taperWeeks: Set<Int>) {
    let gen = PlanGeneratorV3.make(config: config, totalWeeks: totalWeeks, allWorkouts: allWorkouts, adaptive: adaptive)
    let plan = gen.generate()
    return (plan, gen.deloadWeeks, gen.taperWeeks)
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
    let (planByWeek, deloadWeeks, taperWeeks) = generatePlanV3WithDeloads(config: config, totalWeeks: totalWeeks, allWorkouts: workouts)
    
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

        // True if a slot is "hard" (speed/quality). Must list EVERY quality slot
        // label or the day scheduler places it next to other hard sessions.
        // MP efforts count as quality even though they sit at Z3, not Z4-Z5.
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
                    var ev = WorkoutEvent(workout: workout, planId: planId, date: workoutDate)
                    ev.isDeloadWeek = deloadWeeks.contains(weekIndex)
                    ev.isTaperWeek = taperWeeks.contains(weekIndex)
                    ev.planWeekIndex = weekIndex
                    events.append(ev)
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

// MARK: - Week composition (R8)

/// Proportional duration rescale — every interval scales by the same factor,
/// so paces/targets and the workout's shape are preserved.
func rescaledV3(_ w: Workout, toSeconds target: Int64) -> Workout {
    guard w.duration > 0, target > 0, target != w.duration else { return w }
    let f = Double(target) / Double(w.duration)
    let ivs = w.intervals.map {
        WorkoutInterval(id: $0.id, type: $0.type, duration: $0.duration * f,
                        distance: $0.distance, targetType: $0.targetType, target: $0.target)
    }
    return Workout(id: w.id, title: w.title, type: w.type, subtype: w.subtype,
                   trainingType: w.trainingType, targetType: w.targetType,
                   duration: target, distance: w.distance, key: w.key,
                   trainingLoad: Int64((Double(w.trainingLoad) * f).rounded()),
                   intervals: ivs, workRestRatio: w.workRestRatio,
                   workDuration: Int64((Double(w.workDuration) * f).rounded()),
                   restDuration: Int64((Double(w.restDuration) * f).rounded()),
                   workDistance: w.workDistance, restDistance: w.restDistance)
}

/// R8: the LONG run must out-last any medium-long run in its week. Fixed
/// mediumLong templates (85-110min) can out-last an early-build long run —
/// swap the two durations (weekly volume unchanged, both keep their type).
func enforceLongOverMediumLongV3(_ weekWorkouts: inout [(type: String, workout: Workout)]) {
    let longSubs: Set<WorkoutSubtype> = [.long, .steadyLong, .progressiveLong,
                                         .raceRehearsalM, .raceRehearsalHM, .fastFinish]
    // Compare against the LARGEST medium-long — Cmp weeks carry 2-4 of them
    // (base extra + forced pick + fill), and first-match let the rest slip
    // past the guard (R12 Cmp finding: 27% of weeks inverted).
    guard let li = weekWorkouts.firstIndex(where: { longSubs.contains($0.workout.subtype) }),
          let mi = weekWorkouts.indices
              .filter({ weekWorkouts[$0].workout.subtype == .mediumLong })
              .max(by: { weekWorkouts[$0].workout.duration < weekWorkouts[$1].workout.duration }),
          weekWorkouts[mi].workout.duration > weekWorkouts[li].workout.duration
    else { return }
    let l = weekWorkouts[li].workout, m = weekWorkouts[mi].workout
    weekWorkouts[li] = (weekWorkouts[li].type, rescaledV3(l, toSeconds: m.duration))
    weekWorkouts[mi] = (weekWorkouts[mi].type, rescaledV3(m, toSeconds: l.duration))
}

// MARK: - Aerobic volume top-up (#152 / Roadmap-5)

/// Selection under-delivers vs the config's weekly duration target (slot
/// fractions + template inventory cap what a fixed day count can hold), and
/// the ACWR ramp cap then chains every later week off that shortfall — which
/// collapsed the per-level volume spread the configs encode (42K: Beg 222 /
/// Int 265 / Adv 328 min). Close the gap by scaling the week's PLAIN-AEROBIC
/// runs (easy / mediumLong / recovery — never the long run, never quality) up
/// toward the target: at most +30% per run, 5-min ticked, build weeks only.
func topUpAerobicVolumeV3(_ weekWorkouts: inout [(type: String, workout: Workout)],
                          targetDurationMins: Double, isDeloading: Bool,
                          phase: TrainingPhase) {
    guard !isDeloading, phase == .base || phase == .speed || phase == .peak else { return }
    let aeroSubs: Set<WorkoutSubtype> = [.easy, .mediumLong, .recovery]
    let delivered = weekWorkouts.reduce(0.0) { $0 + Double($1.workout.duration) }
    let targetSec = targetDurationMins * 60.0
    let deficit = targetSec - delivered
    guard deficit >= 300 else { return }
    let aeroIdx = weekWorkouts.indices.filter {
        aeroSubs.contains(weekWorkouts[$0].workout.subtype)
            && !weekWorkouts[$0].workout.intervals.contains { iv in
                if case .heartRateZone(let z) = iv.target { return z >= 4 }
                return false
            }
    }
    let aeroSec = aeroIdx.reduce(0.0) { $0 + Double(weekWorkouts[$1].workout.duration) }
    guard aeroSec > 0 else { return }
    let factor = min(1.30, (aeroSec + deficit) / aeroSec)
    guard factor > 1.02 else { return }
    for i in aeroIdx {
        let w = weekWorkouts[i].workout
        let raw = Double(w.duration) * factor
        let ticked = Int64((raw / 300.0).rounded() * 300.0)
        guard ticked > w.duration else { continue }
        weekWorkouts[i] = (weekWorkouts[i].type, rescaledV3(w, toSeconds: ticked))
    }
}
