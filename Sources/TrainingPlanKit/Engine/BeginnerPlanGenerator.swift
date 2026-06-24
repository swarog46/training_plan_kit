//
//  BeginnerPlanGenerator.swift
//  RunPlan
//
//  Beginner-tier plan generator. Owns the beginner week assembly; inherits the
//  shared skeleton (phase math, pools, targets, finalization) from PlanGeneratorV3.
//

import Foundation

final class BeginnerPlanGenerator: PlanGeneratorV3 {
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

            // Beginner: never a yasso week (yasso is Int/Adv only) — folds to false.

            // PEAK milestone cadence — computed at week scope so both the
            // pool gate AND the per-level selection logic below can read it.
            let milestoneCadence = max(3, peakDur / 2)
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
            // Skip the PEAK week the beginner half/marathon forces a race rehearsal
            // onto (see long-run section) so a TT + a race-pace rehearsal don't stack
            // into one brutal week — they sit in separate weeks instead.
            let rehearsalWeekInPhase = (config.distance >= 21000 && peakDur >= 2)
                ? max(1, (peakDur - 1) / 2) : -1
            let peakTTWeek = config.distance >= 21000 && phase == .peak
                && (weekInPhase % milestoneCadence) == milestoneCadence / 2
                && weekInPhase != rehearsalWeekInPhase
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

                // Yasso 800s are Int/Adv only — never in a beginner week, so
                // they're unconditionally excluded here.
                pool = pool.filter { $0.subtype != .yasso800 }
                // Gate Time Trials by the milestone cadence (TT runs for all
                // levels). Cadence yields 2-3 per PEAK cycle, never sharing a week.
                if !ttWeek {
                    pool = pool.filter { $0.subtype != .timeTrial }
                }

                // Minimum-duration floor by phase + level. Below the floor the
                // session is too short to engage VO2max/T-pace meaningfully
                // (Daniels: I-pace reps need 2-5min each; total session typically
                // 35-50min). Onboarding (BASE wks 0-2) gets the lighter floor;
                // race-PEAK pushes Int/Adv toward textbook 40-50min sessions.
                let isOnboarding = phase == .base && weekInPhase <= 1
                // Deload build weeks: relax the floor to the onboarding value (22).
                // The full PEAK floor can drop every interval/short-ladder template
                // except one heavy survivor, forcing the "recovery" pick onto the
                // monster session. 22 still excludes the lightest 20-min ladder so
                // the deload lands on a genuine Z5 session, not something trivial.
                let minIntervalMinutes: Int = {
                    if isDeloading && phase != .race { return 22 }
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
                    // Alternate: even weeks = intervals, odd = threshold.
                    // On a Time Trial week, take the interval branch (even if it would
                    // otherwise be a threshold/odd week) and prefer the TT subtype so
                    // the recalibration checkpoint isn't lost to standard intervals
                    // (Yasso is gated out entirely for beginners).
                    if (week % 2 == 0 || ttWeek) && !intervalPool.isEmpty {
                        let begPool: [Workout] = {
                            if ttWeek {
                                let ttOnly = intervalPool.filter { $0.subtype == .timeTrial }
                                if !ttOnly.isEmpty { return ttOnly }
                            }
                            // PEAK = race sharpening. Bias 5K/10K beginners toward
                            // race-specific neuromuscular work (strides @ ~5K pace)
                            // and the tune-up time-trial; drop hill repeats, which
                            // are a BASE-phase strength stimulus. Sustained race-pace
                            // intervals (fivekPace, ~12k load) are intentionally NOT
                            // in the beginner pool — too heavy for a ~9k-load week,
                            // and the catalog has no beginner-dosed variant. Strides
                            // are the injury-safe way a novice rehearses fast running
                            // (Daniels/Higdon). Other distances keep the full pool.
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
                        // Apply progression filter to thresholds
                        let progressedThresholds = filterThresholdsByProgression(filteredThresholds, week: week, totalWeeks: actualWeeksToGenerate)
                        let thresholdPool = progressedThresholds.isEmpty ? filteredThresholds : progressedThresholds

                        if let threshold = selectWorkoutByTargetV3(workouts: thresholdPool, targetLoad: targetLoad * 0.4, targetDuration: Int(targetDuration * 0.35), usedIds: &usedIds, previousWorkout: prevThreshold, isDeloading: isDeloading, phaseJustStarted: phaseJustStarted, isMaintenance: false) {
                            weekWorkouts.append(("threshold", threshold))
                            prevThreshold = threshold
                        }
                    }
            }

            // LONG RUN
            var shouldAddLong = true
            var longRunTypes: [WorkoutSubtype] = [.long, .steadyLong]

            if config.distance == 5000 {
                // 5K Beginner: no long runs (5K is too short to warrant
                // marathon-style endurance work, and beginners don't have the
                // aerobic base to absorb a weekly 75min LR).
                shouldAddLong = false
            } else if config.distance == 10000 {
                // 10K Beginner: weekly long run in BASE/SPEED/PEAK.
                // Pfitz and Higdon's beginner 10K plans both have weekly longs —
                // just shorter on cutback weeks (handled via phaseProgression).
                longRunTypes = [.long, .steadyLong]
                shouldAddLong = phase == .base || phase == .speed || phase == .peak
            } else if config.distance >= 21000 {
                // 21K+ Beginner: long run every BASE/SPEED/PEAK week.
                longRunTypes = [.long, .steadyLong]
                shouldAddLong = phase == .base || phase == .speed || phase == .peak
            }

            // SPEED + PEAK: add progressiveLong (Z2→Z3/MP) to break up the wall of
            // aerobic that pure steadyLong selection creates. BASE stays pure aerobic.
            // Beg gets no progressive-forcing — Pfitz Beg "Just Finish" half IS
            // pure-aerobic by design (can't yet handle race-pace volume).
            if phase == .speed || phase == .peak {
                longRunTypes.append(.progressiveLong)
            }

            // PEAK weeks: open the long-run pool to include the race-rehearsal
            // flavor matching the plan distance (10K → raceRehearsal10K,
            // 21K → raceRehearsalHM, 42K → raceRehearsalM). Each subtype's
            // eligibleDistances pins it to one race, so we just look up the
            // first matching subtype.
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
                    // Beg 21K/42K: schedule one race rehearsal in mid-PEAK.
                    // Pfitz "Just Finish" prescribes 1-2 race-pace tune-ups in
                    // PEAK so the runner doesn't arrive at race day having never
                    // run at goal pace. Without this, the selector picks steady
                    // aerobic every week (load match dominates) and the runner
                    // never gets a race-pace exposure. One rehearsal at the
                    // midpoint is conservative — Pfitz Just Finish has more.
                    let rehearsalWeekIdx = max(1, (peakDur - 1) / 2)
                    if peakWeekIndex == rehearsalWeekIdx {
                        // Also drop fastFinish: at the half's shorter peak-LR target it
                        // out-matches raceRehearsalHM on load/duration and wins every
                        // time, so the half never got a rehearsal (the marathon's longer
                        // LR picks raceRehearsalM regardless). Removing it forces the
                        // race-pace rehearsal for both distances.
                        longRunTypes.removeAll {
                            $0 == .steadyLong || $0 == .long || $0 == .progressiveLong || $0 == .fastFinish
                        }
                    }
                }
            }
            
            if shouldAddLong && !longRuns.isEmpty {
                var pool = filterWorkoutsBySubtypeV3(workouts: longRuns, subtypes: longRunTypes)

                // Duration caps. Marathon/Half caps scale with level — Pfitzinger
                // 18/55 peaks at 22mi long runs; Higdon Int 1 marathon at 20mi.
                // Longest-run cap is declared per-plan on the config as one readable
                // (distance, level) table — see PlanConfiguration.maxLongRunMinutes.
                let maxDurationMins = config.maxLongRunMinutes
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
                    // On recovery/deload BUILD weeks, cut the LR target ~20% so the
                    // week's dominant load chunk dips. Both the tolerance filter and
                    // the selector below read longRunTargetMins, so the cut reaches both.
                    longRunTargetMins = recoveryLongRunTarget(targetLongRunMins, isDeloading: isDeloading, phase: phase)
                    let toleranceMins = 15
                    let filteredByTarget = pool.filter { abs(Int($0.duration) / 60 - longRunTargetMins) <= toleranceMins }
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
                    // week a progression in the last slot leaves zero recovery when the
                    // quality slot is hard. ONLY Beg 42K (4 days) gets an occasional
                    // 3rd-slot progression, with its 4th slot staying easy to preserve
                    // a recovery day (TT weeks too).
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
                        // Default (Beg 10K/21K): easy run filling the remaining slot.
                        // (Beg excluded from the Pfitz mediumLong forcing — Higdon
                        // Novice doesn't prescribe MLR — so the pool stays easyRuns.)
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

            // Fill remaining trainingDays with easy runs. Used to bail here,
            // leaving days unscheduled — major reason marathon plans were ~30%
            // under Higdon volume. For 21K+ we prefer a longer easy ("medium-
            // long" Pfitz-style) for the first fill slot so weekly volume grows
            // when trainingDays.count is 4+.
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
                switch config.runnerLevel {
                case .competitive: return 540   // ~9.0h ceiling (was up to 10.1h)
                case .advanced:    return 480   // ~8.0h ceiling (was up to 8.4h)
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
            applyDeloadReshaping(&weekWorkouts, phase: phase, isDeloading: isDeloading)

            lastWeekHadZ5 = weekWorkouts.contains { isRealZ5($0.workout) }
            workoutsByWeek[week] = weekWorkouts
        } while false
    }

}
