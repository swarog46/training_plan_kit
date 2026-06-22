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
        // `repeat { … } while false` preserves the former for-loop's `continue`
        // semantics now that the per-week body is a standalone method: a
        // `continue` (maintenance / race week) skips the rest of the body and
        // falls through to the (false) while-check, exactly as it skipped to the
        // next loop iteration before. Behavior is byte-identical.
        repeat {
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
                        // BASE off-weeks (Int / Adv / Cmp): actively exclude
                        // hill repeats so the load-target selector doesn't keep
                        // picking them out of the unfiltered pool. Without
                        // exclusion hills win the off-weeks too (they score
                        // cleanly against BASE load targets), and the
                        // "alternating" rule is meaningless. This is what
                        // actually forces variety on the off-weeks.
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
                        if let interval = selectWorkoutByTargetV3(workouts: noZ5, targetLoad: targetLoad * 0.3, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, previousWorkout: prevInterval, isDeloading: isDeloading, phaseJustStarted: phaseJustStarted, isMaintenance: false) {
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

            // LONG RUN
            var shouldAddLong = true
            var longRunTypes: [WorkoutSubtype] = [.long, .steadyLong]

            if config.distance == 5000 {
                // 5K: Int gets no long runs (5K is too short to warrant
                // marathon-style endurance work, and the tier lacks the
                // aerobic base to absorb a weekly 75min LR).
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
                // fastFinish: universal — long-ish easy + race-pace tail. The
                // catalog mixes 5K/10K/MP tails; load+duration matching picks
                // the right one for each plan. Skipped for competitive plans:
                // fastFinish caps at 100min, which is way short of the 160-200min
                // peak LR target competitive needs. Letting it into the pool
                // means the selector picks it as the "LR" because its load
                // matches better than a true 150-200min steadyLong, undercutting
                // peak volume — Pfitz never uses sub-100min LRs in marathon peak.
                if WorkoutSubtype.fastFinish.eligibleDistances.contains(config.distance) {
                    longRunTypes.append(.fastFinish)
                }
                let peakWeekIndex = week - baseDur - speedDur
                if config.distance == 10000 && peakDur >= 2 {
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
                // Marathon surprise weeks: shorten the long run instead of skipping
                // it (5d). 90min keeps the aerobic stimulus without the recovery cost.
                if isSurpriseWeek && isMarathon {
                    maxDurationMins = min(maxDurationMins, 90)
                }
                pool = pool.filter { $0.duration <= maxDurationMins * 60 }

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
                if let longRun = selectWorkoutByTargetV3(workouts: pool, targetLoad: targetLoad * lrLoadMult, targetDuration: longRunTargetMins, usedIds: &usedIds, isMaintenance: false) {
                    weekWorkouts.append(("long", longRun))
                    prevLongRunMins = Int(longRun.duration / 60)
                }
            }

            // EASY RUN (fills remaining slots)
            //
            // Daniels' rule of thumb: 70-80% of weekly volume should be easy. With
            // a 3-day/wk beginner plan that means 1 hard + 1 long + 1 EASY. The
            // previous logic defaulted this third slot to a progression run for
            // most level/distance combos, which collapsed the easy share to ~10%
            // empirically (per PLAN_GENERATION_ANALYSIS_2026.md). Flipped to
            // easy-by-default; progression is the occasional ~30% variant.
            if weekWorkouts.count < maxWorkoutsPerWeek {
                if !easyRuns.isEmpty {
                    // INTERMEDIATE (beginner routes to BeginnerPlanGenerator): the
                    // 3rd slot is pure easy. At 4 days/wk Int already carries 2
                    // quality + a race-pace long, so a progression here would leave
                    // zero recovery. Variety comes from the rotating long-run type.
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
                        let easyLoadMult = 0.15
                        let easyPool = easyRuns
                        let easyTargetDur = Int(targetDuration * 0.30)

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
                // BASE wants easy aerobic volume, not a 2nd Z3 progression — keep
                // the base polarized (the every-3rd-week SPEED/PEAK progression
                // already supplies tempo variety for intermediates).
                if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.15, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, isMaintenance: false) {
                    weekWorkouts.append(("easy_base", easy))
                }
            }

            // Fill remaining slots (4 workouts; 5 for 21K+).
            while weekWorkouts.count < maxWorkoutsPerWeek {
                // Intermediate (beginner routes to BeginnerPlanGenerator): fill
                // remaining trainingDays with easy runs. Used to bail here, leaving
                // days unscheduled — major reason marathon plans were ~30% under
                // Higdon volume.
                //
                // For 21K+ we prefer a longer easy ("medium-long" Pfitz-style)
                // for the first fill slot so weekly volume actually grows
                // when trainingDays.count is 4+.
                let isLongRace = config.distance >= 21000
                let isFirstFill = !weekWorkouts.contains { $0.type.contains("fill") }
                let easyTargetMin: Int = {
                    if isLongRace && isFirstFill {
                        return min(90, max(60, Int(targetDuration * 0.30)))
                    } else {
                        return min(60, max(35, Int(targetDuration * 0.22)))
                    }
                }()
                // Per-slot LOAD multipliers determine which workout the
                // selector picks (load match dominates the score). Defaults
                // (0.18 MLR, 0.12 fill) target ~3600 / ~2400 load.
                let mlrLoadMult = 0.18
                let fillLoadMult = 0.12
                let easyTargetLoad = targetLoad * (isLongRace && isFirstFill ? mlrLoadMult : fillLoadMult)
                if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: easyTargetLoad, targetDuration: easyTargetMin, usedIds: &usedIds, isMaintenance: false) {
                    weekWorkouts.append((isLongRace && isFirstFill ? "medium_long_fill" : "easy_fill", easy))
                } else {
                    break  // Catalog exhausted
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

            lastWeekHadZ5 = weekWorkouts.contains { isRealZ5($0.workout) }
            workoutsByWeek[week] = weekWorkouts
        } while false
    }
}
