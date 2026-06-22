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
            
            // Surprise weeks inject variety (shorter LR, threshold → progression
            // swap) to prevent staleness in long plans.
            let isSurpriseWeek = surpriseWeeks.contains(week)

            // PEAK milestone cadence — computed at week scope so both the
            // pool gate AND the per-level selection logic below can read it.
            let milestoneCadence = max(3, peakDur / 2)
            let yassoWeek = phase == .peak && (weekInPhase % milestoneCadence) == 0
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
            let peakTTWeek = config.distance >= 21000 && phase == .peak
                && (weekInPhase % milestoneCadence) == milestoneCadence / 2
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
                let isOnboarding = phase == .base && weekInPhase <= 1
                let minIntervalMinutes: Int = {
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
                        let ramped = rampVariantsByPlanWeek(variants, week: week)
                        if !ramped.isEmpty {
                            result = result.filter { $0.subtype != rampSub } + ramped
                        }
                    }
                }
                return result
            }()
            
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
                // Pfitz-style race week: 3 short sessions before race day — a
                // progression tune-up, an easy + strides, and a short shakeout.
                // Total ~120min, matching Pfitz's ~25km race-week mileage at light pace.
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
                        // Second workout: easy run, hard-capped at 50min. The unbounded
                        // `targetDuration * 0.30` lands ~90min for competitive 42K — too
                        // long 3 days pre-race. So bypass the global >= 60min easy filter
                        // AND hard-filter the pool to <= 50min before the selector, or
                        // load scoring picks the 90-110min options over the duration target.
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
                    // strength foundation), alternating with other interval work
                    // week-to-week so five straight weeks of one hill template don't
                    // read as a single repeated workout. Falls back to plain intervals.
                    let preferHillsThisWeek: Bool = {
                        guard phase == .base, weekInPhase >= 1 else { return false }
                        // fitter tiers alternate a milestone subtype in BASE; beginners stay plain
                        return config.profile.alternatesMilestoneInBase && weekInPhase % 2 == 1
                    }()
                    let preferredPool: [Workout] = {
                        // PEAK milestone weeks: if the pool has the milestone
                        // subtype (Yasso 800s / time trial), prefer it so it
                        // doesn't lose the load competition to ladders/hills and
                        // get under-picked.
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
                        // BASE off-weeks: actively exclude hill repeats so the
                        // load-target selector doesn't keep picking them out of the
                        // unfiltered pool (they score cleanly against BASE load
                        // targets and would win the off-weeks too, making the
                        // "alternating" rule meaningless). This is what forces variety.
                        let excludesHillsOnOffWeek = phase == .base
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
                        if baseLTWeek,
                           let threshold = selectWorkoutByTargetV3(workouts: filteredThresholds, targetLoad: targetLoad * 0.3, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, previousWorkout: prevThreshold, isDeloading: isDeloading, phaseJustStarted: phaseJustStarted, isMaintenance: false) {
                            weekWorkouts.append(("threshold", threshold))
                            prevThreshold = threshold
                        } else if let interval = selectWorkoutByTargetV3(workouts: noZ5, targetLoad: targetLoad * 0.3, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, previousWorkout: prevInterval, isDeloading: isDeloading, phaseJustStarted: phaseJustStarted, isMaintenance: false) {
                            weekWorkouts.append(("interval", interval))
                            prevInterval = interval
                        } else if let threshold = selectWorkoutByTargetV3(workouts: filteredThresholds, targetLoad: targetLoad * 0.3, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, previousWorkout: prevThreshold, isDeloading: isDeloading, phaseJustStarted: phaseJustStarted, isMaintenance: false) {
                            // No sub-Z5 interval template exists for this distance
                            // (5K pools are mostly I-pace). Use a threshold session
                            // as the week's quality instead of breaking the policy —
                            // Daniels' BASE-phase quality IS the LT run.
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
                    
                    // Threshold in SPEED/PEAK only (not BASE). Gated to 4+ day plans:
                    // a 2nd quality session would leave a 3-day week zero easy days
                    // (quality + quality + long), so the accessible 3-day tier caps at
                    // one quality/week and fills the freed day with aerobic running.
                    if (phase == .speed || phase == .peak) && config.trainingDays.count >= 4 {
                        // Determine variation type for this week
                        let weekVariation = week % 5  // Cycle every 5 weeks for variety

                        if isSurpriseWeek {
                            // Surprise week: Replace threshold with progression run (intensity drop)
                            var progressivePool = filterWorkoutsBySubtypeV3(workouts: workoutPool, subtypes: [.progression])
                                .filter { $0.duration >= 40 * 60 }
                            if config.distance < 42000 {
                                progressivePool = progressivePool.filter { $0.duration <= 70 * 60 }  // Cap at 1h10m for <42K
                            }
                            if let progressive = selectWorkoutByTargetV3(workouts: progressivePool, targetLoad: targetLoad * 0.25, targetDuration: Int(targetDuration * 0.30), usedIds: &usedIds, isMaintenance: false) {
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
                            // threshold slot on alternating PEAK weeks (Pfitz prescribes
                            // two MP exposures — one LR-with-MP, one dedicated MP run).
                            // The default selector picks bigger thresholds over MP
                            // (whose Z3 load sits below threshold workouts), so the
                            // dedicated "12mi @ MP" run never appeared. MP entries are
                            // continuous so they fail the progression filter — bypass it
                            // by pulling from `filteredThresholds`.
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
                // Adv 5K: Daniels' Phase II prescribes optional ~75min long
                // runs on Sundays — pure aerobic base for the speed work.
                // Schedule LR in BASE/SPEED only; PEAK stays sharp/speed-focused.
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
                longRunTypes.append(.progressiveLong)
                if phase == .speed {
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
                    // 10K: alternate raceRehearsal10K (5K tune-up simulation) with
                    // plain steady in PEAK. The selector picks steadyLong/fastFinish
                    // at default loads every week, so force the alternation to guarantee
                    // the tune-up exposure. On MP-segment weeks also drop fastFinish, or
                    // it out-scores raceRehearsal10K (closer 10K-LR duration).
                    let isMPSegmentWeek = peakWeekIndex % 2 == 0
                    if isMPSegmentWeek {
                        longRunTypes.removeAll {
                            $0 == .steadyLong || $0 == .long
                            || $0 == .progressiveLong || $0 == .fastFinish
                        }
                    }
                }
                // (Beg 21K/42K mid-PEAK rehearsal is handled in BeginnerPlanGenerator.)
            }
            
            // Surprise week: for short-race plans (5K/10K/21K) replace the long
            // run with an easy "surprise" run. For marathon, the user needs every
            // long run they can get in SPEED+PEAK — instead of skipping, just
            // shorten the long run cap so it still happens but lighter.
            let isMarathon = config.distance >= 30000
            if isSurpriseWeek && !isMarathon {
                if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.12, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, isMaintenance: false) {
                    weekWorkouts.append(("easy_surprise", easy))
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
                // Marathon surprise/cutback weeks: shorten the long run instead of
                // skipping it (5d). Cap at 90min for the aerobic stimulus without the
                // recovery cost — but never below ~65% of the surrounding peak long
                // run, so a mid-block cutback doesn't collapse to the 60min floor
                // (~9km) and break the long-run thread.
                if isSurpriseWeek && isMarathon {
                    let cutbackFloor = Int(Double(prevLongRunMins) * 0.65)
                    maxDurationMins = min(maxDurationMins, max(90, cutbackFloor))
                }
                pool = pool.filter { $0.duration <= maxDurationMins * 60 }

                // Filter: ALL long runs (including progressive) must be >= 60 minutes
                let minLongRunMins = 60
                pool = pool.filter { workout in
                    return workout.duration >= minLongRunMins * 60
                }

                // Progressive long-run target by distance + level + phase, from the
                // config's (start, peak) anchors. Without explicit targets the load-
                // dominated selector picks short LRs even when targetDuration is high.
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
                    // 5K (Adv, no longRunProgression): weekly-duration percentage.
                    longRunTargetMins = Int(targetDuration * 0.50)
                }

                // LR load multiplier — bumped for competitive so the selector
                // prefers the 150-200min steadyLong / raceRehearsalM in PEAK
                // over shorter alternatives whose load happens to match the
                // default 0.35 multiplier. Without this, a 85min fastFinish
                // (load ~10700) wins against a 150min steadyLong (load ~14500)
                // even when the duration target is 160min.
                let lrLoadMult = config.profile.longRunSnapLoadFraction
                // Monotonic enforcement (shared): non-decreasing in BUILD, non-
                // increasing in TAPER/RACE, with a 65%-of-peak cutback floor so a
                // down-week long run never collapses to the 60min catalog minimum.
                pool = applyLongRunMonotonic(pool: pool, phase: phase, prevLongRunMins: prevLongRunMins)
                if let longRun = selectWorkoutByTargetV3(workouts: pool, targetLoad: targetLoad * lrLoadMult, targetDuration: longRunTargetMins, usedIds: &usedIds, isMaintenance: false) {
                    weekWorkouts.append(("long", longRun))
                    prevLongRunMins = Int(longRun.duration / 60)
                }
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
                    if !progressionWeek {
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
                        // Already have a long run — BASE wants easy aerobic
                        // volume here, not a 2nd Z3 progression. The every-3rd-
                        // week progression (slot above) already supplies the
                        // controlled tempo touch; stacking another keeps Adv in
                        // the gray zone (~50% easy) instead of polarized (~80%,
                        // like the Cmp tier). Default this base slot to easy.
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
                    // 21K+ Advanced: fill volume with EASY aerobic running.
                    // (Previously alternated progression/easy here, which — on top
                    // of the every-3rd-week progression and the long run — left
                    // the half/marathon Adv plans ~50% easy. The endurance base
                    // for a 21K+/Adv plan wants easy volume, not more Z3 fill.)
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

            // Cap strides at 1/week — Daniels prescribes ~2/week max but with
            // 5-day plans that becomes excessive. Replace any extra strides with
            // the closest-duration plain easy run. Use the UNFILTERED easy pool
            // here — the competitive >= 60min filter applied to `easyRuns` would
            // otherwise force taper strides to be replaced with 60min easies,
            // wrecking the taper volume target.
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

            // Peak-volume soft cap (marathon Adv/Cmp). Pfitz 18/70 and 18/85 push
            // 9-10h weeks at peak — faithful to the books, but above what most
            // amateurs choosing these plans can absorb without breaking down. Shed
            // the excess from the largest aerobic FILL (medium-long / easy) only —
            // never the long run, the quality session, or MP work — and let the
            // freed day become recovery. Halves and shorter never approach the cap.
            let weeklyCapMinutes: Int = {
                guard config.distance >= 42195 else { return .max }
                return 480   // Adv marathon ~8.0h ceiling (was up to 8.4h)
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
        } while false
    }
}
