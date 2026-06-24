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
                        // PEAK lead-VO2 rotation (mirrors baseLTWeek): hills are gated
                        // out of PEAK and the load selector parks on the single biggest
                        // ladder every week (5-6× the same ladder title). On alternating
                        // PEAK weeks force plain intervals so the lead VO2 alternates
                        // intervals/ladder instead of locking. Sourced from filteredIntervals
                        // (pre-floor): the only plain-intervals templates are 25-36min, below
                        // the PEAK min-interval floor that otherwise leaves the 61min ladder
                        // as the sole survivor — so the floor is bypassed for this slot only.
                        // All plain-intervals templates are true Z5 (VO2), so the 5K/10K
                        // Z5-lead requirement still holds.
                        // 5K excluded: its PEAK is 5K-pace/intervals driven (no ladder
                        // lock), and forcing the light plain-intervals templates there
                        // displaces the heavier race-specific work.
                        if phase == .peak && weekInPhase % 2 == 1 && config.distance >= 10000 {
                            // Cycle the segment-count variant per forced-interval week
                            // (load-sorted) so back-to-back interval weeks don't all
                            // land on the heaviest template — otherwise the lock just
                            // moves from one ladder title to one interval title.
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
                    
                    // Threshold in SPEED/PEAK only (not BASE). Gated to 4+ day plans:
                    // a 2nd quality session would leave a 3-day week zero easy days
                    // (quality + quality + long), so the accessible 3-day tier caps at
                    // one quality/week and fills the freed day with aerobic running.
                    if (phase == .speed || phase == .peak) && config.trainingDays.count >= 4 {
                        // Determine variation type for this week
                        let weekVariation = week % 5  // Cycle every 5 weeks for variety

                        if weekVariation == 3 && !intervalPool.isEmpty && config.distance < 21097 {
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

                            // 42K Pfitz MP-volume preference: force marathonPace in the
                            // threshold slot on alternating PEAK weeks (Pfitz's two MP
                            // exposures). The selector otherwise picks bigger thresholds
                            // over MP; MP entries are continuous so bypass the progression
                            // filter via `filteredThresholds`.
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

            // EASY RUN (fills remaining slots). Daniels: 70-80% of weekly volume
            // should be easy, so this slot is easy by default.
            if weekWorkouts.count < maxWorkoutsPerWeek {
                if !easyRuns.isEmpty {
                    // The 3rd slot is pure easy: at 4 days/wk Int already carries 2
                    // quality + a race-pace long, so a progression here would leave
                    // zero recovery. Variety comes from the rotating long-run type.
                        let easyLoadMult = 0.15
                        let easyPool = easyRuns
                        let easyTargetDur = Int(targetDuration * 0.30)

                        // Force mediumLong on alternating midweek slots (marathon/HM):
                        // without this the selector picks generic `easy` (60-80min) over
                        // `mediumLong` (85-110min) on duration matching at lower target
                        // loads, and Pfitz prescribes a weekday Medium-Long Run. 10K/5K
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

            lastWeekHadZ5 = weekWorkouts.contains { isRealZ5($0.workout) }
            workoutsByWeek[week] = weekWorkouts
        } while false
    }
}
