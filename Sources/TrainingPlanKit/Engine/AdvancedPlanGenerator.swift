//
//  AdvancedPlanGenerator.swift
//  RunPlan
//
//  Advanced-tier plan generator (race + VO2).
//  Inherits the shared skeleton from PlanGeneratorV3. Starts as a copy of
//  base buildWeek; per-type simplification follows.
//

import Foundation

final class AdvancedPlanGenerator: PlanGeneratorV3 {
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
                // Reset variety tracking at phase boundaries (per-phase reset).
                // See BeginnerPlanGenerator.
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
            // Late PEAK tune-up TT only for the longer plans (half+); short 5K/10K
            // blocks keep just the mid-plan recalib. See BeginnerPlanGenerator.
            let peakTTWeek = config.distance >= 21000 && phase == .peak
                && (weekInPhase % milestoneCadence) == milestoneCadence / 2
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
                // R8: "5K Pace" is a race-dose session, not the weekly default — on 5K
                // race plans it may lead only every other week, so intervals/ladders
                // (incl. faster-than-5K short reps) carry the rest.
                if !config.isVO2Max, config.distance == 5000, week % 2 == 0 {
                    let nonFivek = result.filter { $0.subtype != .fivekPace }
                    if !nonFivek.isEmpty { result = nonFivek }
                }
                // R10: ladders are the exotic garnish, not the staple — allow
                // them in the pool only every third week (plain intervals lead).
                // R10/#185 phase flavor: BASE builds the engine — no race-
                // specific sharpening tools yet; PEAK sharpens — race-specific
                // work leads when the pool has it. SPEED keeps the full mix.
                if phase == .base, !config.isVO2Max {
                    // Onboarding weeks (1-2) additionally stay Z5-free — the
                    // flavor filter must not promote reps into week 1.
                    if weekInPhase <= 1 {
                        let noZ5 = result.filter { !isRealZ5($0) }
                        if !noZ5.isEmpty { result = noZ5 }
                    }
                    let generalOnly = result.filter {
                        ![WorkoutSubtype.tenkPace, .fivekPace, .mileRepeats, .yasso800]
                            .contains($0.subtype)
                    }
                    if !generalOnly.isEmpty { result = generalOnly }
                } else if phase == .peak, !config.isVO2Max {
                    let raceSpecific = result.filter {
                        [WorkoutSubtype.tenkPace, .fivekPace, .yasso800, .timeTrial]
                            .contains($0.subtype)
                    }
                    if !raceSpecific.isEmpty { result = raceSpecific }
                }
                if week % 3 != 2 {
                    let noLadders = result.filter { $0.subtype != .ladderIntervals }
                    if !noLadders.isEmpty { result = noLadders }
                }
                for rampSub in [WorkoutSubtype.hillRepeats, .ladderIntervals, .tenkPace] {
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
                    // Always add intervals; BASE alternates hill repeats with other
                    // interval work week-to-week. See IntermediatePlanGenerator.
                    let preferHillsThisWeek: Bool = {
                        guard phase == .base, weekInPhase >= 1 else { return false }
                        // fitter tiers alternate a milestone subtype in BASE; beginners stay plain
                        return config.profile.alternatesMilestoneInBase && weekInPhase % 2 == 1
                    }()
                    // VO2 block: the lead quality is a week-indexed Z5 DOSE (ramps
                    // ~12→32min) off the dose ladder (intervals/ladderIntervals/
                    // fivekPace) — so MOST weeks carry true VO2 and the dose climbs,
                    // instead of the selector parking on fivekPace's fixed 20min. Skips
                    // pure BASE onboarding. Takes precedence over the TT/yasso rotation.
                    let isVO2Onboarding = config.isVO2Max && phase == .base && weekInPhase == 0
                    let preferredPool: [Workout] = {
                        if config.isVO2Max && !isVO2Onboarding {
                            let dose = vo2DoseMatched(intervalPool, targetMinutes: vo2Z5DoseTarget(week: week, isDeloading: isDeloading))
                            if !dose.isEmpty { return dose }
                        }
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
                        // PEAK lead-VO2 rotation (mirrors baseLTWeek): force plain
                        // intervals on alternating PEAK weeks so the lead VO2 doesn't
                        // lock onto one ladder; 5K excluded. See IntermediatePlanGenerator.
                        if phase == .peak && weekInPhase % 2 == 1 && config.distance >= 10000 {
                            // Cycle the segment-count variant per forced-interval week
                            // (load-sorted) so the lock doesn't just move titles. See Int.
                            let variants = filterIntervalsByMaxRest(filteredIntervals, maxRest: maxRestPerInterval)
                                .filter { $0.subtype == .intervals }
                                .sorted { $0.trainingLoad < $1.trainingLoad }
                            if !variants.isEmpty {
                                return [variants[(weekInPhase / 2) % variants.count]]
                            }
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

                    // Z5 policy: blocked in BASE/TAPER and the week after a Z5 week
                    // for 21K/42K (VO2 blocks exempt); also blocked at week==weeksToTrim
                    // since trimmed plans can open mid-SPEED. See IntermediatePlanGenerator.
                    let z5Blocked = !config.isVO2Max && (
                        phase == .base || phase == .taper
                        || week == weeksToTrim
                        || (config.distance >= 21000 && lastWeekHadZ5))
                    if z5Blocked {
                        let noZ5 = preferredPool.filter { !isRealZ5($0) }
                        // BASE off-weeks otherwise collapse to all-ladders (the selector
                        // parks on ladders; intervals/pyramids are Z5 and blocked here).
                        // Rotate an LT (threshold) session into every other off-week so
                        // BASE carries 3 quality types (hill/ladder/LT). %4==2 → 2,6,10,…
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
                            // Weekly Z5 cap for the second slot: one Z5/week ceiling
                            // (Adv VO2 blocks excepted), no fallback. See Intermediate.
                            let blockZ5Second = z5Blocked
                                || (z5UsedThisWeek && !config.isVO2Max)
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

                            // 42K Pfitz MP-volume preference: force marathonPace in the
                            // threshold slot on alternating PEAK weeks (bypassing the
                            // progression filter via `filteredThresholds`). See Intermediate.
                            let preferMP = config.distance == 42195
                                && phase == .peak
                                && (week % 2 == 0)
                            if preferMP {
                                let mpOnly = filteredThresholds.filter { $0.subtype == .marathonPace }
                                if !mpOnly.isEmpty { thresholdPool = mpOnly }
                            }

                            if let threshold = selectWorkoutByTargetV3(workouts: thresholdPool, targetLoad: targetLoad * 0.25, targetDuration: Int(targetDuration * 0.3), usedIds: &usedIds, previousWorkout: prevThreshold, isDeloading: isDeloading, phaseJustStarted: phaseJustStarted, isMaintenance: false) {
                                weekWorkouts.append(("threshold", threshold))
                                prevThreshold = threshold
                            }
                        }
                    }

                    // No dedicated 3rd MP slot — the LR already carries MP volume.
                    // See IntermediatePlanGenerator.
            }

            // LONG RUN
            var shouldAddLong = true
            var longRunTypes: [WorkoutSubtype] = [.long, .steadyLong]

            if config.distance == 5000 {
                // Adv 5K: Daniels' Phase II optional ~75min Sunday LRs — aerobic base
                // for the speed work. BASE/SPEED only; PEAK stays sharp.
                longRunTypes = [.long, .steadyLong]
                shouldAddLong = (phase == .base || phase == .speed)
            } else if config.distance == 10000 {
                // 10K Intermediate/Advanced: regular long runs (beginner 10K
                // routes to BeginnerPlanGenerator, never here).
                longRunTypes = [.long, .steadyLong]
                if phase == .base { shouldAddLong = true }
            } else if config.distance >= 21000 {
                // 21K+ Int/Adv/Cmp: keep the default long-run config (the
                // beginner-only override is handled in BeginnerPlanGenerator).
            }

            // SPEED + PEAK: add progressiveLong (Z2→Z3/MP) to break up the wall of
            // aerobic that pure steadyLong selection creates. BASE stays pure aerobic.
            // On even SPEED weeks, force progressiveLong by removing steadyLong/long:
            // otherwise the selector picks light steadyLong every week and the runner
            // never does any HMP work.
            if phase == .speed || phase == .peak {
                // R10: volume dominates — the progressive long is the every-OTHER-
                // week flavor; plain steady long runs carry the rest.
                if week % 2 == 0 {
                    longRunTypes.append(.progressiveLong)
                    if phase == .speed {
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
                // fastFinish: long-ish easy + race-pace tail. The catalog mixes
                // 5K/10K/MP tails; load+duration matching picks the right one.
                if WorkoutSubtype.fastFinish.eligibleDistances.contains(config.distance) {
                    longRunTypes.append(.fastFinish)
                }
                let peakWeekIndex = week - baseDur - speedDur
                if config.distance == 10000 && peakDur >= 2 {
                    // 10K: alternate raceRehearsal10K with plain steady in PEAK to
                    // guarantee the tune-up exposure. See IntermediatePlanGenerator.
                    // Deload weeks skip the slot; it shifts to the next non-deload week.
                    let scheduledMP = peakWeekIndex % 2 == 0
                    let isMPSegmentWeek = !isDeloading && (scheduledMP || pendingRehearsalSlot)
                    if isDeloading && scheduledMP { pendingRehearsalSlot = true }
                    else if isMPSegmentWeek { pendingRehearsalSlot = false }
                    if isMPSegmentWeek {
                        longRunTypes.removeAll {
                            $0 == .steadyLong || $0 == .long
                            || $0 == .progressiveLong || $0 == .fastFinish
                        }
                    }
                }
                // (Beg 21K/42K mid-PEAK rehearsal is handled in BeginnerPlanGenerator.)
            }

            if shouldAddLong && !longRuns.isEmpty {
                var pool = filterWorkoutsBySubtypeV3(workouts: longRuns, subtypes: longRunTypes)

                // Duration cap per (distance, level) — see PlanConfiguration.maxLongRunMinutes.
                let maxDurationMins = config.maxLongRunMinutes
                pool = pool.filter { $0.duration <= maxDurationMins * 60 }

                // Filter: ALL long runs (including progressive) must be >= 60 minutes
                let minLongRunMins = 60
                pool = pool.filter { workout in
                    return workout.duration >= minLongRunMins * 60
                }

                // PEAK: ramp the Race-Rehearsal race-pace segment up across the peak
                // weeks (M 60→75→90; HM 15→20→25→30) so it doesn't park on the
                // largest rung — nor regress. The 10K rehearsal has its OWN PEAK
                // placement (the alternation above), so it only caps the rung
                // (force/windowGate off) — forcing it would add rehearsals on the
                // aerobic weeks and inflate load past the Accessible-tier margin.
                if phase == .peak {
                    let force10K = config.distance != 10000
                    pool = rampRehearsalMPSegment(pool, peakWeekIndex: week - baseDur - speedDur, peakDur: peakDur,
                        priorRehearsalCount: priorPeakRehearsalCount(beforeWeek: week, baseDur: baseDur, speedDur: speedDur), force: force10K, windowGate: force10K, isDeloading: isDeloading)
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
                        // Ramp the long run UP across BASE toward p.base (anchored at
                        // the last base week, -2min/week earlier, floored at 0.80×base).
                        // See BeginnerPlanGenerator.
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
                    // On recovery/deload BUILD weeks, cut the LR target ~20% so the
                    // week's dominant load chunk dips. See BeginnerPlanGenerator.
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

            // R8/R10: a rehearsal week keeps at most ONE other quality session
            // (advanced runners handle rehearsal + one short quality; extras and
            // any standalone MP drop to easy fill).
            if weekWorkouts.contains(where: {
                $0.workout.subtype == .raceRehearsalM || $0.workout.subtype == .raceRehearsalHM
            }) {
                weekWorkouts.removeAll { $0.workout.subtype == .marathonPace }
                let qualityIdx = weekWorkouts.indices.filter {
                    ["interval", "interval2", "threshold"].contains(weekWorkouts[$0].type)
                }
                for i in qualityIdx.dropFirst().reversed() { weekWorkouts.remove(at: i) }
            }

            // Track if we added a long run
            let hasLongRun = weekWorkouts.contains { $0.workout.subtype == .long || $0.workout.subtype == .steadyLong }
            
            // EASY RUN (fills remaining slots). Daniels: 70-80% of weekly volume
            // should be easy, so this slot is easy by default; progression is the
            // occasional ~30% variant.
            if weekWorkouts.count < maxWorkoutsPerWeek {
                // Roughly 30% of weeks get progression instead of easy, so the
                // overall E:P split sits around 70/30 in line with Daniels.
                let progressionWeek = (week % 3 == 0)

                if config.distance == 5000 {
                    // 5K Advanced: easy in BASE; SPEED/PEAK alternates ~70% easy / 30% progression.
                    if phase == .base || !progressionWeek {
                        if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.15, targetDuration: Int(targetDuration * 0.30), usedIds: &usedIds, isMaintenance: false) {
                            weekWorkouts.append(("easy", easy))
                        }
                    } else {
                        let progressivePool = filterWorkoutsBySubtypeV3(workouts: workoutPool, subtypes: [.progression])
                            .filter { $0.duration >= 40 * 60 }
                        if let progressive = selectWorkoutByTargetV3(workouts: progressivePool, targetLoad: targetLoad * 0.20, targetDuration: Int(targetDuration * 0.35), usedIds: &usedIds, isMaintenance: false) {
                            weekWorkouts.append(("progressive", progressive))
                        } else if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.15, targetDuration: Int(targetDuration * 0.30), usedIds: &usedIds, isMaintenance: false) {
                            weekWorkouts.append(("easy", easy))
                        }
                    }
                } else {
                    // Non-5K Advanced: easy by default; progression every 3rd week.
                    // R10: never a SECOND progression-shaped run in one week — if
                    // the long run is already progressive (or a progression is
                    // placed), this slot stays plain easy.
                    let hasProgressionShape = weekWorkouts.contains {
                        $0.workout.subtype == .progression || $0.workout.subtype == .progressiveLong
                    }
                    if !progressionWeek || hasProgressionShape {
                        if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.15, targetDuration: Int(targetDuration * 0.30), usedIds: &usedIds, isMaintenance: false) {
                            weekWorkouts.append(("easy", easy))
                        }
                    } else {
                        var progressivePool = filterWorkoutsBySubtypeV3(workouts: workoutPool, subtypes: [.progression])
                            .filter { $0.duration >= 40 * 60 }
                        if config.distance < 42000 {
                            progressivePool = progressivePool.filter { $0.duration <= 70 * 60 }
                        }
                        if let progressive = selectWorkoutByTargetV3(workouts: progressivePool, targetLoad: targetLoad * 0.20, targetDuration: Int(targetDuration * 0.30), usedIds: &usedIds, isMaintenance: false) {
                            weekWorkouts.append(("progressive", progressive))
                        } else if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.15, targetDuration: Int(targetDuration * 0.30), usedIds: &usedIds, isMaintenance: false) {
                            weekWorkouts.append(("easy", easy))
                        }
                    }
                }
            }

            // BASE phase extra workout
            if phase == .base && weekWorkouts.count < maxWorkoutsPerWeek {
                if config.distance == 5000 {
                    // 5K Advanced: Add progression run in BASE (no long runs for 5K)
                    let progressivePool = filterWorkoutsBySubtypeV3(workouts: workoutPool, subtypes: [.progression])
                        .filter { $0.duration >= 40 * 60 && $0.duration <= 50 * 60 }
                    if let progressive = selectWorkoutByTargetV3(workouts: progressivePool, targetLoad: targetLoad * 0.15, targetDuration: 45, usedIds: &usedIds, isMaintenance: false) {
                        weekWorkouts.append(("progressive_base_5k", progressive))
                    }
                } else if config.distance >= 21000 {
                    // 21K+ Advanced: Add progression or easy (NOT long run - max 1 per week)
                    if !hasLongRun {
                        // Only add a long run if we don't already have one
                        let filteredLong = filterWorkoutsBySubtypeV3(workouts: workoutPool, subtypes: [.long, .steadyLong])
                            .filter { $0.duration >= 60 * 60 && $0.duration <= 80 * 60 }
                        if let longRun = selectWorkoutByTargetV3(workouts: filteredLong, targetLoad: targetLoad * 0.15, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, isMaintenance: false) {
                            weekWorkouts.append(("long_base", longRun))
                        }
                    } else {
                        // Already have a long run — BASE wants easy aerobic volume,
                        // not a 2nd Z3 progression (the every-3rd-week progression
                        // already adds tempo; stacking keeps Adv gray, not polarized).
                        if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.15, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, isMaintenance: false) {
                            weekWorkouts.append(("easy_base", easy))
                        }
                    }
                } else {
                    // 10K Advanced: BASE wants easy aerobic volume (polarized
                    // base) — the every-3rd-week progression already covers tempo.
                    if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.15, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, isMaintenance: false) {
                        weekWorkouts.append(("easy_base", easy))
                    }
                }
            }

            // Fill remaining slots for advanced runners (5 workouts for 21K+, 4 for others)
            while weekWorkouts.count < maxWorkoutsPerWeek {
                if config.distance == 5000 {
                    // 5K Advanced: Add easy run
                    if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.10, targetDuration: Int(targetDuration * 0.20), usedIds: &usedIds, isMaintenance: false) {
                        weekWorkouts.append(("easy_fill", easy))
                    } else {
                        break  // No more workouts available
                    }
                } else if config.distance >= 21000 {
                    // 21K+ Advanced: fill volume with EASY aerobic running — the
                    // endurance base wants easy volume, not more Z3 fill on top of the
                    // every-3rd-week progression and the long run.
                    if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.10, targetDuration: Int(targetDuration * 0.20), usedIds: &usedIds, isMaintenance: false) {
                        weekWorkouts.append(("easy_fill", easy))
                    } else {
                        break
                    }
                } else {
                    // 10K Advanced: Add easy run
                    if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.10, targetDuration: Int(targetDuration * 0.20), usedIds: &usedIds, isMaintenance: false) {
                        weekWorkouts.append(("easy_fill", easy))
                    } else {
                        break
                    }
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
                return 480   // Adv marathon ~8.0h ceiling
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
            applyDeloadReshaping(&weekWorkouts, weekIndex: week, phase: phase, isDeloading: isDeloading)

            enforceLongOverMediumLongV3(&weekWorkouts)
            lastWeekHadZ5 = weekWorkouts.contains { isRealZ5($0.workout) }
            workoutsByWeek[week] = weekWorkouts
        } while false
    }
}
