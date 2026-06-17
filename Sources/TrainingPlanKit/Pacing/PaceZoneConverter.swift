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
    /// from day 1 — forces real race-pace exposure. Easy/long zones gap-
    /// blend from VDOT-derived current easy pace at W1 toward goal easy
    /// pace at race week, mirroring `.advanced`'s initial=0.5/final=0.0
    /// envelope.
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
        config: PaceProgressionConfig
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
        config: PaceProgressionConfig
    ) -> Double {
        let target: Double = (zone >= 5) ? 1.00 : 1.06   // 5K pace / threshold
        // Competitive/build-band lock quality at goal pace from day 1 (no easing).
        if config.qualityZonesAlwaysAtTarget { return target }
        let slow: Double   = (zone >= 5) ? 1.12 : 1.16   // conservative start
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
        config: PaceProgressionConfig = .intermediate
    ) -> WorkoutInterval {
        let newTarget: TargetRange
        switch interval.target {
        case .heartRateZone(let zone):
            if let speedPace = speedPace, zone >= 4 {
                // Quality zones (Z4 threshold, Z5 VO2 intervals) anchor to the
                // runner's 5K SPEED, not the goal-race pace. A threshold run is
                // 15K-HM pace and an interval is 5K pace whether the goal is a 5K
                // or a marathon (Daniels/Pfitzinger). Anchoring these to goal pace
                // made marathon "intervals" run at marathon pace.
                let relative = qualitySpeedMultiplier(
                    for: zone, progressionFactor: progressionFactor, config: config)
                newTarget = .paceTarget(basePace: speedPace, relative: relative)
            } else {
                // Z1/Z2 (easy) and Z3 (marathon pace) stay anchored to race pace.
                let relative = progressiveMultiplier(
                    for: zone,
                    racePace: racePace,
                    conversationalPace: conversationalPace,
                    progressionFactor: progressionFactor,
                    config: config
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
                config: config
            )
            newTarget = .paceTarget(basePace: racePace, relative: easyRelative)
        default:
            newTarget = interval.target
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
        config: PaceProgressionConfig = .intermediate
    ) -> Workout {
        let convertedIntervals = workout.intervals.map { interval in
            convertIntervalToPace(
                interval: interval,
                racePace: racePace,
                conversationalPace: conversationalPace,
                speedPace: speedPace,
                progressionFactor: progressionFactor,
                config: config
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
        endDate: Date
    ) -> [WorkoutEvent] {
        let totalDuration = endDate.timeIntervalSince(startDate)

        guard totalDuration > 0 else { return events }

        return events.map { event in
            // Calculate progression factor: 0.0 at plan start → 1.0 at plan end
            let elapsed = event.date.timeIntervalSince(startDate)
            let progressionFactor = max(0, min(1.0, elapsed / totalDuration))

            // Convert this event's workout with its specific progression
            let convertedWorkout = convertHRWorkoutToPace(
                workout: event.workout,
                racePace: racePace,
                conversationalPace: conversationalPace,
                speedPace: speedPace,
                progressionFactor: progressionFactor,
                config: config
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
