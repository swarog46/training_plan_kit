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
            var rawTargets = calculateWeeklyTargetsV3(weekInPlan: week, weekInPhase: weekInPhase, phase: phase, phaseDurations: phaseDurations, config: config)
            // #158: Cmp duration targets in PHYSICAL minutes. The boost×amplifier
            // model produced 1496-min "targets" the ceilings ignored (rendered
            // 469; Pfitz 18/70 peaks 660-720). Fixed per-distance peak — length
            // buys more base weeks, never a lower peak — with a phase-anchored
            // ramp; PEAK > SPEED > BASE by construction at every length, which
            // also cures the 12w peak<base and 36w speed>peak inversions (R16).
            if config.distance >= 21097 {
                // Duration-native peak: Pfitz 18/70 is ~70mi; in minutes that's
                // pace-dependent (~590min @3:00 goal, ~660 @3:30). Generation is
                // pace-blind, so 620 targets the 3:15 mid-band; render paces make
                // faster runners' weeks shorter in minutes, same in km — correct.
                let peakMin: Double = config.distance == 42195 ? 660 : 570
                let p = rawTargets.phaseProgression
                let frac: Double
                switch phase {
                case .base:  frac = 0.72 + 0.12 * p
                case .speed: frac = 0.84 + 0.08 * p
                case .peak:  frac = 0.92 + 0.08 * p
                case .taper: frac = 0.80 - 0.25 * p
                case .race:  frac = 0.40
                }
                var dur = peakMin * frac
                // Deload duration factor tuned so the COMPOUNDED weekly cut
                // (load mult x fill undershoot x LR cut) lands at Pfitz's -20-25%,
                // not the -40% the 0.85 factor produced.
                if rawTargets.isDeloading { dur *= 0.95 }
                rawTargets = WeeklyTargets(load: rawTargets.load, duration: dur,
                                           isDeloading: rawTargets.isDeloading,
                                           phaseProgression: p)
            }
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
            
            // Cmp marathon: midweek quality NEVER carries .marathonPace — MP volume
            // lives in the long-run lane (rehearsals / progressive finishes),
            // Pfitz-style. Kills the z5Blocked-fallback leak that stacked a 110-min
            // MP session on top of a progressive-finish week (155 MP-min weeks).
            // ONE exception: taper week 2 (~10 days out) admits the SHORT dress
            // rehearsal (≤45min, ~20min at race pace) — Pfitz's final MP touch.
            let taperWk = week - baseDur - speedDur - peakDur
            let dressRehearsalWeek = phase == .taper && taperWk == 1 && config.distance >= 21097
            let filteredThresholds: [Workout] = {
                guard config.distance >= 30000 else { return self.filteredThresholds }
                if dressRehearsalWeek {
                    return self.filteredThresholds.filter {
                        $0.subtype != .marathonPace || $0.duration <= 45 * 60
                    }
                }
                return self.filteredThresholds.filter { $0.subtype != .marathonPace }
            }()

            // Dress-rehearsal week: restrict the threshold family to the short MP
            // tune-up so the selector can't prefer a bigger LT session instead.
            let dressPool = filteredThresholds.filter { $0.subtype == .marathonPace && $0.duration <= 45 * 60 }
            let weekThresholds = (dressRehearsalWeek && !dressPool.isEmpty) ? dressPool : filteredThresholds

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
                        var progressivePool = filterWorkoutsBySubtypeV3(workouts: workoutPool, subtypes: [.progression])
                            .filter { $0.duration >= 40 * 60 && $0.duration <= 50 * 60 }
                        // R12: the race-week tune-up prefers the 3-tier kick shape
                        // (easy→goal→faster, has a Z4 tail) — long variants were
                        // selecting the flat Z2→Z3 template and giving the most
                        // committed athletes the weakest final sharpener.
                        let withKick = progressivePool.filter { w in
                            w.intervals.contains { iv in
                                if case .heartRateZone(let z) = iv.target { return z >= 4 }
                                return false
                            }
                        }
                        if !withKick.isEmpty { progressivePool = withKick }
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
                           let threshold = selectWorkoutByTargetV3(workouts: weekThresholds, targetLoad: targetLoad * 0.3, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, previousWorkout: prevThreshold, isDeloading: isDeloading, phaseJustStarted: phaseJustStarted, isMaintenance: false) {
                            weekWorkouts.append(("threshold", threshold))
                            prevThreshold = threshold
                        } else if let interval = selectWorkoutByTargetV3(workouts: noZ5, targetLoad: targetLoad * 0.3, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, previousWorkout: prevInterval, isDeloading: isDeloading, phaseJustStarted: phaseJustStarted, isMaintenance: false) {
                            weekWorkouts.append(("interval", interval))
                            prevInterval = interval
                        } else if let threshold = selectWorkoutByTargetV3(workouts: weekThresholds, targetLoad: targetLoad * 0.3, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, previousWorkout: prevThreshold, isDeloading: isDeloading, phaseJustStarted: phaseJustStarted, isMaintenance: false) {
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
                        } else if !weekThresholds.isEmpty {
                            // Normal week: Add threshold
                            let progressedThresholds = filterThresholdsByProgression(weekThresholds, week: week, totalWeeks: actualWeeksToGenerate)
                            var thresholdPool = progressedThresholds.isEmpty ? weekThresholds : progressedThresholds

                            // Competitive marathon PEAK already carries MP via the
                            // MP-segment LR alternation. `.marathonPace` is also in
                            // `thresholdSubtypes`, so without this the threshold slot
                            // would add a second MP session (LR + 2 MP = over budget).
                            // Drop MP here so the threshold slot picks a real threshold.
                            let mpQualitySlotWillFire = phase == .peak
                                && config.distance >= 30000
                                && !isDeloading
                            // Also drop MP on DELOAD weeks: the deload long is
                            // already plain aerobic (R18) — letting this slot pick
                            // a 90min-MP session instead defeats the down week.
                            if mpQualitySlotWillFire || isDeloading {
                                let withoutMP = thresholdPool.filter { $0.subtype != .marathonPace }
                                if !withoutMP.isEmpty { thresholdPool = withoutMP }
                                else if isDeloading { thresholdPool = [] }  // skip the slot on a down week
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
                                let mileRepsOnly = weekThresholds.filter { $0.subtype == .mileRepeats }
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
                    // Not on deloads: forcing progressiveLong would put an MP
                    // finish on the down week (cut the stressor).
                    if speedWeekIndex % 2 == 0 && !isDeloading {
                        longRunTypes.removeAll { $0 == .steadyLong || $0 == .long }
                    }
                }
            }

            // PEAK weeks: open the long-run pool to the distance-matched race
            // rehearsal (eligibleDistances pins each to one race). See Beginner.
            // R18 P1: a rung suppressed by a deload on the LAST peak week used to
            // die at the phase boundary (18w half: 5-wk PEAK with TT + 2 deloads
            // delivered 20/25, never 30). Spill it into the first taper week —
            // Pfitz runs the last race-pace session 10-14 days out anyway.
            // (Taper W1 always carries the deload label — that label means "no new
            // stressor" in BUILD; here it must not veto the final race-pace touch.)
            // Half only, and only if the 20/25/30 ladder is incomplete — plans
            // that finished in PEAK must not grow a junk 4th rung in taper.
            let spillRehearsal = phase == .taper && weekInPhase == 0 && pendingRehearsalSlot
                && config.distance == 21097
                && priorPeakRehearsalCount(beforeWeek: week, baseDur: baseDur, speedDur: speedDur) < 3
            if spillRehearsal {
                pendingRehearsalSlot = false
                for rehearsal: WorkoutSubtype in [.raceRehearsalM, .raceRehearsalHM, .raceRehearsal10K]
                where rehearsal.eligibleDistances.contains(config.distance) {
                    longRunTypes.append(rehearsal)
                }
                longRunTypes.removeAll { $0 == .steadyLong || $0 == .long }
            }
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
                    // Deload weeks never force MP — a down week runs a plain aerobic long
                    // (cut the stressor; the rehearsal IS the stressor). A slot a deload
                    // suppresses shifts to the next non-deload peak week (rung not lost).
                    // Short PEAK phases (≤6w, e.g. the 18w half's 5-week peak)
                    // can't fit the full rung ladder on alternation — schedule
                    // every non-deload peak week so the 20/25/30 ladder lands
                    // (R13 Cmp finding: the 18w half never reached its 30min rung).
                    let scheduledMP = (peakDur <= 6 && !ttWeek)
                        || peakWeekIndex % 2 == 0 || peakWeekIndex == peakDur - 1
                    let isMPSegmentWeek = !isDeloading && (scheduledMP || pendingRehearsalSlot)
                    if isDeloading && scheduledMP { pendingRehearsalSlot = true }
                    else if isMPSegmentWeek { pendingRehearsalSlot = false }
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

                // Deload: plain aerobic long only — a progressiveLong here would
                // carry a ≥25%-MP finish (the filter below guarantees it), which
                // is exactly the stressor the down week exists to cut.
                if isDeloading {
                    let plain = pool.filter { $0.subtype != .progressiveLong }
                    if !plain.isEmpty { pool = plain }
                }

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

                // Marathon PEAK: ramp the Race-Rehearsal MP segment up across the
                // peak weeks (60→75→90) so it doesn't park on the largest rung.
                if phase == .peak {
                    pool = rampRehearsalMPSegment(pool, peakWeekIndex: week - baseDur - speedDur, peakDur: peakDur,
                        priorRehearsalCount: priorPeakRehearsalCount(beforeWeek: week, baseDur: baseDur, speedDur: speedDur), force: true, windowGate: false,
                        isDeloading: isDeloading && !spillRehearsal)
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
                        // Step down across the taper: wk1 (3 out) keeps the Pfitz
                        // final medium-long; wk2+ drops toward a race-week jog.
                        let taperWeekIndex = week - baseDur - speedDur - peakDur
                        targetLongRunMins = taperWeekIndex <= 0 ? p.taper
                            : Int(Double(p.taper) * 0.8)
                    }
                    // Recovery/deload BUILD weeks: cut the LR target ~20%. See Beginner.
                    longRunTargetMins = recoveryLongRunTarget(targetLongRunMins, isDeloading: isDeloading, phase: phase)
                    let toleranceMins = 15
                    let filteredByTarget = pool.filter { abs(Int($0.duration) / 60 - longRunTargetMins) <= toleranceMins }
                    if !filteredByTarget.isEmpty {
                        pool = filteredByTarget
                    } else if phase == .taper, week - baseDur - speedDur - peakDur >= 1 {
                        // No template near the stepped-down target: cap at the
                        // target rather than bouncing back up to a 140-min long
                        // two weeks from the race (the ±15 filter found nothing).
                        let capped = pool.filter { Int($0.duration) / 60 <= longRunTargetMins + 15 }
                        if !capped.isEmpty { pool = capped }
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
                // Plain easy only — the MLR slots own .mediumLong (R19 P1: this
                // pre-fill slot was the last one still leaking a 3rd MLR in BASE).
                let plainEasy = easyRuns.filter { $0.subtype != .mediumLong }
                if let easy = selectWorkoutByTargetV3(workouts: plainEasy, targetLoad: targetLoad * 0.25, targetDuration: Int(targetDuration * 0.25), usedIds: &usedIds, isMaintenance: false) {
                    weekWorkouts.append(("easy", easy))
                }
            }

            // Fill remaining slots (5 for 21K+, 4 for others).
            while weekWorkouts.count < maxWorkoutsPerWeek {
                // Fill with easy runs; 21K+ prefers a longer "medium-long" first fill
                // so weekly volume grows at 4+ days.
                let isLongRace = config.distance >= 21000
                let fillCount = weekWorkouts.filter { $0.type.contains("fill") }.count
                let isFirstFill = fillCount == 0
                // Pfitz signature (#158 phase 2): a core MLR already exists
                // pre-fill; upgrading the FIRST fill to the mediumLong pool makes
                // two per build week (Tue+Fri) — the second fill stays easy
                // (three MLRs was the accidental modal case, R17 P2-2).
                let isBuildWeek = (phase == .base || phase == .speed || phase == .peak) && !isDeloading
                let isSecondMLR = false
                // Drop the Pfitz-MLR sizing in TAPER/RACE — tapering means shorter
                // easies all around (Pfitz race-week easies are 30-45min, not 80-110).
                let isTaperingDown = phase == .taper || phase == .race
                let easyTargetMin: Int = {
                    if isTaperingDown {
                        return phase == .race ? 30 : 40
                    } else if isLongRace && isFirstFill {
                        return min(110, max(60, Int(targetDuration * 0.30)))
                    } else if isSecondMLR {
                        return min(95, max(60, Int(targetDuration * 0.26)))
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
                    easyTargetLoad = targetLoad * ((isLongRace && isFirstFill) ? mlrLoadMult
                                                    : isSecondMLR ? 0.29 : fillLoadMult)
                }
                // Hard-cap easy duration when tapering so the selector can't pick a
                // 60-90min MLR even when load scoring would prefer it.
                let easyPool: [Workout]
                if isTaperingDown {
                    let taperCapMins = phase == .race ? 35 : 50
                    easyPool = filterWorkoutsBySubtypeV3(workouts: workoutPool, subtypes: easySubtypes)
                        .filter { $0.duration <= taperCapMins * 60 }
                } else if (isLongRace && isFirstFill && isBuildWeek) || isSecondMLR {
                    // MLR fills pick real mediumLong templates when available —
                    // the easy pool's subtype would pin them at the easy cap.
                    let mlrPool = filterWorkoutsBySubtypeV3(workouts: workoutPool, subtypes: [.mediumLong])
                    easyPool = mlrPool.isEmpty ? easyRuns : mlrPool
                } else {
                    // Generic fill: plain easy only — mediumLong stays exclusive
                    // to the two labeled MLR slots (R17 P2-2: 3-MLR weeks were
                    // the modal case because easySubtypes includes .mediumLong).
                    easyPool = easyRuns.filter { $0.subtype != .mediumLong }
                }
                if let easy = selectWorkoutByTargetV3(workouts: easyPool, targetLoad: easyTargetLoad, targetDuration: easyTargetMin, usedIds: &usedIds, isMaintenance: false) {
                    weekWorkouts.append(((isLongRace && isFirstFill) || isSecondMLR ? "medium_long_fill" : "easy_fill", easy))
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

            // #158: Cmp weeks now top up to the PHYSICAL duration target like
            // every other level — without this, the Pfitz-class targets were
            // aspirational (selection composed ~470-530min weeks regardless).
            topUpAerobicVolumeV3(&weekWorkouts, targetDurationMins: targetDuration,
                                 isDeloading: isDeloading, phase: phase,
                                 isCompetitive: true)

            // Peak-volume cap — AFTER topUp (R17 P1-2: the old pre-topUp trim was
            // re-inflated by the 2.0× stretch, 52 breaches up to +24%). Tracks the
            // physical peak target instead of a stale 540. Trims by SHRINKING the
            // largest aerobic run (deleting whole MLRs was eating the second MLR).
            let weeklyCapMinutes: Int = {
                guard config.distance >= 21097 else { return .max }
                let peakMin = config.distance == 42195 ? 660.0 : 570.0
                // Phase-scaled: the cap enforces the curve's own shape top-side,
                // so BASE can never out-deliver PEAK (12w did, R17 follow-up).
                let phaseScale: Double
                switch phase {
                case .base:  phaseScale = 0.88
                case .speed: phaseScale = 0.97
                default:     phaseScale = 1.05
                }
                return Int(peakMin * phaseScale)
            }()
            if weeklyCapMinutes != .max {
                let trimmable: Set<WorkoutSubtype> = [.mediumLong, .easy]
                func weekMins() -> Int { weekWorkouts.reduce(0) { $0 + Int($1.workout.duration) / 60 } }
                var guardCount = 0
                while weekMins() > weeklyCapMinutes, guardCount < 12 {
                    guardCount += 1
                    guard let idx = weekWorkouts.indices
                        .filter({ trimmable.contains(weekWorkouts[$0].workout.subtype) })
                        .max(by: { weekWorkouts[$0].workout.duration < weekWorkouts[$1].workout.duration })
                    else { break }
                    let w = weekWorkouts[idx].workout
                    let overshoot = weekMins() - weeklyCapMinutes
                    let newMins = max(45, Int(w.duration) / 60 - max(5, min(overshoot, 30)))
                    if newMins >= Int(w.duration) / 60 { break }
                    weekWorkouts[idx].workout = rescaledV3(w, toSeconds: Int64(newMins * 60))
                }
            }

            enforceLongOverMediumLongV3(&weekWorkouts)
            lastWeekHadZ5 = weekWorkouts.contains { isRealZ5($0.workout) }
            workoutsByWeek[week] = weekWorkouts
        } while false
    }
}
