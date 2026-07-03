//
//  IntermediatePlanGenerator.swift
//  RunPlan
//
//  Intermediate-tier plan generator (race + VO2).
//  Inherits the shared skeleton from PlanGeneratorV3. Starts as a copy of
//  base buildWeek; per-type simplification follows.
//

import Foundation

final class IntermediatePlanGenerator: PlanGeneratorV3 {
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

                // Gate Yasso 800s (Int/Adv only) and Time Trials (all levels) by
                // milestone cadence — 2-3 of each per PEAK cycle, never sharing a week.
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
                    // Always add intervals. BASE prefers hill repeats (Higdon/Lydiard
                    // strength), alternating with other interval work week-to-week so a
                    // run of one hill template doesn't read as one repeated workout.
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
                        // TT) so it isn't under-picked vs ladders/hills.
                        if phase == .peak && yassoWeek {
                            let yassosOnly = intervalPool.filter { $0.subtype == .yasso800 }
                            if !yassosOnly.isEmpty { return yassosOnly }
                        }
                        if ttWeek {
                            let ttOnly = intervalPool.filter { $0.subtype == .timeTrial }
                            if !ttOnly.isEmpty { return ttOnly }
                        }
                        // PEAK lead-VO2 rotation (mirrors baseLTWeek): hills are gated out
                        // of PEAK and the selector locks onto one big ladder every week.
                        // Force plain intervals on alternating PEAK weeks so the lead VO2
                        // alternates intervals/ladder. Sourced pre-floor (the plain-intervals
                        // templates are 25-36min, below the PEAK floor, but all true Z5 so
                        // the 5K/10K Z5-lead still holds). 5K excluded (no ladder lock there).
                        if phase == .peak && weekInPhase % 2 == 1 && config.distance >= 10000 {
                            // Cycle the segment-count variant (load-sorted) so the lock
                            // doesn't just move from a ladder title to an interval title.
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
                        // can't keep picking them every week (forces the alternation).
                        let excludesHillsOnOffWeek = phase == .base
                        if excludesHillsOnOffWeek {
                            let withoutHills = intervalPool.filter { $0.subtype != .hillRepeats }
                            if !withoutHills.isEmpty { return withoutHills }
                        }
                        return intervalPool
                    }()

                    // Z5 policy: blocked in BASE/TAPER, the week after a Z5 week for
                    // 21K/42K, and at week==weeksToTrim (front-trimmed plans can open
                    // mid-SPEED but still mustn't lead with VO2). VO2 blocks exempt.
                    let z5Blocked = !config.isVO2Max && (
                        phase == .base || phase == .taper
                        || week == weeksToTrim
                        || (config.distance >= 21000 && lastWeekHadZ5))
                    if z5Blocked {
                        let noZ5 = preferredPool.filter { !isRealZ5($0) }
                        if let interval = selectWorkoutByTargetV3(workouts: noZ5, targetLoad: targetLoad * 0.3, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, previousWorkout: prevInterval, isDeloading: isDeloading, phaseJustStarted: phaseJustStarted, isMaintenance: false) {
                            weekWorkouts.append(("interval", interval))
                            prevInterval = interval
                        } else if let threshold = selectWorkoutByTargetV3(workouts: filteredThresholds, targetLoad: targetLoad * 0.3, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, previousWorkout: prevThreshold, isDeloading: isDeloading, phaseJustStarted: phaseJustStarted, isMaintenance: false) {
                            // No sub-Z5 interval exists (5K pools are mostly I-pace);
                            // use a threshold as the quality (Daniels' BASE quality IS LT).
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
                    // would leave a 3-day week zero easy days). See AdvancedPlanGenerator.
                    // R10: the half plan runs a 2-quality week only every other
                    // week — the off weeks stay 1 quality + easy/strides.
                    let secondQualityWeekOK = config.distance != 21097 || week % 2 == 1
                    if (phase == .speed || phase == .peak) && config.trainingDays.count >= 4
                        && secondQualityWeekOK {
                        // Determine variation type for this week
                        let weekVariation = week % 5  // Cycle every 5 weeks for variety

                        if weekVariation == 3 && !intervalPool.isEmpty && config.distance < 21097 {
                            // Every 5th week: double intervals instead of threshold —
                            // 5K/10K ONLY (half/marathon are LT/MP-dominant, no VO2-doubling).
                            // The second slot excludes milestones (standalone benchmarks)
                            // and the first slot's subtype (variety is the whole point).
                            let firstIntervalSubtype = weekWorkouts.last(where: { $0.type == "interval" })?.workout.subtype
                            let secondSlotPool = intervalPool.filter {
                                $0.subtype != .yasso800 &&
                                $0.subtype != .timeTrial &&
                                $0.subtype != firstIntervalSubtype
                            }
                            let pool2base = secondSlotPool.isEmpty ? intervalPool : secondSlotPool
                            // Weekly Z5 cap for the second slot: one Z5/week ceiling
                            // (Adv VO2 blocks excepted), no fallback (skip if none).
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

                            // R8: if the interval slot already took a rep session,
                            // the 2nd quality must be CONTINUOUS (threshold/MP) — a
                            // mile-repeats week next to an intervals week reads as
                            // two interval sessions and doubles the rep load.
                            if weekWorkouts.contains(where: { $0.type == "interval" }) {
                                let noReps = thresholdPool.filter { $0.subtype != .mileRepeats }
                                if !noReps.isEmpty { thresholdPool = noReps }
                            }

                            // 42K Pfitz MP-volume preference: force marathonPace in the
                            // threshold slot on alternating PEAK weeks (the selector
                            // otherwise picks bigger thresholds over MP). Bypasses the
                            // progression filter via `filteredThresholds`.
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

                    // No dedicated 3rd MP slot: the LR already carries MP volume, and
                    // a 3rd hard session would force back-to-back hard days in a 5-day
                    // non-LR window (Pfitz prescribes 2 quality + LR-with-MP, not 3 + 1).
            }

            // LONG RUN
            var shouldAddLong = true
            var longRunTypes: [WorkoutSubtype] = [.long, .steadyLong]

            if config.distance == 5000 {
                // 5K: Int gets no long runs (too short to warrant LR work).
                shouldAddLong = false
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
            // at Int's low baseLoad the selector otherwise picks light steadyLong every
            // week, so the half runner never does any HMP work.
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
                // fastFinish: long-ish easy + race-pace tail. The catalog mixes
                // 5K/10K/MP tails; load+duration matching picks the right one.
                if WorkoutSubtype.fastFinish.eligibleDistances.contains(config.distance) {
                    longRunTypes.append(.fastFinish)
                }
                let peakWeekIndex = week - baseDur - speedDur
                if config.distance == 10000 && peakDur >= 2 {
                    // 10K: alternate raceRehearsal10K with plain steady in PEAK to
                    // guarantee the tune-up exposure (selector picks steady otherwise).
                    // Drop fastFinish on MP-segment weeks or it out-scores the rehearsal.
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

            // R8/R10: a race-rehearsal week is built AROUND the rehearsal — it
            // carries no other quality at all (no standalone MP, no yasso/
            // threshold/intervals). The freed slots fall to the easy fill, so
            // the week reads rehearsal + easy running (the R10 "extreme week"
            // fix: Yasso 59min + Threshold 41min + Rehearsal 165min was a real
            // Int marathon week).
            if weekWorkouts.contains(where: {
                $0.workout.subtype == .raceRehearsalM || $0.workout.subtype == .raceRehearsalHM
            }) {
                weekWorkouts.removeAll {
                    $0.type == "interval" || $0.type == "interval2" || $0.type == "threshold"
                        || $0.workout.subtype == .marathonPace
                }
            }

            // EASY RUN (fills remaining slots). Daniels: 70-80% of weekly volume
            // should be easy, so this slot is easy by default.
            if weekWorkouts.count < maxWorkoutsPerWeek {
                if !easyRuns.isEmpty {
                    // The 3rd slot is pure easy: at 4 days/wk Int already carries 2
                    // quality + a race-pace long, so a progression would leave zero
                    // recovery. Variety comes from the rotating long-run type.
                        let easyLoadMult = 0.15
                        let easyPool = easyRuns
                        let easyTargetDur = Int(targetDuration * 0.30)

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
                // BASE wants easy aerobic volume, not a 2nd Z3 progression — keep base
                // polarized (the SPEED/PEAK progression already supplies tempo variety).
                if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.15, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, isMaintenance: false) {
                    weekWorkouts.append(("easy_base", easy))
                }
            }

            // Fill remaining slots (4 workouts; 5 for 21K+).
            while weekWorkouts.count < maxWorkoutsPerWeek {
                // Fill remaining trainingDays with easy runs. For 21K+ prefer a longer
                // "medium-long" (Pfitz-style) first fill so weekly volume grows at 4+ days.
                let isLongRace = config.distance >= 21000
                let isFirstFill = !weekWorkouts.contains { $0.type.contains("fill") }
                let easyTargetMin: Int = {
                    if isLongRace && isFirstFill {
                        return min(90, max(60, Int(targetDuration * 0.30)))
                    } else {
                        return min(60, max(35, Int(targetDuration * 0.22)))
                    }
                }()
                // Per-slot LOAD multipliers drive the pick (load match dominates).
                let mlrLoadMult = 0.18
                let fillLoadMult = 0.12
                let easyTargetLoad = targetLoad * (isLongRace && isFirstFill ? mlrLoadMult : fillLoadMult)
                if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: easyTargetLoad, targetDuration: easyTargetMin, usedIds: &usedIds, isMaintenance: false) {
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
