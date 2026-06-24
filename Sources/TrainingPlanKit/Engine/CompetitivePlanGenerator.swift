//
//  CompetitivePlanGenerator.swift
//  RunPlan
//
//  Competitive-tier plan generator (race).
//  Inherits the shared skeleton from PlanGeneratorV3. Starts as a copy of
//  base buildWeek; per-type simplification follows.
//

import Foundation

final class CompetitivePlanGenerator: PlanGeneratorV3 {
    override func buildWeek(week: Int) {
        // `repeat { … } while false` lets `continue` (race week) skip the rest
        // of the body and fall through, as it did in the former per-week for-loop.
        repeat {
            let phaseInfo = determinePhaseV3(weekIndex: week, baseDur: baseDur, speedDur: speedDur, peakDur: peakDur, taperDur: taperDur)
            let phase = phaseInfo.phase
            let weekInPhase = phaseInfo.weekInPhase
            
            // Detect phase transition
            let phaseJustStarted = prevPhase != nil && phase != prevPhase!
            if phaseJustStarted {
                // Reset variety tracking at phase boundaries (per-phase reset; the
                // cumulative penalty handles within-phase variety). Persisting across
                // phases drags volume down via penalized good matches. See Beginner.
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
            let isDeloading = targets.isDeloading
            
            var weekWorkouts: [(type: String, workout: Workout)] = []
            var z5UsedThisWeek = false
            let targetLoad = targets.load
            let targetDuration = targets.duration
            
            let maxWorkoutsPerWeek = config.trainingDays.count
            
            // Max-rest filter applies only to density-driven VO2 subtypes; see
            // BeginnerPlanGenerator for why hills/yasso/mile-reps/TT are exempt.
            let maxRestPerInterval = config.profile.intervalRestCapSeconds

            // PEAK milestone cadence — computed at week scope so both the
            // pool gate AND the per-level selection logic below can read it.
            let milestoneCadence = max(3, peakDur / 2)
            let yassoWeek = phase == .peak && (weekInPhase % milestoneCadence) == 0
            // Time trials: a mid-plan SPEED recalibration check + the late PEAK
            // tune-up; recalib falls back to the last BASE week if no SPEED phase.
            // See BeginnerPlanGenerator for the full reasoning.
            let recalibTTWeek = (speedDur > 0)
                ? (phase == .speed && weekInPhase == speedDur / 2)
                : (phase == .base && weekInPhase == baseDur - 1)
            // Late PEAK tune-up TT for the longer plans (half+); see Beginner.
            // Competitive forces a rehearsal onto even/last PEAK weeks, so suppress a
            // PEAK TT there (rehearsal + TT would stack into one brutal week).
            let peakWeekIndex = week - baseDur - speedDur
            let competitiveRehearsalWeek = peakDur >= 3
                && (peakWeekIndex % 2 == 0 || peakWeekIndex == peakDur - 1)
            let peakTTWeek = config.distance >= 21000 && phase == .peak
                && (weekInPhase % milestoneCadence) == milestoneCadence / 2
                && !competitiveRehearsalWeek
            let ttWeek = recalibTTWeek || peakTTWeek

            // (Hills/ladders climb one variant per ~2 plan weeks via
            // rampVariantsByPlanWeek below — see BeginnerPlanGenerator.)
            let intervalPool: [Workout] = {
                var pool = filterIntervalsByMaxRest(filteredIntervals, maxRest: maxRestPerInterval)
                // Gate hill repeats: BASE/SPEED only, skipping each phase's first
                // week so the runner adapts first. See BeginnerPlanGenerator.
                let hillsAllowed = (phase == .base || phase == .speed) && weekInPhase >= 1
                if !hillsAllowed {
                    pool = pool.filter { $0.subtype != .hillRepeats }
                }

                // Gate Yasso 800s / Time Trials by milestone cadence. See
                // IntermediatePlanGenerator.
                if !yassoWeek {
                    pool = pool.filter { $0.subtype != .yasso800 }
                }
                if !ttWeek {
                    pool = pool.filter { $0.subtype != .timeTrial }
                }

                // Min-duration floor by phase+level so the session engages VO2/T-pace;
                // onboarding gets the lighter floor. See BeginnerPlanGenerator.
                let isOnboarding = phase == .base && weekInPhase <= 1
                // Deload build weeks relax the floor to the onboarding 22 (keeps the
                // deload on a real Z5 session, not a trivial one) — see Beginner.
                let minIntervalMinutes: Int = {
                    if isDeloading && phase != .race { return 22 }
                    if isOnboarding { return 22 }
                    return config.profile.minIntervalMinutes(phase: phase)
                }()
                let filtered = pool.filter { $0.duration >= minIntervalMinutes * 60 }
                // Fall back to the full pool if the floor excluded everything.
                var result = filtered.isEmpty ? pool : filtered
                // 5K/10K: the lead VO2 session must be true Z5. Drop Z4-only VO2-family
                // templates when true-Z5 ones exist (on 5K/10K a Z4 "VO2" renders
                // slower than race); see BeginnerPlanGenerator.
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
            
            // RACE week: skip quality entirely. 5K/10K keep taperDur=1, so their
            // last week is phase==.taper but still needs this hands-off treatment.
            // See BeginnerPlanGenerator.
            let isLastWeekOfPlan = week == actualWeeksToGenerate - 1
            let isRaceWeek = phase == .race
                || (phase == .taper && isLastWeekOfPlan)
            if isRaceWeek {
                // Pfitz-style race week: 3 short sessions (progression tune-up,
                // easy+strides, shakeout) ~120min total. See BeginnerPlanGenerator.
                let numWorkouts = min(3, maxWorkoutsPerWeek)
                for i in 0..<numWorkouts {
                    if i == 0 {
                        // First workout: progression run (short)
                        let progressivePool = filterWorkoutsBySubtypeV3(workouts: workoutPool, subtypes: [.progression])
                            .filter { $0.duration >= 40 * 60 && $0.duration <= 50 * 60 }
                        if let progressive = selectWorkoutByTargetV3(workouts: progressivePool, targetLoad: targetLoad * 0.5, targetDuration: 45, usedIds: &usedIds, isMaintenance: false) {
                            weekWorkouts.append(("progressive_race", progressive))
                        }
                    } else if i == 2 {
                        // Final shakeout 1-2 days before race — short, very easy.
                        // Pfitz prescribes 20-30min of jogging + 4×100m strides.
                        let shakeoutPool = filterWorkoutsBySubtypeV3(workouts: workoutPool, subtypes: easySubtypes)
                            .filter { $0.duration >= 20 * 60 && $0.duration <= 35 * 60 }
                        if let shakeout = selectWorkoutByTargetV3(workouts: shakeoutPool, targetLoad: targetLoad * 0.2, targetDuration: 25, usedIds: &usedIds, isMaintenance: false) {
                            weekWorkouts.append(("shakeout_race", shakeout))
                        }
                    } else {
                        // Second workout: easy run hard-capped at 50min (pre-filtered
                        // <= 50min so load scoring can't pick the long ones). See Beginner.
                        let raceEasyPool = filterWorkoutsBySubtypeV3(workouts: workoutPool, subtypes: easySubtypes)
                            .filter { $0.duration <= 50 * 60 }
                        let raceEasyTarget = min(Int(targetDuration * 0.30), 40 * 60)
                        if let easy = selectWorkoutByTargetV3(workouts: raceEasyPool, targetLoad: targetLoad * 0.5, targetDuration: raceEasyTarget, usedIds: &usedIds, isMaintenance: false) {
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

            if shouldAddIntervals {
                    // Always add intervals; BASE alternates hill repeats (Pfitz/Lydiard)
                    // with other interval work week-to-week. See IntermediatePlanGenerator.
                    let preferHillsThisWeek: Bool = {
                        guard phase == .base, weekInPhase >= 1 else { return false }
                        // fitter tiers alternate a milestone subtype in BASE; beginners stay plain
                        return config.profile.alternatesMilestoneInBase && weekInPhase % 2 == 1
                    }()
                    let preferredPool: [Workout] = {
                        // PEAK milestone weeks: prefer the milestone subtype (Yasso /
                        // TT) so it isn't under-picked. See IntermediatePlanGenerator.
                        if phase == .peak && yassoWeek {
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
                        // BASE off-weeks: exclude hill repeats so the load selector
                        // can't pick them every week (forces the alternation that gives
                        // variety). See IntermediatePlanGenerator.
                        let excludesHillsOnOffWeek = phase == .base
                        if excludesHillsOnOffWeek {
                            let withoutHills = intervalPool.filter { $0.subtype != .hillRepeats }
                            if !withoutHills.isEmpty { return withoutHills }
                        }
                        return intervalPool
                    }()

                    // Z5 policy: blocked in BASE/TAPER, the week after a Z5 week for
                    // 21K/42K, and at week==weeksToTrim (trimmed plans can open mid-
                    // SPEED). See IntermediatePlanGenerator.
                    let z5Blocked = phase == .base || phase == .taper
                        || week == weeksToTrim
                        || (config.distance >= 21000 && lastWeekHadZ5)
                    if z5Blocked {
                        let noZ5 = preferredPool.filter { !isRealZ5($0) }
                        // Rotate an LT (threshold) session into every other BASE off-week
                        // so BASE carries 3 quality types (hill/ladder/LT) instead of
                        // collapsing to all-ladders. See AdvancedPlanGenerator.
                        let baseLTWeek = phase == .base && weekInPhase % 4 == 2
                        if baseLTWeek,
                           let threshold = selectWorkoutByTargetV3(workouts: filteredThresholds, targetLoad: targetLoad * 0.3, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, previousWorkout: prevThreshold, isDeloading: isDeloading, phaseJustStarted: phaseJustStarted, isMaintenance: false) {
                            weekWorkouts.append(("threshold", threshold))
                            prevThreshold = threshold
                        } else if let interval = selectWorkoutByTargetV3(workouts: noZ5, targetLoad: targetLoad * 0.3, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, previousWorkout: prevInterval, isDeloading: isDeloading, phaseJustStarted: phaseJustStarted, isMaintenance: false) {
                            weekWorkouts.append(("interval", interval))
                            prevInterval = interval
                        } else if let threshold = selectWorkoutByTargetV3(workouts: filteredThresholds, targetLoad: targetLoad * 0.3, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, previousWorkout: prevThreshold, isDeloading: isDeloading, phaseJustStarted: phaseJustStarted, isMaintenance: false) {
                            // No sub-Z5 interval exists (5K pools are mostly I-pace);
                            // use a threshold as the quality. See IntermediatePlanGenerator.
                            weekWorkouts.append(("threshold", threshold))
                            prevThreshold = threshold
                        }
                    } else if !preferredPool.isEmpty {
                        if let interval = selectWorkoutByTargetV3(workouts: preferredPool, targetLoad: targetLoad * 0.3, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, previousWorkout: prevInterval, isDeloading: isDeloading, phaseJustStarted: phaseJustStarted, isMaintenance: false) {
                            weekWorkouts.append(("interval", interval))
                            prevInterval = interval
                            if isRealZ5(interval) { z5UsedThisWeek = true }
                        }
                    }
                    
                    // Threshold in SPEED/PEAK only, gated to 4+ day plans (a 2nd quality
                    // would zero out a 3-day week's easy days). See IntermediatePlanGenerator.
                    if (phase == .speed || phase == .peak) && config.trainingDays.count >= 4 {
                        // Determine variation type for this week
                        let weekVariation = week % 5  // Cycle every 5 weeks for variety

                        if weekVariation == 3 && !intervalPool.isEmpty && config.distance < 21097 {
                            // Every 5th week: double intervals instead of threshold —
                            // 5K/10K ONLY (half/marathon are LT/MP-dominant). The second
                            // slot excludes milestones and the first slot's subtype.
                            // See IntermediatePlanGenerator.
                            let firstIntervalSubtype = weekWorkouts.last(where: { $0.type == "interval" })?.workout.subtype
                            let secondSlotPool = intervalPool.filter {
                                $0.subtype != .yasso800 &&
                                $0.subtype != .timeTrial &&
                                $0.subtype != firstIntervalSubtype
                            }
                            let pool2base = secondSlotPool.isEmpty ? intervalPool : secondSlotPool
                            // Weekly Z5 cap for the second slot: one Z5/week ceiling,
                            // no fallback. See IntermediatePlanGenerator.
                            let blockZ5Second = z5Blocked || z5UsedThisWeek
                            let pool2: [Workout] = blockZ5Second
                                ? pool2base.filter { !isRealZ5($0) }
                                : pool2base
                            if let interval2 = selectWorkoutByTargetV3(workouts: pool2, targetLoad: targetLoad * 0.25, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, previousWorkout: prevInterval, isDeloading: isDeloading, isMaintenance: false) {
                                weekWorkouts.append(("interval2", interval2))
                                if isRealZ5(interval2) { z5UsedThisWeek = true }
                            }
                        } else if !filteredThresholds.isEmpty {
                            // Normal week: Add threshold
                            let progressedThresholds = filterThresholdsByProgression(filteredThresholds, week: week, totalWeeks: actualWeeksToGenerate)
                            var thresholdPool = progressedThresholds.isEmpty ? filteredThresholds : progressedThresholds

                            // Competitive marathon PEAK already carries MP via the
                            // MP-segment LR alternation. `.marathonPace` is also in
                            // `thresholdSubtypes`, so without this the threshold slot
                            // would add a second MP session (LR + 2 MP = over budget).
                            // Drop MP here so the threshold slot picks a real threshold.
                            let mpQualitySlotWillFire = phase == .peak
                                && config.distance >= 30000
                                && !isDeloading
                            if mpQualitySlotWillFire {
                                let withoutMP = thresholdPool.filter { $0.subtype != .marathonPace }
                                if !withoutMP.isEmpty { thresholdPool = withoutMP }
                            }

                            // Cmp 21K Pfitz LT-interval preference: on alternating
                            // SPEED/PEAK weeks restrict the threshold pool to mileRepeats
                            // (Pfitz's signature 4-6 × 1mi @ HMP, which the selector
                            // otherwise passes over for continuous tempo). Bypasses the
                            // progression filter via `filteredThresholds` (it drops
                            // mileRepeats after ~33%). Marathon Cmp unaffected.
                            let preferMileRepeats = config.distance == 21097
                                && (phase == .speed || phase == .peak)
                                && (week % 2 == 0)
                            if preferMileRepeats {
                                let mileRepsOnly = filteredThresholds.filter { $0.subtype == .mileRepeats }
                                if !mileRepsOnly.isEmpty { thresholdPool = mileRepsOnly }
                            }

                            if let threshold = selectWorkoutByTargetV3(workouts: thresholdPool, targetLoad: targetLoad * 0.25, targetDuration: Int(targetDuration * 0.3), usedIds: &usedIds, previousWorkout: prevThreshold, isDeloading: isDeloading, phaseJustStarted: phaseJustStarted, isMaintenance: false) {
                                weekWorkouts.append(("threshold", threshold))
                                prevThreshold = threshold
                            }
                        }
                    }

                    // No dedicated 3rd MP slot — the PEAK MP-segment LR alternation
                    // already carries that MP volume. See IntermediatePlanGenerator.
            }

            // LONG RUN
            var shouldAddLong = true
            var longRunTypes: [WorkoutSubtype] = [.long, .steadyLong]

            if config.distance == 5000 {
                // 5K Competitive: no long runs (5K is too short to warrant
                // marathon-style endurance work).
                shouldAddLong = false
            } else if config.distance == 10000 {
                // 10K Competitive: regular long runs (beginner 10K
                // routes to BeginnerPlanGenerator, never here).
                longRunTypes = [.long, .steadyLong]
                if phase == .base { shouldAddLong = true }
            } else if config.distance >= 21000 {
                // 21K+ Int/Adv/Cmp: keep the default long-run config (the
                // beginner-only override is handled in BeginnerPlanGenerator).
            }

            // SPEED + PEAK: add progressiveLong (Z2→Z3/MP) to break up the wall of
            // aerobic that pure steadyLong selection creates. BASE stays pure aerobic.
            // On even SPEED weeks force progressiveLong (else the selector picks light
            // steadyLong every week at competitive's scaled-down targets, no HMP work).
            if phase == .speed || phase == .peak {
                longRunTypes.append(.progressiveLong)
                if phase == .speed {
                    let speedWeekIndex = week - baseDur
                    if speedWeekIndex % 2 == 0 {
                        longRunTypes.removeAll { $0 == .steadyLong || $0 == .long }
                    }
                }
            }

            // PEAK weeks: open the long-run pool to the distance-matched race
            // rehearsal (eligibleDistances pins each to one race). See Beginner.
            if phase == .peak {
                for rehearsal: WorkoutSubtype in [.raceRehearsalM, .raceRehearsalHM, .raceRehearsal10K]
                where rehearsal.eligibleDistances.contains(config.distance) {
                    // 10K-pace rehearsal is Int/Adv only; beginner 10K never
                    // reaches the base generator, so no beginner guard needed here.
                    longRunTypes.append(rehearsal)
                }
                // fastFinish isn't appended for competitive: it caps at 100min, short
                // of the 160-200min peak LR target.
                // Late PEAK: alternate MP-segment vs steady LRs — pure steadyLong
                // exclusion would starve the selector into 5+ consecutive rehearsals.
                // Even peakWeekIndex (and the first/last) gets MP-segment; odd gets a
                // recovery aerobic week.
                let peakWeekIndex = week - baseDur - speedDur
                if peakDur >= 3 {
                    let isMPSegmentWeek = peakWeekIndex % 2 == 0 || peakWeekIndex == peakDur - 1
                    if isMPSegmentWeek {
                        // Force a race-rehearsal-style pick.
                        longRunTypes.removeAll { $0 == .steadyLong || $0 == .long }
                    } else {
                        // Recovery aerobic week: drop rehearsals, pick plain steady.
                        longRunTypes.removeAll {
                            $0 == .raceRehearsalM || $0 == .raceRehearsalHM || $0 == .raceRehearsal10K
                        }
                    }
                }
            }
            
            if shouldAddLong && !longRuns.isEmpty {
                var pool = filterWorkoutsBySubtypeV3(workouts: longRuns, subtypes: longRunTypes)

                // Duration cap per (distance, level) — see PlanConfiguration.maxLongRunMinutes.
                let maxDurationMins = config.maxLongRunMinutes
                pool = pool.filter { $0.duration <= maxDurationMins * 60 }

                // Competitive: drop the lightest progressives (< 25% Z3 work). The
                // selector otherwise picks the 12-18% Z3 variants, leaving long-run
                // aerobic share ~85%; Pfitz prescribes 25-40% MP volume per workout.
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

                // Filter: ALL long runs (including progressive) must be >= 60 minutes
                let minLongRunMins = 60
                pool = pool.filter { workout in
                    return workout.duration >= minLongRunMins * 60
                }

                // Progressive long-run target by distance+level+phase from the config's
                // (start, peak) anchors — without it the load-dominated selector picks
                // short LRs. See BeginnerPlanGenerator.
                let longRunTargetMins: Int
                let targetLongRunMins: Int

                // Ramp declared per-plan in PlanConfiguration.longRunProgression
                // (nil for 5K / maintenance → non-progressive logic below).
                let progression = config.longRunProgression

                if let p = progression {
                    switch phase {
                    case .base:
                        // Ramp the LR UP across BASE toward p.base (last base week,
                        // -2min/week earlier, floored at 0.80×base). See Beginner.
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
                    // Recovery/deload BUILD weeks: cut the LR target ~20%. See Beginner.
                    longRunTargetMins = recoveryLongRunTarget(targetLongRunMins, isDeloading: isDeloading, phase: phase)
                    let toleranceMins = 15
                    let filteredByTarget = pool.filter { abs(Int($0.duration) / 60 - longRunTargetMins) <= toleranceMins }
                    if !filteredByTarget.isEmpty {
                        pool = filteredByTarget
                    }
                    // Low-mileage short races: load budget sits below the shortest run,
                    // so snap to the nearest-target aerobic run (half/marathon untouched).
                    // See BeginnerPlanGenerator.
                    let snapLoadMult = config.profile.longRunSnapLoadFraction
                    let snapMinLoad = pool.map { Double($0.trainingLoad) }.min() ?? 0
                    if config.distance < 21000,
                       Double(targetLoad) * snapLoadMult < snapMinLoad {
                        let aerobic = pool.filter {
                            $0.subtype == .steadyLong || $0.subtype == .long || $0.subtype == .progressiveLong
                        }
                        let base = aerobic.isEmpty ? pool : aerobic
                        if let nearest = base.min(by: {
                            abs(Int($0.duration) / 60 - longRunTargetMins)
                                < abs(Int($1.duration) / 60 - longRunTargetMins)
                        }) {
                            let nd = Int(nearest.duration) / 60
                            let snapped = base.filter { abs(Int($0.duration) / 60 - nd) <= 2 }
                            if !snapped.isEmpty { pool = snapped }
                        }
                    }
                } else {
                    // 5K (Adv, no longRunProgression): weekly-duration percentage.
                    longRunTargetMins = Int(targetDuration * 0.50)
                }

                // LR load multiplier (bumped for competitive so PEAK picks the long
                // steadyLong/raceRehearsalM over short alternatives). See Beginner.
                let lrLoadMult = config.profile.longRunSnapLoadFraction
                // Monotonic: non-decreasing in BUILD, non-increasing in TAPER/RACE,
                // 65%-of-peak cutback floor. See BeginnerPlanGenerator.
                pool = applyLongRunMonotonic(pool: pool, phase: phase, prevLongRunMins: prevLongRunMins, isDeloading: isDeloading)
                if let longRun = selectWorkoutByTargetV3(workouts: pool, targetLoad: targetLoad * lrLoadMult, targetDuration: longRunTargetMins, usedIds: &usedIds, isMaintenance: false) {
                    weekWorkouts.append(("long", longRun))
                    prevLongRunMins = Int(longRun.duration / 60)
                }
            }

            // EASY RUN (fills remaining slots). Daniels: 70-80% of weekly volume
            // should be easy, so this slot is easy by default.
            if weekWorkouts.count < maxWorkoutsPerWeek {
                if !easyRuns.isEmpty {
                        // Competitive bumps the easy load multiplier to 0.30 so the
                        // selector targets the 80-90min easies, not the filtered-out
                        // 60min ones (every PEAK week picked the same 60min easy otherwise).
                        // TAPER/RACE override: drop to short easies (30-50min) — Pfitz
                        // tapers easy-day duration too, and the >= 60min filter would
                        // otherwise blow past the taper target.
                        let isTaperingDown = phase == .taper || phase == .race
                        let easyLoadMult: Double
                        let easyPool: [Workout]
                        let easyTargetDur: Int
                        if isTaperingDown {
                            let taperCapMins = phase == .race ? 35 : 50
                            easyLoadMult = 0.10
                            easyPool = filterWorkoutsBySubtypeV3(workouts: workoutPool, subtypes: easySubtypes)
                                .filter { $0.duration <= taperCapMins * 60 }
                            easyTargetDur = phase == .race ? 25 : 40
                        } else {
                            easyLoadMult = 0.30
                            easyPool = easyRuns
                            easyTargetDur = Int(targetDuration * 0.30)
                        }

                        // Force mediumLong on alternating midweek slots (marathon/HM):
                        // else the selector picks generic `easy` (60-80min) over
                        // `mediumLong` (85-110min), and Pfitz prescribes a weekday MLR.
                        // 10K/5K excluded (the 85+min pool is too long for their targets).
                        let isMarathonOrHM = (config.distance == 42195 || config.distance == 21097)
                        let prefersMediumLong = isMarathonOrHM
                            && phase != .taper && phase != .race
                            && week % 2 == 0
                        var finalPool = easyPool
                        if prefersMediumLong {
                            let mlOnly = easyPool.filter { $0.subtype == .mediumLong }
                            if !mlOnly.isEmpty { finalPool = mlOnly }
                        }

                        if let easy = selectWorkoutByTargetV3(workouts: finalPool, targetLoad: targetLoad * easyLoadMult, targetDuration: easyTargetDur, usedIds: &usedIds, isMaintenance: false) {
                            weekWorkouts.append(("easy", easy))
                        }
                }
            }
            
            // BASE phase extra workout
            if phase == .base && weekWorkouts.count < maxWorkoutsPerWeek {
                // Competitive: add a medium-long easy (60-90min) for Pfitz-style
                // weekly volume.
                if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.25, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, isMaintenance: false) {
                    weekWorkouts.append(("easy", easy))
                }
            }

            // Fill remaining slots (5 for 21K+, 4 for others).
            while weekWorkouts.count < maxWorkoutsPerWeek {
                // Fill with easy runs; 21K+ prefers a longer "medium-long" first fill
                // so weekly volume grows at 4+ days.
                let isLongRace = config.distance >= 21000
                let isFirstFill = !weekWorkouts.contains { $0.type.contains("fill") }
                // Drop the Pfitz-MLR sizing in TAPER/RACE — tapering means shorter
                // easies all around (Pfitz race-week easies are 30-45min, not 80-110).
                let isTaperingDown = phase == .taper || phase == .race
                let easyTargetMin: Int = {
                    if isTaperingDown {
                        return phase == .race ? 30 : 40
                    } else if isLongRace && isFirstFill {
                        return min(90, max(60, Int(targetDuration * 0.30)))
                    } else {
                        return min(90, max(60, Int(targetDuration * 0.25)))
                    }
                }()
                // Per-slot LOAD multipliers drive the pick (load match dominates);
                // competitive scales them up to land on the catalog's long easies.
                let mlrLoadMult = 0.33
                let fillLoadMult = 0.23
                let easyTargetLoad: Double
                if isTaperingDown {
                    easyTargetLoad = targetLoad * 0.08
                } else {
                    easyTargetLoad = targetLoad * (isLongRace && isFirstFill ? mlrLoadMult : fillLoadMult)
                }
                // Hard-cap easy duration when tapering so the selector can't pick a
                // 60-90min MLR even when load scoring would prefer it.
                let easyPool: [Workout]
                if isTaperingDown {
                    let taperCapMins = phase == .race ? 35 : 50
                    easyPool = filterWorkoutsBySubtypeV3(workouts: workoutPool, subtypes: easySubtypes)
                        .filter { $0.duration <= taperCapMins * 60 }
                } else {
                    easyPool = easyRuns
                }
                if let easy = selectWorkoutByTargetV3(workouts: easyPool, targetLoad: easyTargetLoad, targetDuration: easyTargetMin, usedIds: &usedIds, isMaintenance: false) {
                    weekWorkouts.append((isLongRace && isFirstFill ? "medium_long_fill" : "easy_fill", easy))
                } else {
                    break  // Catalog exhausted
                }
            }

            // Cap strides at 1/week — replace extras with the closest-duration plain
            // easy from the UNFILTERED pool (avoids wrecking taper). See Beginner.
            let stridesIndices = weekWorkouts.indices.filter { weekWorkouts[$0].workout.subtype == .strides }
            if stridesIndices.count > 1 {
                let plainEasy = filterWorkoutsBySubtypeV3(workouts: workoutPool, subtypes: [.easy])
                for i in stridesIndices.dropFirst() {
                    let targetMin = Int(weekWorkouts[i].workout.duration / 60)
                    if let replacement = plainEasy.min(by: {
                        abs(Int($0.duration / 60) - targetMin) < abs(Int($1.duration / 60) - targetMin)
                    }) {
                        weekWorkouts[i] = (weekWorkouts[i].type, replacement)
                    }
                }
            }

            // Peak-volume soft cap (marathon Adv/Cmp): shed excess from the largest
            // aerobic FILL only, freeing a recovery day. See BeginnerPlanGenerator.
            let weeklyCapMinutes: Int = {
                guard config.distance >= 42195 else { return .max }
                return 540   // Cmp marathon ~9.0h ceiling
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

            // Recovery-week reshaping: remove real load on deload weeks (drop a
            // session at >=5/wk, else swap the heaviest quality for easy/progression).
            // Runs last so it sees the fully-assembled week. BUILD phases only.
            applyDeloadReshaping(&weekWorkouts, phase: phase, isDeloading: isDeloading)

            lastWeekHadZ5 = weekWorkouts.contains { isRealZ5($0.workout) }
            workoutsByWeek[week] = weekWorkouts
        } while false
    }
}
