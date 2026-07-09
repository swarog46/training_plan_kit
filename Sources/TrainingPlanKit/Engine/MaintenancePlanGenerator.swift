//
//  MaintenancePlanGenerator.swift
//  RunPlan
//
//  Maintenance plan generator (all levels; open-ended upkeep).
//  Inherits the shared skeleton from PlanGeneratorV3. Starts as a copy of
//  base buildWeek; per-type simplification follows.
//

import Foundation

final class MaintenancePlanGenerator: PlanGeneratorV3 {
    // The maintenance recovery cadence's LIGHT weeks: the opening easy ramp (W1-2)
    // plus every 4th week thereafter (W6, W10, …). The single source of truth for
    // "is this a cutback week" — read by the generator (workout selection) AND by
    // calculateWeeklyTargetsV3 (so the dump's [deload] label marks these same weeks,
    // not the periodization's heavy phase-end weeks). 0-based week index.
    static func isLightWeek(week: Int) -> Bool {
        week < 2 || (week >= 4 && week % 4 == 1)   // W1-2 ramp; W6, W10, …
    }

    override func buildWeek(week: Int) {
        // `repeat { … } while false` lets `continue` (end of the maintenance block)
        // skip the rest of the body and fall through, as it did in the former
        // per-week for-loop.
        repeat {
            let phaseInfo = determinePhaseV3(weekIndex: week, baseDur: baseDur, speedDur: speedDur, peakDur: peakDur, taperDur: taperDur)
            let phase = phaseInfo.phase
            let weekInPhase = phaseInfo.weekInPhase
            
            // Detect phase transition
            let phaseJustStarted = prevPhase != nil && phase != prevPhase!
            if phaseJustStarted {
                // Reset variety tracking at phase boundaries. See BeginnerPlanGenerator.
                usedIds.removeAll()
            }
            prevPhase = phase
            
            // Calculate targets
            let rawTargets = calculateWeeklyTargetsV3(weekInPlan: week, weekInPhase: weekInPhase, phase: phase, phaseDurations: phaseDurations, config: config)
            // ACWR ramp cap (DURATION): cap volume at 1.25× the recent 3-week max,
            // scaling load with the cut. See BeginnerPlanGenerator for the rationale.
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

            var weekWorkouts: [(type: String, workout: Workout)] = []
            let targetLoad = targets.load

            let maxWorkoutsPerWeek = config.trainingDays.count
            
            // Max-rest filter applies only to density-driven VO2 subtypes; see
            // BeginnerPlanGenerator for why hills/yasso/mile-reps/TT are exempt.
            let maxRestPerInterval = config.profile.intervalRestCapSeconds

            // PEAK milestone cadence — computed at week scope so both the
            // pool gate AND the per-level selection logic below can read it.
            let milestoneCadence = max(3, peakDur / 2)
            let yassoWeek = phase == .peak && config.runnerLevel != .beginner && (weekInPhase % milestoneCadence) == 0
            // Time trials: a mid-plan SPEED recalibration check + the late PEAK
            // tune-up; recalib falls back to the last BASE week if no SPEED phase.
            // See BeginnerPlanGenerator for the full reasoning.
            let recalibTTWeek = (speedDur > 0)
                ? (phase == .speed && weekInPhase == speedDur / 2)
                : (phase == .base && weekInPhase == baseDur - 1)
            // Late PEAK tune-up TT only for the longer plans (half+); see Beginner.
            // Competitive forces a rehearsal onto even/last PEAK weeks, so suppress a
            // PEAK TT there (rehearsal + TT would stack into one brutal week).
            let peakWeekIndex = week - baseDur - speedDur
            let competitiveRehearsalWeek = config.runnerLevel == .competitive && peakDur >= 3
                && (peakWeekIndex % 2 == 0 || peakWeekIndex == peakDur - 1)
            let peakTTWeek = config.isLongRaceClass && phase == .peak
                && (weekInPhase % milestoneCadence) == milestoneCadence / 2
                && !competitiveRehearsalWeek
            let ttWeek = recalibTTWeek || peakTTWeek

            // (Hills/ladders climb one variant per ~2 plan weeks via
            // rampVariantsByPlanWeek below — see PlanGeneratorV3.)
            let intervalPool: [Workout] = {
                var pool = filterIntervalsByMaxRest(filteredIntervals, maxRest: maxRestPerInterval)
                // Gate hill repeats: BASE/SPEED only, skipping each phase's first
                // week so the runner adapts first. See BeginnerPlanGenerator.
                let hillsAllowed = (phase == .base || phase == .speed) && weekInPhase >= 1
                if !hillsAllowed {
                    pool = pool.filter { $0.subtype != .hillRepeats }
                }

                // Gate Yasso 800s (Int/Adv only) and Time Trials (all levels) by
                // milestone cadence — 2-3 of each per PEAK cycle, never sharing a week.
                if !yassoWeek {
                    pool = pool.filter { $0.subtype != .yasso800 }
                }
                if !ttWeek {
                    pool = pool.filter { $0.subtype != .timeTrial }
                }

                // Maintenance: fixed 20min interval floor (engine min to engage VO2/T-pace).
                let minIntervalMinutes = 20
                let filtered = pool.filter { $0.duration >= minIntervalMinutes * 60 }
                // Fall back to the full pool if the floor excluded everything.
                var result = filtered.isEmpty ? pool : filtered
                // 5K/10K: the lead VO2 session must be true Z5. Drop Z4-only VO2-family
                // templates when true-Z5 ones exist (on 5K/10K a Z4 "VO2" renders
                // slower than race); see BeginnerPlanGenerator.
                if !config.isLongRaceClass {
                    for vsub in [WorkoutSubtype.intervals, .ladderIntervals, .pyramidIntervals] {
                        if result.contains(where: { $0.subtype == vsub && isRealZ5($0) }) {
                            result = result.filter { !($0.subtype == vsub && !isRealZ5($0)) }
                        }
                    }
                }
                for rampSub in [WorkoutSubtype.hillRepeats, .ladderIntervals] {
                    let variants = result.filter { $0.subtype == rampSub }
                    if variants.count > 1 {
                        let ramped = rampVariantsByPlanWeek(variants, week: week)
                        if !ramped.isEmpty {
                            result = result.filter { $0.subtype != rampSub } + ramped
                        }
                    }
                }
                return result
            }()
            
            // MAINTENANCE: indefinite upkeep, no race target. Cadence: weeks 0-1
            // easy ramp; every 4th week deload; all other weeks 1 long + 1 quality
            // (alternating interval/threshold) + easy fill, scaled to days/week.
            do {
                // Light-week cadence (single source of truth: isLightWeek). The opening
                // two weeks ramp (W1 easy, W2 easy+progression); every 4th week is a
                // cutback. Both are gentle — see the branches below.
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

                let progressivePool = filterWorkoutsBySubtypeV3(workouts: workoutPool, subtypes: [.progression])
                    .filter { $0.duration >= 30 * 60 && $0.duration <= progMaxMin * 60 }
                let easyIntervalPool = intervalPool.filter { $0.duration <= 40 * 60 }
                let effectiveIntervalPool = easyIntervalPool.isEmpty ? intervalPool : easyIntervalPool
                let longPool = longRuns.filter { $0.duration >= 60 * 60 && $0.duration <= longRunMaxMinutes * 60 }

                if week == 0 {
                    // Week 1: pure easy — gentlest onboarding / post-marathon recovery.
                    for _ in 0..<maxWorkoutsPerWeek {
                        if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.4, targetDuration: 25, usedIds: &usedIds, isMaintenance: true) {
                            weekWorkouts.append(("easy_recovery", easy))
                        } else {
                            break
                        }
                    }
                } else if week == 1 {
                    // Week 2: easy + a single progression — a small step up from W1's
                    // pure easy (no long run / hard quality yet). Ramps the opening so
                    // W3's first full quality week isn't a load detonation off pure easy.
                    if !progressivePool.isEmpty,
                       let prog = selectWorkoutByTargetV3(workouts: progressivePool, targetLoad: targetLoad * 0.25, targetDuration: progTargetMin, usedIds: &usedIds, isMaintenance: true) {
                        weekWorkouts.append(("progressive_ramp", prog))
                    }
                    while weekWorkouts.count < maxWorkoutsPerWeek {
                        if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.3, targetDuration: easyTargetMin, usedIds: &usedIds, isMaintenance: true) {
                            weekWorkouts.append(("easy_ramp", easy))
                        } else {
                            break
                        }
                    }
                } else if isDeloadWeek {
                    // Every-4th-week cutback: a GENTLE cutback, not a stop. Keep an
                    // aerobic spine — a long run (when room) + a progression — so the
                    // week stays well below the quality weeks yet the rebound into the
                    // next full week isn't a load detonation. The hard threshold/interval
                    // is what's dropped, not all the volume.
                    if maxWorkoutsPerWeek >= 3, !longPool.isEmpty,
                       let lr = selectWorkoutByTargetV3(workouts: longPool, targetLoad: targetLoad * 0.3, targetDuration: min(55, longRunMaxMinutes - 10), usedIds: &usedIds, isMaintenance: true) {
                        weekWorkouts.append(("long_deload", lr))
                    }
                    if weekWorkouts.count < maxWorkoutsPerWeek, !progressivePool.isEmpty,
                       let prog = selectWorkoutByTargetV3(workouts: progressivePool, targetLoad: targetLoad * 0.25, targetDuration: progTargetMin, usedIds: &usedIds, isMaintenance: true) {
                        weekWorkouts.append(("progressive_deload", prog))
                    }
                    // Fill the rest with easy.
                    while weekWorkouts.count < maxWorkoutsPerWeek {
                        if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.3, targetDuration: easyTargetMin, usedIds: &usedIds, isMaintenance: true) {
                            weekWorkouts.append(("easy_deload", easy))
                        } else {
                            break
                        }
                    }
                } else {
                    // Regular maintenance week, by days/week. 2 days/wk: alternate
                    // long+easy / quality+easy by week (no room for both). 3+ days/wk:
                    // 1 long + 1 quality + easy fill. Quality alternates interval/threshold.
                    let useInterval = (week / 2) % 2 == 0  // alternate quality type per week
                    let isLongWeek = week % 2 == 1          // for 2-day plans only

                    let canFitBoth = maxWorkoutsPerWeek >= 3

                    // First quality week (the week right after the 2-week opening ramp):
                    // long + ONE quality, no 3rd progression slot, and bias the quality
                    // lighter — so the first full week ramps IN off the W2 easy+prog week
                    // instead of detonating straight to a full long+threshold+progression.
                    let isFirstQualityWeek = week == 2
                    let qualityLoadMult = isFirstQualityWeek ? 0.22 : 0.3

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
                            if let intv = selectWorkoutByTargetV3(workouts: effectiveIntervalPool, targetLoad: targetLoad * qualityLoadMult, targetDuration: 30, usedIds: &usedIds, previousWorkout: prevInterval, isDeloading: false, isMaintenance: true) {
                                weekWorkouts.append(("interval", intv))
                                prevInterval = intv
                            }
                        } else if !filteredThresholds.isEmpty {
                            if let th = selectWorkoutByTargetV3(workouts: filteredThresholds, targetLoad: targetLoad * qualityLoadMult, targetDuration: isFirstQualityWeek ? 28 : 35, usedIds: &usedIds, previousWorkout: prevThreshold, isDeloading: false, isMaintenance: true) {
                                weekWorkouts.append(("threshold", th))
                                prevThreshold = th
                            } else if let prog = selectWorkoutByTargetV3(workouts: progressivePool, targetLoad: targetLoad * 0.25, targetDuration: progTargetMin, usedIds: &usedIds, isMaintenance: true) {
                                // Threshold pool empty — fall back to progression
                                weekWorkouts.append(("progressive", prog))
                            }
                        }
                    }

                    // Optional progression slot for 3+ day weeks (skipped on the first
                    // quality week — that week ramps in with just long + 1 quality).
                    if maxWorkoutsPerWeek >= 3 && !isFirstQualityWeek && weekWorkouts.count < maxWorkoutsPerWeek {
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

                // Cap strides at 1/week
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
        } while false
    }
}
