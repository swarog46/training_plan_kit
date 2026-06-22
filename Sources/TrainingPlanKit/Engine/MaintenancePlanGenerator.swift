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
                // Reset variety tracking at phase boundaries — encourages reuse of
                // pool workouts within each phase. Persisting across phases interacts
                // badly with the cumulative penalty (good matches give way to short
                // easies, dragging volume down), so keep the per-phase reset.
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

            var weekWorkouts: [(type: String, workout: Workout)] = []
            let targetLoad = targets.load

            let maxWorkoutsPerWeek = config.trainingDays.count
            
            // Filter intervals by max rest per runner level. Only applies to the
            // VO2max-style subtypes (intervals/pyramidIntervals/ladderIntervals)
            // that get their stimulus from short-rest density. Hill repeats,
            // yasso 800s, mile repeats, and time trials are designed with long
            // recoveries by construction — exempt them from this filter or they
            // get excluded for advanced runners (60s rest cap).
            let maxRestPerInterval = config.profile.intervalRestCapSeconds
            
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
                && !competitiveRehearsalWeek
            let ttWeek = recalibTTWeek || peakTTWeek

            // Climb one variant per ~2 plan weeks (load-sorted) across BASE+SPEED so
            // the load-target selector can't park on the cheapest template. Absolute
            // week (not weekInPhase) so the ramp continues base → speed. Applied to
            // BOTH hills and ladders — both have many same-subtype catalog variants.

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
                // Maintenance: fixed 20min interval floor.
                let minIntervalMinutes = 20
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
                        let ramped = rampVariantsByPlanWeek(variants, week: week)
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
            do {
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

                let progressivePool = filterWorkoutsBySubtypeV3(workouts: workoutPool, subtypes: [.progression])
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
