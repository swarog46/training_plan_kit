//
//  PaceZoneConverter.swift
//  RunPlan
//
//  Created by Claude Code on 06/02/2026.
//

import Foundation

// MARK: - Workout Pace Tolerance
//
// The "on target" pace window shown on the Apple Watch during a workout.
// Single source of truth — referenced by:
//   * the watch tracker view (paints green/red pace zones around target)
//   * the plan detail view (displays target ± tolerance to the runner)
//   * the engine regression tests (asserts generated paces land inside
//     the same window the runner would see as on-target on race day)
//
// Tolerance is symmetric in seconds-per-km, not a percentage — runners
// at 4:00/km and 7:00/km both get the same ±15s window because that is
// what a wrist-worn pace display can resolve in real time regardless of
// absolute pace.
public enum WorkoutPaceTolerance {
    public static let seconds: Double = 15.0
}

// MARK: - Pace Progression Configuration

/// Defines how pace intensity progresses through a training plan.
/// Different runner levels get different progression curves.
/// All values are easily tweakable.
public struct PaceProgressionConfig {
    /// How much to blend toward conservativeTarget at plan START (1.0 = fully conservative, 0.0 = use base zone multiplier)
    public let initialAdjustment: Double
    /// How much to blend toward conservativeTarget at plan END (1.0 = fully conservative, 0.0 = use base zone multiplier)
    public let finalAdjustment: Double
    /// Floor multiplier - intervals never go faster than this × race pace
    public let minMultiplier: Double
    /// Conservative ceiling for fast zones when fully adjusted.
    /// Values > 1.0 mean intervals start SLOWER than race pace (e.g., 1.10 = 10% slower).
    /// At full adjustment, both Zone 4 and Zone 5 blend toward this value.
    public let conservativeTarget: Double
    /// When true, Z3/Z4/Z5 always return their base multiplier (true target
    /// pace) — easing-in is disabled for quality zones. Z1/Z2 still ease in
    /// per initialAdjustment/finalAdjustment. Used by competitive build-band
    /// plans where the runner needs sub-3 / sub-1:30 race-pace exposure
    /// from day 1 even though their easy paces are still ramping in.
    /// Default false (back-compat for existing presets).
    public let qualityZonesAlwaysAtTarget: Bool

    public init(initialAdjustment: Double, finalAdjustment: Double,
         minMultiplier: Double, conservativeTarget: Double,
         qualityZonesAlwaysAtTarget: Bool = false) {
        self.initialAdjustment = initialAdjustment
        self.finalAdjustment = finalAdjustment
        self.minMultiplier = minMultiplier
        self.conservativeTarget = conservativeTarget
        self.qualityZonesAlwaysAtTarget = qualityZonesAlwaysAtTarget
    }

    // MARK: - Presets per runner level

    public static let beginner = PaceProgressionConfig(
        initialAdjustment: 1.0,     // Start fully conservative
        finalAdjustment: 0.0,       // Reach true zones by race week (0.5 kept beginner
                                    //   threshold slower than race pace at half/marathon)
        minMultiplier: 0.92,        // Never faster than 92% of race pace (~4:36 for 5:00 pace)
        conservativeTarget: 1.12    // Start intervals at ~112% race pace (5:36 for 5:00 target)
    )

    public static let intermediate = PaceProgressionConfig(
        // Quality easing matched to .advanced (0.5 → 0.0). The previous
        // 0.8 → 0.2 ramp held quality so conservative that a "10K Pace" or
        // "5K Pace" workout ran ~10-15s/km slower than its named pace right
        // through SPEED/PEAK — the name oversold the effort. Intermediates
        // have the base to ramp like Advanced; this lets the named race-pace
        // sessions actually reach their pace by the sharpening phase, while
        // the minMultiplier floor still caps how fast Z5 can get.
        initialAdjustment: 0.5,     // Start moderate (was 0.8)
        finalAdjustment: 0.0,       // Reach true target by race week (was 0.2)
        minMultiplier: 0.88,        // Never faster than 88% of race pace (~4:24 for 5:00 pace)
        conservativeTarget: 1.10    // (legacy race-pace-anchored path only)
    )

    public static let advanced = PaceProgressionConfig(
        initialAdjustment: 0.5,     // Start moderate
        finalAdjustment: 0.0,       // End at full standard multipliers
        minMultiplier: 0.85,        // Can reach standard Zone 5 (0.85x)
        conservativeTarget: 1.03    // Start near race pace
    )

    /// Sub-3 marathon / sub-1:30 half plans. Runner has proven the fitness
    /// via a recent race result (gate requires VDOT ≥ 58). All zones flat
    /// at goal target paces from day 1.
    public static let competitive = PaceProgressionConfig(
        initialAdjustment: 0.0,
        finalAdjustment: 0.0,
        minMultiplier: 0.84,
        conservativeTarget: 1.0,
        qualityZonesAlwaysAtTarget: true
    )

    /// Sub-3 / sub-1:30 plans for the "build band" runners (VDOT 54-57).
    /// They CAN reach goal fitness with more weeks, but currently can't run
    /// goal easy pace. Quality (MP/threshold/intervals) locks at goal paces
    /// from day 1 — forces real race-pace exposure. Easy/long zones run flat
    /// at the runner's VDOT-derived easy pace (floored at race), not the
    /// generic 1.15×race which is too slow at elite goal paces.
    public static let competitiveBuildBand = PaceProgressionConfig(
        initialAdjustment: 0.5,
        finalAdjustment: 0.0,
        minMultiplier: 0.84,
        conservativeTarget: 1.0,
        qualityZonesAlwaysAtTarget: true
    )

    // MARK: - Maintenance presets (very slow progression, stays conservative)

    public static let maintenanceBeginner = PaceProgressionConfig(
        initialAdjustment: 1.0,     // Start fully conservative
        finalAdjustment: 0.8,       // Stay very conservative even at end
        minMultiplier: 0.95,        // Never faster than 95% race pace
        conservativeTarget: 1.15    // Start intervals well above race pace
    )

    public static let maintenanceIntermediate = PaceProgressionConfig(
        initialAdjustment: 0.9,     // Start very conservative
        finalAdjustment: 0.6,       // Stay mostly conservative
        minMultiplier: 0.92,        // Never faster than 92% race pace
        conservativeTarget: 1.12    // Start intervals above race pace
    )

    public static let maintenanceAdvanced = PaceProgressionConfig(
        initialAdjustment: 0.7,     // Start conservative
        finalAdjustment: 0.4,       // Moderate by end
        minMultiplier: 0.88,        // Never faster than 88% race pace
        conservativeTarget: 1.08    // Start intervals near race pace
    )

}

/// Converts between heart rate zones and pace targets
public struct PaceZoneConverter {

    // MARK: - Standard HR Zone to Pace Multiplier Mapping

    /// Returns the standard (unadjusted) pace multiplier for a given HR zone
    /// - Parameter zone: Heart rate zone (1-5)
    /// - Returns: Base multiplier to apply to race pace
    ///
    /// Zone mappings:
    /// - Zone 1 (50-60% max HR): Easy recovery - 1.25x race pace (slower)
    /// - Zone 2 (60-70% max HR): Conversational - 1.15x race pace
    /// - Zone 3 (70-80% max HR): Marathon pace - 1.0x race pace
    /// - Zone 4 (80-90% max HR): Tempo - 0.93x race pace (faster)
    /// - Zone 5 (90-100% max HR): Intervals - 0.85x race pace (much faster)
    public static func baseMultiplier(for zone: Int) -> Double {
        switch zone {
        case 1: return 1.25    // Easy recovery
        case 2: return 1.15    // Conversational
        case 3: return 1.0     // Marathon pace
        case 4: return 0.93    // Tempo
        case 5: return 0.85    // Intervals
        default: return 1.0
        }
    }

    // MARK: - Progressive Pace Multiplier

    /// Returns pace multiplier adjusted for runner's fitness gap and plan progression.
    /// - Parameters:
    ///   - zone: Heart rate zone (1-5)
    ///   - racePace: Target race pace in seconds/km
    ///   - conversationalPace: Current easy pace in seconds/km (nil = no adjustment)
    ///   - progressionFactor: Position in plan (0.0 = start, 1.0 = end)
    ///   - config: Progression config for the runner's level
    /// - Returns: Adjusted multiplier
    public static func progressiveMultiplier(
        for zone: Int,
        racePace: Int,
        conversationalPace: Int?,
        progressionFactor: Double,
        config: PaceProgressionConfig,
        vdotAnchored: Bool = false
    ) -> Double {
        let base = baseMultiplier(for: zone)

        // Quality zones (Z3 MP, Z4 threshold, Z5 intervals) lock at target
        // for configs that demand race-pace exposure from day 1 — even when
        // there is a measurable gap between race pace and conversational
        // pace, the runner runs MP at MP, threshold at T, intervals at I.
        // Only the easy zones (Z1 / Z2) get the gap-blend treatment below.
        if config.qualityZonesAlwaysAtTarget && zone >= 3 {
            return base
        }

        // No adjustment without conversational pace
        guard let convPace = conversationalPace else {
            return base
        }

        // Calculate gap between conversational and race pace
        // e.g., 370/300 = 1.233 → 23% gap
        let gapRatio = Double(convPace) / Double(racePace)

        // Easy/recovery pace: anchor to the runner's stated (VDOT-derived) easy +
        // gentle easing — NEVER blend toward the generic 1.15×race. Take the
        // freeze-fix when (a) non-competitive, (b) the runner's easy is at/under
        // base (gapRatio < base), OR (c) the AT-GOAL competitive config
        // (initialAdjustment == 0): its gap-blend has zero movement, so a gapRatio
        // just over base (a sub-1:30 half at 1.157) would otherwise freeze easy
        // flat at 1.15×race all block — while the marathon (under base) eased.
        // The build-band (initialAdjustment 0.5) is the exception: it keeps the
        // gap-blend so its easy converges from the runner's easy toward goal as
        // fitness builds. Floored at race; recovery (Z1) scaled by base/1.15.
        if base > 1.0, (!config.qualityZonesAlwaysAtTarget || gapRatio < base || config.initialAdjustment == 0) {
            let flat = max(1.0, gapRatio) * (base / 1.15)
            // VDOT mode: the easy anchor (conversationalPace) is already interpolated
            // current→projected VDOT upstream, so the fitness progression lives in the
            // anchor — return the flat gap and let the moving anchor carry it.
            if vdotAnchored { return flat }
            // Legacy mode: ~6.5% easing over the WHOLE plan as a modeled slice of the
            // projected fitness gain (same effort, pace drifts down as the runner
            // adapts). 5s-quantized downstream. Guardrail, not a target.
            let p = max(0, min(1.0, progressionFactor))
            return flat * (1.0 - 0.065 * p)
        }

        let gapFactor = max(0, min(1.0, (gapRatio - 1.0) / 0.20))

        // No adjustment if gap is negligible
        guard gapFactor > 0 else { return base }

        // Interpolate adjustment based on plan progression
        // Start of plan → initialAdjustment, End of plan → finalAdjustment
        let clampedProgression = max(0, min(1.0, progressionFactor))
        let adjustment = config.initialAdjustment +
            (config.finalAdjustment - config.initialAdjustment) * clampedProgression

        // Choose blend target based on zone type
        let blendTarget: Double
        if base < 1.0 {
            // Fast zones (4, 5): blend toward conservativeTarget (above race pace)
            blendTarget = config.conservativeTarget
        } else if base > 1.0 {
            // Easy zones (1, 2): blend toward conversational pace ratio
            // but never make a zone faster than its standard multiplier
            blendTarget = max(base, gapRatio)
        } else {
            // Zone 3 (Marathon Pace): always hit the target. A "Marathon Pace"
            // workout exists to practice race-day pacing — blending it toward
            // the runner's current easy pace defeats the purpose.
            return base
        }

        let adjusted = base + (blendTarget - base) * gapFactor * adjustment

        // Apply floor for fast zones only - never go faster than minMultiplier
        if base < 1.0 {
            return max(adjusted, config.minMultiplier)
        }
        return adjusted
    }

    // MARK: - Quality Pace Multiplier (anchored to 5K speed)

    /// Multiplier applied to the runner's **5K pace** for quality zones, with
    /// level-appropriate easing. Goal-distance independent (Daniels/Pfitzinger):
    ///   - Zone 5 (VO2 intervals) → 5K race pace          (target 1.00)
    ///   - Zone 4 (threshold/LT)  → 15K-HM pace           (target ~1.06)
    /// Less-fit tiers ease in from a slower start; competitive sits at target
    /// from day 1 (Pro VO2 work at true 5K pace).
    public static func qualitySpeedMultiplier(
        for zone: Int,
        progressionFactor: Double,
        config: PaceProgressionConfig,
        tenK: Bool = false,
        z5Target: Double? = nil
    ) -> Double {
        // Anchored to 5K SPEED, all PROGRESSING toward a sharper target over the
        // block (depth per level via initialAdjustment), never sagging to race:
        //   • Z5 VO2 — rep-length-aware (z5Target): short reps run I/R-pace
        //     (faster than 5K), long reps ~I-pace. Eases over a 0.06 band.
        //   • Z4 threshold — eases 1.06 (true LT, wk 1) → 1.02 (10K tempo, race wk).
        //   • 10K work — between.
        // Z4 THRESHOLD progresses true LT (wk 1, 1.07) → sharp 10K tempo (race wk,
        // 1.02) over a FULL ~15s span for EVERY level — the sharpening IS the
        // point, not a level-gated ease-in (initialAdjustment<1 made it nearly
        // flat, ~5s, on advanced). The caller's Z4 race floor keeps the true-LT
        // end from dropping 10K threshold below race.
        if zone == 4, !tenK {
            let sharp = 1.02, trueLT = 1.07
            if config.qualityZonesAlwaysAtTarget { return sharp }
            return trueLT + (sharp - trueLT) * max(0, min(1.0, progressionFactor))
        }
        // Z5 VO2 (rep-length-aware) + 10K-pace work ease in over a small band,
        // depth per level via initialAdjustment.
        let target: Double = tenK ? 1.01 : (z5Target ?? 0.96)
        let band: Double = 0.06
        if config.qualityZonesAlwaysAtTarget { return target }
        let slow: Double = target + band
        let p = max(0, min(1.0, progressionFactor))
        let adjustment = config.initialAdjustment +
            (config.finalAdjustment - config.initialAdjustment) * p
        let clampedAdj = max(0, min(1.0, adjustment))
        return target + (slow - target) * clampedAdj
    }

    // MARK: - Interval Conversion

    /// Converts an HR-based interval to pace-based with progression
    public static func convertIntervalToPace(
        interval: WorkoutInterval,
        racePace: Int,
        conversationalPace: Int? = nil,
        speedPace: Int? = nil,
        progressionFactor: Double = 0.5,
        config: PaceProgressionConfig = .intermediate,
        subtype: WorkoutSubtype? = nil,
        vdotAnchored: Bool = false
    ) -> WorkoutInterval {
        var newTarget: TargetRange
        var roundToFive = true   // quantize pace to 5s; OFF for Z3 (exact goal pace)
        switch interval.target {
        case .heartRateZone(let zone):
            if let speedPace = speedPace, zone >= 4 {
                // Quality zones (Z4 threshold, Z5 VO2 intervals) anchor to the
                // runner's 5K SPEED, not the goal-race pace. A threshold run is
                // 15K-HM pace and an interval is 5K pace whether the goal is a 5K
                // or a marathon (Daniels/Pfitzinger). Anchoring these to goal pace
                // made marathon "intervals" run at marathon pace.
                let relative: Double
                if subtype == .strides {
                    // Strides: short (≤30s) neuromuscular accelerations run with
                    // full recovery — pure leg-speed / form work, NOT a progressive
                    // VO2 stimulus. Price at ~0.85× 5K speed (≈ 800m–mile effort —
                    // clearly faster than REP pace, which is only the floor) and
                    // FLAT — no ease-in. The Z5 tag means "fast turnover", not
                    // "5K-pace aerobic"; running them through the quality ease-in
                    // renders early-plan strides at ~threshold pace, far too slow.
                    relative = 0.85
                } else if subtype == .timeTrial {
                    // A time trial is a sustained race-effort test (15-25min ≈ a 5K-
                    // 10K race). Render it FLAT at ~5K pace so it always reads faster
                    // than the threshold run it's paired with (threshold = 1.02-1.07×
                    // speed) instead of colliding with it at the same Z4 pace. The
                    // anchor still moves current→projected VDOT, so the TT sharpens.
                    relative = 1.00
                } else {
                    let isTenK = subtype == .tenkPace || subtype == .raceRehearsal10K
                    // Hill repeats are tagged Z4 (hill HR ≈ LT) but the training
                    // effect is VO2/power and the flat-equivalent effort is ~I-pace.
                    // Route them through the Z5 path at I-pace (0.96) so they render
                    // clearly FASTER than a threshold run instead of colliding with
                    // it at the same Z4 pace. Still progresses (the speed anchor
                    // moves) and still pins for competitive (qualityZonesAlwaysAtTarget).
                    let isHills = subtype == .hillRepeats
                    let effZone = isHills ? 5 : zone
                    // Z5 VO2 is REP-LENGTH-AWARE: short reps run R/I-pace (faster),
                    // long reps ~I-pace — you can't hold 1km reps at 400m pace.
                    //   ≤90s → 0.88 (1500/800m), ≤3min → 0.92 (3K), longer → 0.96 (I).
                    let z5Target: Double? = isHills ? 0.96
                        : ((zone >= 5 && !isTenK)
                            ? (interval.duration <= 90 ? 0.88
                                : (interval.duration <= 180 ? 0.92 : 0.96))
                            : nil)
                    var r = qualitySpeedMultiplier(
                        for: effZone, progressionFactor: progressionFactor, config: config,
                        tenK: isTenK, z5Target: z5Target)
                    // 10K-pace floor: "10K Pace" / 10K race-rehearsal work must not ease
                    // in slower than race. On a 10K plan (race ≈ 10K pace) it pins at
                    // race; half/marathon (10K pace faster than race) stay untouched.
                    if isTenK {
                        r = min(r, Double(racePace) / Double(speedPace))
                    }
                    // Z5 VO2 (and hills) never sag slower than race pace (5K/10K,
                    // where speed ≈ race).
                    if effZone >= 5 {
                        r = min(r, Double(racePace) / Double(speedPace))
                    }
                    // Z4 threshold race floor for 10K-and-longer (racePace slower
                    // than 5K speed): the true-LT (1.07) end of the progression
                    // would otherwise render early 10K threshold/mile-reps AT or
                    // below the 10K race pace. No-op on 5K (race == 5K speed, so
                    // threshold stays correctly slower than the 5K race) and on
                    // half/marathon (Z4 is already well faster than race). Hills
                    // excluded — rendered through the Z5 path above.
                    if zone == 4, !isHills, racePace > speedPace {
                        r = min(r, Double(racePace) / Double(speedPace))
                    }
                    relative = r
                }
                newTarget = .paceTarget(basePace: speedPace, relative: relative)
            } else {
                // Z1/Z2 (easy) and Z3 (marathon pace) stay anchored to race pace.
                // Z3 = the EXACT race-day goal pace; keep it exact (don't 5s-round).
                if zone == 3 { roundToFive = false }
                let relative = progressiveMultiplier(
                    for: zone,
                    racePace: racePace,
                    conversationalPace: conversationalPace,
                    progressionFactor: progressionFactor,
                    config: config,
                    vdotAnchored: vdotAnchored
                )
                newTarget = .paceTarget(basePace: racePace, relative: relative)
            }
        case .noRange:
            // Assign easy pace (zone 2 equivalent) for warmup/rest/cooldown with no target
            let easyRelative = progressiveMultiplier(
                for: 2,
                racePace: racePace,
                conversationalPace: conversationalPace,
                progressionFactor: progressionFactor,
                config: config,
                vdotAnchored: vdotAnchored
            )
            newTarget = .paceTarget(basePace: racePace, relative: easyRelative)
        default:
            newTarget = interval.target
        }

        // Quantize the displayed pace to the nearest 5s so every progressing target
        // steps cleanly (6:25→6:20→…, 5:18→5:20) instead of drifting 1s/week.
        // Nearest (not strict round-up) keeps 5K/10K VO2 from rounding ONTO race
        // pace. Z3 goal pace and non-pace (HR) targets pass through untouched.
        if roundToFive, case let .paceTarget(basePace, relative) = newTarget, basePace > 0 {
            let rounded = (Double(basePace) * relative / 5.0).rounded() * 5.0
            // +0.5 so the downstream Int(basePace × relative) floors back to the
            // exact 5s multiple instead of one second under (380 → 6:20, not 6:19).
            newTarget = .paceTarget(basePace: basePace, relative: (rounded + 0.5) / Double(basePace))
        }

        return WorkoutInterval(
            id: interval.id,
            type: interval.type,
            duration: interval.duration,
            distance: interval.distance,
            targetType: interval.targetType,
            target: newTarget
        )
    }

    // MARK: - Workout Conversion

    /// Converts an HR-based workout to pace-based with progression
    public static func convertHRWorkoutToPace(
        workout: Workout,
        racePace: Int,
        conversationalPace: Int? = nil,
        speedPace: Int? = nil,
        progressionFactor: Double = 0.5,
        config: PaceProgressionConfig = .intermediate,
        vdotAnchored: Bool = false
    ) -> Workout {
        let convertedIntervals = workout.intervals.map { interval in
            convertIntervalToPace(
                interval: interval,
                racePace: racePace,
                conversationalPace: conversationalPace,
                speedPace: speedPace,
                progressionFactor: progressionFactor,
                config: config,
                subtype: workout.subtype,
                vdotAnchored: vdotAnchored
            )
        }

        return Workout(
            id: workout.id,
            title: workout.title,
            type: workout.type,
            subtype: workout.subtype,
            trainingType: workout.trainingType,
            targetType: workout.targetType,
            duration: workout.duration,
            distance: workout.distance,
            key: workout.key,
            trainingLoad: workout.trainingLoad,
            intervals: convertedIntervals,
            workRestRatio: workout.workRestRatio,
            workDuration: workout.workDuration,
            restDuration: workout.restDuration,
            workDistance: workout.workDistance,
            restDistance: workout.restDistance
        )
    }

    /// Batch convert all workouts (no progression - for backward compatibility)
    public static func convertWorkoutsArrayToPace(workouts: [Workout], racePace: Int, conversationalPace: Int? = nil) -> [Workout] {
        return workouts.map { convertHRWorkoutToPace(workout: $0, racePace: racePace, conversationalPace: conversationalPace) }
    }

    // MARK: - Plan Post-Processing (Progressive Conversion)

    /// Converts all HR-based workout events to pace-based with progressive intensity.
    /// Each event gets a progressionFactor based on its position in the plan.
    /// Earlier workouts are more conservative, later workouts are more aggressive.
    ///
    /// - Parameters:
    ///   - events: Generated plan events (with HR-based workouts)
    ///   - racePace: Target race pace in seconds/km
    ///   - conversationalPace: Current easy pace in seconds/km (nil = no gap adjustment)
    ///   - config: Progression config for the runner's level
    ///   - startDate: Plan start date
    ///   - endDate: Plan end date (race date)
    /// - Returns: Events with pace-based workouts, progressively adjusted
    public static func applyPaceProgression(
        to events: [WorkoutEvent],
        racePace: Int,
        conversationalPace: Int?,
        speedPace: Int? = nil,
        config: PaceProgressionConfig,
        startDate: Date,
        endDate: Date,
        racePaceEnd: Int? = nil,
        conversationalPaceEnd: Int? = nil,
        speedPaceEnd: Int? = nil
    ) -> [WorkoutEvent] {
        let totalDuration = endDate.timeIntervalSince(startDate)

        guard totalDuration > 0 else { return events }

        // VDOT-progression mode: when projected (race-week) paces are supplied the
        // anchors interpolate from current-VDOT (week 1) to projected-VDOT (race
        // week) across the plan. The projected fitness gain IS the progression —
        // bigger for longer plans and lower-fitness runners, flat near the ceiling.
        // Easy rides the moving anchor; quality keeps its sharpening on top of the
        // moving 5K-speed anchor. No end-paces → legacy fixed-anchor behavior.
        let vdotAnchored = racePaceEnd != nil

        return events.map { event in
            // Calculate progression factor: 0.0 at plan start → 1.0 at plan end
            let elapsed = event.date.timeIntervalSince(startDate)
            let progressionFactor = max(0, min(1.0, elapsed / totalDuration))

            func lerp(_ a: Int, _ b: Int?) -> Int {
                guard let b = b else { return a }
                return Int((Double(a) + (Double(b) - Double(a)) * progressionFactor).rounded())
            }
            let racePaceNow = lerp(racePace, racePaceEnd)
            let easyPaceNow = conversationalPace.map { lerp($0, conversationalPaceEnd) }
            let speedPaceNow = speedPace.map { lerp($0, speedPaceEnd) }

            // Convert this event's workout with its specific progression
            let convertedWorkout = convertHRWorkoutToPace(
                workout: event.workout,
                racePace: racePaceNow,
                conversationalPace: easyPaceNow,
                speedPace: speedPaceNow,
                progressionFactor: progressionFactor,
                config: config,
                vdotAnchored: vdotAnchored
            )

            // Create updated event
            var updatedEvent = event
            updatedEvent.workout = convertedWorkout
            return updatedEvent
        }
    }

    // MARK: - Helper Functions

    /// Calculate target pace range with tolerance
    public static func paceRange(basePace: Int, relative: Double, tolerance: Double = 0.10) -> (min: Int, max: Int) {
        let targetPace = Int(Double(basePace) * relative)
        let delta = Int(Double(targetPace) * tolerance)
        return (min: targetPace - delta, max: targetPace + delta)
    }

    /// Round pace to nearest 5 seconds
    public static func roundToFiveSeconds(_ seconds: Int) -> Int {
        return ((seconds + 2) / 5) * 5
    }

    /// Format pace as string in user's preferred units
    public static func formatPace(_ paceSecondsPerKm: Int) -> String {
        return PaceConversion.formatPaceInUserUnits(paceSecondsPerKm)
    }
}
