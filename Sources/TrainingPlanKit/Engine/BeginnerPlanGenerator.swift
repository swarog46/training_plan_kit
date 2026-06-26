//
//  BeginnerPlanGenerator.swift
//  RunPlan
//
//  Beginner-tier plan generator. Owns the beginner week assembly; inherits the
//  shared skeleton (phase math, pools, targets, finalization) from PlanGeneratorV3.
//

import Foundation

final class BeginnerPlanGenerator: PlanGeneratorV3 {
    // Counts hard-quality (threshold-branch) weeks placed so far. Every other one
    // routes to hills instead of threshold (10K+ only) so the season's few quality
    // weeks span >=2 TYPES (threshold + hills) rather than 100% threshold — both are
    // beginner-safe LT/strength at similar load. Single-use generator ⇒ 0 is fine.
    private var begHardQualityCount = 0

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
                // Reset variety tracking at phase boundaries. Persisting across phases
                // lets the cumulative penalty drag good matches down to short easies.
                usedIds.removeAll()
            }
            prevPhase = phase
            
            // Calculate targets
            let rawTargets = calculateWeeklyTargetsV3(weekInPlan: week, weekInPhase: weekInPhase, phase: phase, phaseDurations: phaseDurations, config: config)
            // ACWR ramp cap (DURATION): a week's volume may not exceed 1.25× the recent
            // 3-week max — kills single-week spikes while letting post-deload weeks
            // rebound. Load scales with the cut so intensity/min is preserved.
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
            let targetLoad = targets.load
            let targetDuration = targets.duration
            
            let maxWorkoutsPerWeek = config.trainingDays.count
            
            // Max-rest filter applies only to density-driven VO2 subtypes (intervals/
            // pyramid/ladder); hills/yasso/mile-reps/TT use long recoveries by design
            // and would vanish under the 60s advanced cap.
            let maxRestPerInterval = config.profile.intervalRestCapSeconds

            // Beginner: never a yasso week (yasso is Int/Adv only) — folds to false.

            // PEAK milestone cadence — computed at week scope so both the
            // pool gate AND the per-level selection logic below can read it.
            let milestoneCadence = max(3, peakDur / 2)
            // Time trials: a mid-plan SPEED recalibration check (re-measure fitness
            // with the plan still ahead) + the late PEAK tune-up. Recalib falls back
            // to the last BASE week if a plan has no SPEED phase.
            let recalibTTWeek = (speedDur > 0)
                ? (phase == .speed && weekInPhase == speedDur / 2)
                : (phase == .base && weekInPhase == baseDur - 1)
            // Late PEAK tune-up TT only for the longer plans (half+); short 5K/10K
            // blocks keep just the mid-plan recalib. Skip the PEAK week the beginner
            // half/marathon forces a race rehearsal onto so TT + rehearsal don't stack
            // into one brutal week.
            let rehearsalWeekInPhase = (config.distance >= 21000 && peakDur >= 2)
                ? max(1, (peakDur - 1) / 2) : -1
            let peakTTWeek = config.distance >= 21000 && phase == .peak
                && (weekInPhase % milestoneCadence) == milestoneCadence / 2
                && weekInPhase != rehearsalWeekInPhase
            let ttWeek = recalibTTWeek || peakTTWeek

            // (Hills/ladders climb one variant per ~2 plan weeks via
            // rampVariantsByPlanWeek below — see PlanGeneratorV3.)
            let intervalPool: [Workout] = {
                var pool = filterIntervalsByMaxRest(filteredIntervals, maxRest: maxRestPerInterval)
                // Gate hill repeats: BASE/SPEED only (strength, then race-specific),
                // skipping each phase's first week so the runner adapts first.
                // (The 10K+ hard-quality alternation routes its OWN phase-eligible hills
                // from filteredIntervals below — it does not read this gated pool.)
                let hillsAllowed = (phase == .base || phase == .speed) && weekInPhase >= 1
                if !hillsAllowed {
                    pool = pool.filter { $0.subtype != .hillRepeats }
                }

                // Yasso 800s are Int/Adv only — never in a beginner week.
                pool = pool.filter { $0.subtype != .yasso800 }
                // Gate Time Trials by milestone cadence (2-3 per PEAK cycle, never sharing).
                if !ttWeek {
                    pool = pool.filter { $0.subtype != .timeTrial }
                }

                // Min-duration floor by phase+level so the session engages VO2/T-pace;
                // onboarding (BASE wks 0-1) gets the lighter floor.
                let isOnboarding = phase == .base && weekInPhase <= 1
                // Deload build weeks relax the floor to the onboarding 22 — the full
                // PEAK floor can leave only one heavy survivor, forcing the "recovery"
                // pick onto the monster session. 22 still excludes the trivial 20-min ladder.
                let minIntervalMinutes: Int = {
                    if isDeloading && phase != .race { return 22 }
                    if isOnboarding { return 22 }
                    return config.profile.minIntervalMinutes(phase: phase)
                }()
                let filtered = pool.filter { $0.duration >= minIntervalMinutes * 60 }
                // Fall back to the full pool if the floor excluded everything.
                var result = filtered.isEmpty ? pool : filtered
                // 5K/10K: the lead VO2 session must be true Z5. The catalog tags ~half of
                // intervals/ladder templates Z4 (correct on LT-dominant half/marathon, but
                // on 5K/10K a Z4 "VO2" renders SLOWER than race). Drop the Z4-only VO2-family
                // templates when true-Z5 ones exist; hills/mile-reps left untouched.
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
            
            // RACE week: skip quality entirely. 5K/10K keep taperDur=1 to preserve
            // build time, so their last week is phase==.taper but still needs the same
            // hands-off treatment (else they'd end with a hard session days before race).
            let isLastWeekOfPlan = week == actualWeeksToGenerate - 1
            let isRaceWeek = phase == .race
                || (phase == .taper && isLastWeekOfPlan)
            if isRaceWeek {
                // Pfitz-style race week: 3 short sessions (progression tune-up,
                // easy+strides, shakeout) ~120min total.
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
                        // Drop <4-rep strides (keep plain easy + 4-6-rep strides) so
                        // the shakeout never lands on a 2-rep stride.
                        let shakeoutPool = filterWorkoutsBySubtypeV3(workouts: workoutPool, subtypes: easySubtypes)
                            .filter { $0.duration >= 20 * 60 && $0.duration <= 35 * 60 }
                            .filter { $0.subtype != .strides || stridesRepCount($0) >= 4 }
                        if let shakeout = selectWorkoutByTargetV3(workouts: shakeoutPool, targetLoad: targetLoad * 0.2, targetDuration: 25, usedIds: &usedIds, isMaintenance: false) {
                            weekWorkouts.append(("shakeout_race", shakeout))
                        }
                    } else {
                        // Second workout: easy run hard-capped at 50min (pre-filtered
                        // <= 50min so load scoring can't pick the long ones). Drop
                        // <4-rep strides so a 2-rep stride never slips into race week.
                        let raceEasyPool = filterWorkoutsBySubtypeV3(workouts: workoutPool, subtypes: easySubtypes)
                            .filter { $0.duration <= 50 * 60 }
                            .filter { $0.subtype != .strides || stridesRepCount($0) >= 4 }
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
            // VO2 block: VO2 IS the point — carry the Z5 dose into BASE too, but skip
            // pure onboarding (BASE wk 0) so week 1 isn't a VO2 detonation.
            let isVO2Onboarding = config.isVO2Max && phase == .base && weekInPhase == 0
            if config.isVO2Max && phase == .base && weekInPhase >= 1 {
                shouldAddIntervals = true
            }
            // TAPER: Still add intervals/threshold but at reduced intensity (handled by targetLoad)

            // Helper: Filter thresholds by progression (prefer shorter intervals early, longer later)

            // VO2 block: select a week-indexed Z5 DOSE (ramps ~12→32min) from the
            // true-Z5 pool — the dose ladder (intervals/ladderIntervals) + fivekPace.
            // This is the lead quality every non-onboarding week, so MOST weeks carry
            // a true VO2 session and the dose climbs across the block instead of
            // pinning at fivekPace's fixed 20min. The dose IS the week's fitness
            // check, so it takes precedence over the standalone recalibration TT.
            if shouldAddIntervals, config.isVO2Max, !isVO2Onboarding {
                let doseTarget = vo2Z5DoseTarget(week: week, isDeloading: isDeloading)
                let dosePool = vo2DoseMatched(intervalPool, targetMinutes: doseTarget)
                if !dosePool.isEmpty {
                    if let interval = selectWorkoutByTargetV3(workouts: dosePool, targetLoad: targetLoad * 0.4, targetDuration: Int(targetDuration * 0.3), usedIds: &usedIds, previousWorkout: prevInterval, isDeloading: isDeloading, phaseJustStarted: phaseJustStarted, isMaintenance: false) {
                        weekWorkouts.append(("interval", interval))
                        prevInterval = interval
                    }
                }
                // Z5 dose placed — skip the standard interval/threshold alternation.
                if !weekWorkouts.isEmpty { shouldAddIntervals = false }
            }

            if shouldAddIntervals {
                    // Alternate: even weeks = intervals, odd = threshold. On a TT week
                    // take the interval branch and prefer the TT subtype so the
                    // recalibration checkpoint isn't lost to standard intervals.
                    if (week % 2 == 0 || ttWeek) && !intervalPool.isEmpty {
                        let begPool: [Workout] = {
                            if ttWeek {
                                let ttOnly = intervalPool.filter { $0.subtype == .timeTrial }
                                if !ttOnly.isEmpty { return ttOnly }
                            }
                            // PEAK = race sharpening for 5K/10K beginners: bias toward
                            // race-specific work (strides @ ~5K pace) + the tune-up TT,
                            // drop BASE-phase hills. (fivekPace intervals are too heavy
                            // for a ~9k-load beginner week, so they're not in the pool.)
                            if phase == .peak && config.distance <= 10000 {
                                let raceSpecific = intervalPool.filter { $0.subtype != .hillRepeats }
                                if !raceSpecific.isEmpty { return raceSpecific }
                            }
                            return intervalPool
                        }()
                        if let interval = selectWorkoutByTargetV3(workouts: begPool, targetLoad: targetLoad * 0.4, targetDuration: Int(targetDuration * 0.3), usedIds: &usedIds, previousWorkout: prevInterval, isDeloading: isDeloading, phaseJustStarted: phaseJustStarted, isMaintenance: false) {
                            weekWorkouts.append(("interval", interval))
                            prevInterval = interval
                        }
                    } else if !filteredThresholds.isEmpty {
                        // HARD-quality week. 10K+: alternate every other one to a hill
                        // session so quality spans hills + threshold (not 100% threshold).
                        // Hills sit at ~threshold load ⇒ a TYPE swap, not added intensity;
                        // the remaining threshold weeks still progress. Hills come from
                        // filteredIntervals (not the gated intervalPool) so they can land on
                        // a phase-first hard week — already a hard threshold there anyway.
                        let hillPhaseOK = (phase == .base || phase == .speed || phase == .peak)
                        var hillsThisWeek = (config.distance >= 10000 && !isDeloading && hillPhaseOK)
                            ? filteredIntervals.filter { $0.subtype == .hillRepeats }
                            : []
                        if hillsThisWeek.count > 1 {
                            let ramped = rampVariantsByPlanWeek(hillsThisWeek, week: week)
                            if !ramped.isEmpty { hillsThisWeek = ramped }
                        }
                        // Count only hill-ELIGIBLE hard weeks so deload/ineligible weeks
                        // don't burn a parity slot; 1st eligible stays threshold, then alternate.
                        let hillsEligible = !hillsThisWeek.isEmpty
                        let routeToHills = hillsEligible && begHardQualityCount % 2 == 1
                        if hillsEligible { begHardQualityCount += 1 }
                        if routeToHills,
                           let hill = selectWorkoutByTargetV3(workouts: hillsThisWeek, targetLoad: targetLoad * 0.4, targetDuration: Int(targetDuration * 0.3), usedIds: &usedIds, previousWorkout: prevInterval, isDeloading: isDeloading, phaseJustStarted: phaseJustStarted, isMaintenance: false) {
                            weekWorkouts.append(("interval", hill))
                            prevInterval = hill
                        } else {
                            // Apply progression filter to thresholds
                            let progressedThresholds = filterThresholdsByProgression(filteredThresholds, week: week, totalWeeks: actualWeeksToGenerate)
                            let thresholdPool = progressedThresholds.isEmpty ? filteredThresholds : progressedThresholds

                            if let threshold = selectWorkoutByTargetV3(workouts: thresholdPool, targetLoad: targetLoad * 0.4, targetDuration: Int(targetDuration * 0.35), usedIds: &usedIds, previousWorkout: prevThreshold, isDeloading: isDeloading, phaseJustStarted: phaseJustStarted, isMaintenance: false) {
                                weekWorkouts.append(("threshold", threshold))
                                prevThreshold = threshold
                            }
                        }
                    }
            }

            // LONG RUN
            var shouldAddLong = true
            var longRunTypes: [WorkoutSubtype] = [.long, .steadyLong]

            if config.distance == 5000 {
                // 5K Beginner: no long runs (too short to warrant LR work).
                shouldAddLong = false
            } else if config.distance == 10000 {
                // 10K Beginner: weekly long run in BASE/SPEED/PEAK (Pfitz/Higdon).
                longRunTypes = [.long, .steadyLong]
                shouldAddLong = phase == .base || phase == .speed || phase == .peak
            } else if config.distance >= 21000 {
                // 21K+ Beginner: long run every BASE/SPEED/PEAK week AND a reduced
                // one in TAPER (mirrors Int/Adv) — avoids the endurance cliff of
                // going from the peak long run straight to no long run. Duration is
                // driven by the config's taper anchor; applyLongRunMonotonic keeps
                // it below the peak. RACE week stays hands-off (handled above).
                longRunTypes = [.long, .steadyLong]
                shouldAddLong = phase == .base || phase == .speed || phase == .peak || phase == .taper
            }

            // SPEED + PEAK: add progressiveLong (Z2→Z3/MP) to break up the wall of
            // aerobic that pure steadyLong selection creates. BASE stays pure aerobic.
            // No progressive-forcing for Beg — Pfitz "Just Finish" half IS pure-aerobic.
            if phase == .speed || phase == .peak {
                longRunTypes.append(.progressiveLong)
            }
            // TAPER (21K+ only): open the pool to progressiveLong so the reduced
            // taper long run can reach its declared taper anchor (the catalog's
            // mid-length long runs are progressiveLong); without it the selector
            // snaps to the shortest steadyLong, undershooting the anchor.
            if phase == .taper && config.distance >= 21000 {
                longRunTypes.append(.progressiveLong)
            }

            // PEAK weeks: open the long-run pool to the distance-matched race
            // rehearsal (eligibleDistances pins each to one race).
            if phase == .peak {
                for rehearsal: WorkoutSubtype in [.raceRehearsalM, .raceRehearsalHM, .raceRehearsal10K]
                where rehearsal.eligibleDistances.contains(config.distance)
                    // 10K-pace rehearsal is a quality session — Int/Adv only, not beginner.
                    && rehearsal != .raceRehearsal10K {
                    longRunTypes.append(rehearsal)
                }
                // fastFinish: long-ish easy + race-pace tail. The catalog mixes
                // 5K/10K/MP tails; load+duration matching picks the right one.
                if WorkoutSubtype.fastFinish.eligibleDistances.contains(config.distance) {
                    longRunTypes.append(.fastFinish)
                }
                let peakWeekIndex = week - baseDur - speedDur
                if config.distance >= 21000 && peakDur >= 2 {
                    // Beg 21K/42K: force one race-pace rehearsal in mid-PEAK so the
                    // runner doesn't reach race day having never run at goal pace
                    // (the selector picks steady aerobic every week otherwise).
                    let rehearsalWeekIdx = max(1, (peakDur - 1) / 2)
                    if peakWeekIndex == rehearsalWeekIdx {
                        // Drop fastFinish too: at the half's shorter peak-LR target it
                        // out-matches raceRehearsalHM and the half never gets a rehearsal.
                        longRunTypes.removeAll {
                            $0 == .steadyLong || $0 == .long || $0 == .progressiveLong || $0 == .fastFinish
                        }
                    }
                }
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

                // Safety net: never leave the long-run slot empty. The forced
                // mid-PEAK rehearsal clears the pool down to raceRehearsal*, which
                // a tight maxLongRunMinutes cap can then filter to nothing — fall
                // back to a regular steadyLong/long within the cap (>=60min if the
                // cap allows, else the shortest available) rather than dropping the
                // long run entirely.
                if pool.isEmpty {
                    let regular = filterWorkoutsBySubtypeV3(workouts: longRuns, subtypes: [.steadyLong, .long])
                        .filter { $0.duration <= maxDurationMins * 60 }
                    pool = regular.filter { $0.duration >= minLongRunMins * 60 }
                    if pool.isEmpty { pool = regular }
                }

                // Marathon PEAK: ramp the Race-Rehearsal MP segment up across the
                // peak weeks (60→75→90) so it doesn't park on the largest rung.
                if phase == .peak {
                    pool = rampRehearsalMPSegment(pool, peakWeekIndex: week - baseDur - speedDur, peakDur: peakDur,
                        priorRehearsalCount: priorPeakRehearsalCount(beforeWeek: week, baseDur: baseDur, speedDur: speedDur), force: false, windowGate: false)
                }

                // Progressive long-run target by distance+level+phase from the config's
                // (start, peak) anchors — without it the load-dominated selector picks
                // short LRs even when targetDuration is high.
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
                        // Long builds get a real progression instead of a flat plateau.
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
                    // week's dominant load chunk dips.
                    longRunTargetMins = recoveryLongRunTarget(targetLongRunMins, isDeloading: isDeloading, phase: phase)
                    let toleranceMins = 15
                    let filteredByTarget = pool.filter { abs(Int($0.duration) / 60 - longRunTargetMins) <= toleranceMins }
                    if !filteredByTarget.isEmpty {
                        pool = filteredByTarget
                    }
                    // Low-mileage short races: load budget sits below the shortest run,
                    // so snap to the nearest-target aerobic run (half/marathon untouched).
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
                    // 5K beginner (no longRunProgression): use the initial range.
                    longRunTargetMins = Int.random(in: config.initialLongRunDuration)
                }

                // LR load multiplier (bumped for competitive so PEAK picks the long
                // steadyLong/raceRehearsalM over short alternatives).
                let lrLoadMult = config.profile.longRunSnapLoadFraction
                // Monotonic: non-decreasing in BUILD, non-increasing in TAPER/RACE,
                // 65%-of-peak cutback floor. See applyLongRunMonotonic.
                pool = applyLongRunMonotonic(pool: pool, phase: phase, prevLongRunMins: prevLongRunMins, isDeloading: isDeloading)
                if let longRun = selectWorkoutByTargetV3(workouts: pool, targetLoad: targetLoad * lrLoadMult, targetDuration: longRunTargetMins, usedIds: &usedIds, isMaintenance: false) {
                    weekWorkouts.append(("long", longRun))
                    prevLongRunMins = Int(longRun.duration / 60)
                }
            }

            // EASY RUN (fills remaining slots). Daniels: 70-80% of weekly volume
            // should be easy — on a 3-day beginner plan that's 1 hard + 1 long + 1
            // easy. So this slot is easy by default; progression is the ~30% variant.
            if weekWorkouts.count < maxWorkoutsPerWeek {
                // Roughly 30% of weeks get progression instead of easy, so the
                // overall E:P split sits around 70/30 in line with Daniels.
                let progressionWeek = (week % 3 == 0)

                if !easyRuns.isEmpty {
                    // Beg 5K/10K/21K: the 3rd slot is ALWAYS pure easy — on a 2-3 day
                    // week a progression there leaves zero recovery. Only Beg 42K (4 days)
                    // gets an occasional 3rd-slot progression, 4th slot staying easy.
                    if config.distance >= 42000 && progressionWeek && !ttWeek {
                        // 21K+: Progress from 40 → 90 mins (can go up to 3 hours)
                        let progressionTargetMins: Int
                        switch phase {
                        case .base:
                            progressionTargetMins = 40
                        case .speed:
                            let speedWeekIndex = week - baseDur
                            let speedProgress = Double(speedWeekIndex) / Double(max(speedDur - 1, 1))
                            progressionTargetMins = 40 + Int(25.0 * speedProgress)  // 40→65
                        case .peak:
                            let peakWeekIndex = week - baseDur - speedDur
                            let peakProgress = Double(peakWeekIndex) / Double(max(peakDur - 1, 1))
                            progressionTargetMins = 65 + Int(25.0 * peakProgress)  // 65→90
                        case .taper, .race:
                            progressionTargetMins = 40
                        }

                        // Filter for progression runs within ±10 mins of target, minimum 40 mins
                        var progressivePool = filterWorkoutsBySubtypeV3(workouts: workoutPool, subtypes: [.progression])
                            .filter { $0.duration >= 40 * 60 }  // Minimum 40 mins
                            .filter { abs(Int($0.duration) / 60 - progressionTargetMins) <= 10 }
                        if config.distance < 42000 {
                            progressivePool = progressivePool.filter { $0.duration <= 70 * 60 }  // Cap at 1h10m for <42K
                        }
                        if let progressive = selectWorkoutByTargetV3(workouts: progressivePool, targetLoad: targetLoad * 0.18, targetDuration: progressionTargetMins, usedIds: &usedIds, isMaintenance: false) {
                            weekWorkouts.append(("progressive_beginner", progressive))
                        } else if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.15, targetDuration: Int(targetDuration * 0.30), usedIds: &usedIds, isMaintenance: false) {
                            weekWorkouts.append(("easy", easy))
                        }
                    } else if config.distance == 5000 {
                        // 5K beginner: Add short progression runs in week 2 and second half
                        let shouldAddProgression = (week == 1) || (week >= actualWeeksToGenerate / 2 && week % 3 == 0)
                        if shouldAddProgression {
                            // Short progression runs (40-50 mins)
                            let progressivePool = filterWorkoutsBySubtypeV3(workouts: workoutPool, subtypes: [.progression])
                                .filter { $0.duration >= 40 * 60 && $0.duration <= 50 * 60 }
                            if let progressive = selectWorkoutByTargetV3(workouts: progressivePool, targetLoad: targetLoad * 0.15, targetDuration: 45, usedIds: &usedIds, isMaintenance: false) {
                                weekWorkouts.append(("progressive_5k_beginner", progressive))
                            } else if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.15, targetDuration: Int(targetDuration * 0.30), usedIds: &usedIds, isMaintenance: false) {
                                weekWorkouts.append(("easy", easy))
                            }
                        } else {
                            // Regular easy run
                            if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.15, targetDuration: Int(targetDuration * 0.30), usedIds: &usedIds, isMaintenance: false) {
                                weekWorkouts.append(("easy", easy))
                            }
                        }
                    } else {
                        // Default (Beg 10K/21K): easy run filling the remaining slot
                        // (Beg excluded from the Pfitz mediumLong forcing).
                        if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.15, targetDuration: Int(targetDuration * 0.30), usedIds: &usedIds, isMaintenance: false) {
                            weekWorkouts.append(("easy", easy))
                        }
                    }
                }
            }
            
            // BASE phase extra workout — Beginner: add an easy run.
            if phase == .base && weekWorkouts.count < maxWorkoutsPerWeek {
                if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: targetLoad * 0.10, targetDuration: Int(targetDuration * 0.20), usedIds: &usedIds, isMaintenance: false) {
                    weekWorkouts.append(("easy", easy))
                }
            }

            // Fill remaining trainingDays with easy runs. For 21K+ prefer a longer
            // "medium-long" (Pfitz-style) first fill so weekly volume grows at 4+ days.
            while weekWorkouts.count < maxWorkoutsPerWeek {
                let isLongRace = config.distance >= 21000
                let isFirstFill = !weekWorkouts.contains { $0.type.contains("fill") }
                let easyTargetMin: Int = {
                    if isLongRace && isFirstFill {
                        return min(90, max(60, Int(targetDuration * 0.30)))
                    } else {
                        return min(60, max(35, Int(targetDuration * 0.22)))
                    }
                }()
                // Per-slot LOAD multipliers determine which workout the selector
                // picks (load match dominates the score): 0.18 MLR / 0.12 fill.
                let easyTargetLoad = targetLoad * (isLongRace && isFirstFill ? 0.18 : 0.12)
                if let easy = selectWorkoutByTargetV3(workouts: easyRuns, targetLoad: easyTargetLoad, targetDuration: easyTargetMin, usedIds: &usedIds, isMaintenance: false) {
                    weekWorkouts.append((isLongRace && isFirstFill ? "medium_long_fill" : "easy_fill", easy))
                } else {
                    break  // Catalog exhausted
                }
            }

            // Beginner strides pool: 4-6 reps only (drop the 2-3-rep templates —
            // too few; standard is 4-8). The selector elsewhere may still surface a
            // <4-rep stride incidentally, so we both force from and normalize to
            // this pool below.
            let begStridesPool = filterWorkoutsBySubtypeV3(workouts: workoutPool, subtypes: [.strides])
                .filter { stridesRepCount($0) >= 4 }

            // Deliberate weekly strides through BASE & SPEED: strides are the
            // beginner's primary safe speed/economy stimulus, so program one per
            // base/speed week (respecting the 1/week cap below) instead of leaving
            // them incidental. If the week already carries a strides session we
            // leave it; otherwise convert the lightest easy/recovery FILL slot to a
            // duration-matched 4-6-rep strides run. PEAK/TAPER keep current behavior.
            if (phase == .base || phase == .speed) && !begStridesPool.isEmpty
                && !weekWorkouts.contains(where: { $0.workout.subtype == .strides }) {
                // Convert a pure easy/recovery slot (never the long run, quality, or
                // progression) — prefer the shortest so we don't turn a medium-long
                // fill into strides.
                let easySlot = weekWorkouts.indices
                    .filter { weekWorkouts[$0].workout.subtype == .easy
                           || weekWorkouts[$0].workout.subtype == .recovery }
                    .min(by: { weekWorkouts[$0].workout.duration < weekWorkouts[$1].workout.duration })
                if let i = easySlot {
                    let targetMin = Int(weekWorkouts[i].workout.duration / 60)
                    if let strides = begStridesPool.min(by: {
                        abs(Int($0.duration / 60) - targetMin) < abs(Int($1.duration / 60) - targetMin)
                    }) {
                        weekWorkouts[i] = ("strides", strides)
                    }
                }
            }

            // Change C safety net: any beginner strides session with <4 reps is
            // swapped for the closest-duration 4-6-rep variant (covers strides the
            // selector placed incidentally, in any phase).
            if !begStridesPool.isEmpty {
                for i in weekWorkouts.indices
                where weekWorkouts[i].workout.subtype == .strides
                    && stridesRepCount(weekWorkouts[i].workout) < 4 {
                    let targetMin = Int(weekWorkouts[i].workout.duration / 60)
                    if let replacement = begStridesPool.min(by: {
                        abs(Int($0.duration / 60) - targetMin) < abs(Int($1.duration / 60) - targetMin)
                    }) {
                        weekWorkouts[i] = (weekWorkouts[i].type, replacement)
                    }
                }
            }

            // Cap strides at 1/week — replace extras with the closest-duration plain
            // easy from the UNFILTERED pool (the competitive >= 60min easyRuns filter
            // would otherwise swap taper strides for 60min easies, wrecking the taper).
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
            // aerobic FILL only (never long run / quality / MP), freeing a recovery day.
            let weeklyCapMinutes: Int = {
                guard config.distance >= 42195 else { return .max }
                switch config.runnerLevel {
                case .competitive: return 540   // ~9.0h ceiling
                case .advanced:    return 480   // ~8.0h ceiling
                default:           return .max  // Beg/Int already sit well below
                }
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

            lastWeekHadZ5 = weekWorkouts.contains { isRealZ5($0.workout) }
            workoutsByWeek[week] = weekWorkouts
        } while false
    }

}
