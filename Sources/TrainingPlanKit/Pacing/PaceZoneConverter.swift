//
//  PaceZoneConverter.swift
//  RunPlan
//
//  Created by Claude Code on 06/02/2026.
//

import Foundation

// MARK: - Workout Pace Tolerance
//
// The "on target" pace window shown during a workout. Symmetric in
// seconds-per-km (not a percentage) — a wrist-worn display resolves the
// same ±15s regardless of absolute pace.
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

    /// Standard (unadjusted) pace multiplier for an HR zone (1-5), applied to
    /// race pace. Z1 recovery (slowest) → Z5 intervals (fastest); see values.
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

        // Easy/recovery: anchor to the runner's VDOT-derived easy (never the
        // generic 1.15×race). Take this path for non-competitive, or when easy
        // is at/under base, or for the AT-GOAL competitive config (its gap-blend
        // has zero movement and would otherwise freeze easy flat). The build-band
        // (initialAdjustment 0.5) keeps the gap-blend so easy converges toward
        // goal as fitness builds. Floored at race; recovery (Z1) scaled by base/1.15.
        if base > 1.0, (!config.qualityZonesAlwaysAtTarget || gapRatio < base || config.initialAdjustment == 0) {
            let flat = max(1.0, gapRatio) * (base / 1.15)
            // VDOT mode: the easy anchor (conversationalPace) is already interpolated
            // current→projected VDOT upstream, so the fitness progression lives in the
            // anchor — return the flat gap and let the moving anchor carry it.
            if vdotAnchored { return flat }
            // Legacy mode: ~6.5% easing over the WHOLE plan as a modeled slice of the
            // projected fitness gain (same effort, pace drifts down as the runner
            // adapts). 5s-quantized downstream. Guardrail, not a target.
            // Clamp at 1.0 (race pace): when easy↔race headroom is below the 6.5%
            // easing (gapRatio−1 < 0.065 — at-goal competitive, slow runners), the
            // eased aerobic pace would otherwise underflow race. Easy must be ≥ race.
            let p = max(0, min(1.0, progressionFactor))
            return max(1.0, flat * (1.0 - 0.065 * p))
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
        // Anchored to 5K SPEED, progressing toward a sharper target over the
        // block, never sagging to race. Z4 threshold progresses true LT (wk 1,
        // 1.07) → sharp 10K tempo (race wk, 1.02) over a FULL span for EVERY
        // level — the sharpening IS the point, not a level-gated ease-in. The
        // caller's Z4 race floor keeps the true-LT end from dropping below race.
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
        // Easy/recovery (Z1/Z2) anchored to race: the multiplier is already floored
        // at race, but 5s-quantization can round a race-pace easy DOWN to the next
        // lower 5s (256→255), i.e. faster than race. Floor the rounded pace at race
        // so the aerobic floor survives rounding. Only the easy/noRange branches set this.
        var floorAtBasePace = false
        switch interval.target {
        case .heartRateZone(let zone):
            if let speedPace = speedPace, zone >= 4 {
                // Quality zones (Z4 threshold, Z5 VO2 intervals) anchor to the
                // runner's 5K SPEED, not the goal-race pace. A threshold run is
                // 15K-HM pace and an interval is 5K pace whether the goal is a 5K
                // or a marathon (Daniels/Pfitzinger). Anchoring these to goal pace
                // made marathon "intervals" run at marathon pace.
                let relative: Double
                if subtype == .fastFinish, interval.type == .work {
                    // Fast-finish tail is tagged Z4 (HR≈LT) but the intent is a
                    // 5K-effort surge — render FLAT at ~5K pace so it reads faster
                    // than threshold. The easy portion (Z2) stays easy below.
                    relative = 1.00
                } else if subtype == .strides {
                    // Strides are short neuromuscular accelerations (leg-speed/form),
                    // not a VO2 stimulus — price FLAT at ~0.85× 5K speed (≈800m–mile
                    // effort). The Z5 tag means "fast turnover", not "5K-pace aerobic".
                    relative = 0.85
                } else if subtype == .timeTrial {
                    // A time trial is a sustained race-effort test — render FLAT at
                    // ~5K pace so it reads faster than its paired threshold run
                    // instead of colliding at the same Z4 pace.
                    relative = 1.00
                } else {
                    let isTenK = subtype == .tenkPace || subtype == .raceRehearsal10K
                    // Hill repeats are tagged Z4 (hill HR≈LT) but the effect is
                    // VO2/power — route through the Z5 path at I-pace (0.96) so they
                    // read faster than threshold instead of colliding with it.
                    let isHills = subtype == .hillRepeats
                    let effZone = isHills ? 5 : zone
                    // Z5 VO2 is REP-LENGTH-AWARE: short reps run R/I-pace (faster),
                    // long reps ~I-pace. ≤90s→0.88, ≤3min→0.92, longer→0.96 (I).
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
                    // than 5K speed): the true-LT (1.07) end would otherwise render
                    // early 10K threshold/mile-reps at/below 10K race pace. No-op on
                    // 5K (race==speed) and half/marathon (Z4 already faster than race).
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
                // Easy/recovery is the aerobic floor — never let quantization round it
                // faster than race (Z3 MP is meant to sit AT race, so it's exempt).
                if zone <= 2 { floorAtBasePace = true }
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
            floorAtBasePace = true
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
            var rounded = (Double(basePace) * relative / 5.0).rounded() * 5.0
            // Aerobic floor: a race-anchored easy/recovery pace must never render
            // faster than race. When 5s-rounding pulls it below race (e.g. 256→255),
            // pin it AT race instead. Only binds in the low-headroom zone (easy≈race);
            // typical runners round well above race and are untouched.
            if floorAtBasePace, rounded < Double(basePace) { rounded = Double(basePace) }
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

    /// On 5K/10K, a `progression` workout whose Work blocks are Z3 then Z4 (no
    /// easy Z2 opener) collapses at render: Z3 lands at race pace and Z4 is
    /// race-floored, so both blocks are ≈1s/km apart. Demote the Z3 Work
    /// block(s) to Z2 so the run renders as a genuine easy→fast progression.
    /// No-op for: non-progressions, distances > 10K (Z4 stays faster than race),
    /// and progressions that already contain a Z2 Work block.
    private static func degenerateZ3ToZ4ProgressionFix(
        workout: Workout, raceDistanceMeters: Int?
    ) -> [WorkoutInterval] {
        guard workout.subtype == .progression,
              let dist = raceDistanceMeters, dist <= 10000 else { return workout.intervals }
        let workZones: [Int] = workout.intervals.compactMap { iv in
            guard iv.type == .work, case .heartRateZone(let z) = iv.target else { return nil }
            return z
        }
        // Only the pure Z3→Z4 shape (has Z3 and Z4, no Z2 opener) collapses.
        guard workZones.contains(3), workZones.contains(4), !workZones.contains(2)
        else { return workout.intervals }
        return workout.intervals.map { iv in
            guard iv.type == .work, iv.target == .heartRateZone(zone: 3) else { return iv }
            return WorkoutInterval(
                id: iv.id, type: iv.type, duration: iv.duration, distance: iv.distance,
                targetType: iv.targetType, target: .heartRateZone(zone: 2))
        }
    }

    /// Converts an HR-based workout to pace-based with progression
    public static func convertHRWorkoutToPace(
        workout: Workout,
        racePace: Int,
        conversationalPace: Int? = nil,
        speedPace: Int? = nil,
        progressionFactor: Double = 0.5,
        config: PaceProgressionConfig = .intermediate,
        vdotAnchored: Bool = false,
        raceDistanceMeters: Int? = nil,
        isCompetitive: Bool = false,
        isBeginner: Bool = false
    ) -> Workout {
        // 5K/10K race pace ≈ 5K speed, so a Z3 (MP) block renders at race pace and
        // an adjacent Z4 (threshold) block is race-floored too — a `Z3→Z4`
        // "Progression Run" collapses to a ~1s/km span (both blocks ≈ race). When
        // such a progression has no easy (Z2) opener, demote its Z3 block(s) to Z2
        // so it reads as a real easy→fast progression. Longer races are untouched
        // (their Z4 stays faster than race), as are shapes that already open easy.
        let sourceIntervals = degenerateZ3ToZ4ProgressionFix(
            workout: workout, raceDistanceMeters: raceDistanceMeters)
        let convertedIntervals = sourceIntervals.map { interval in
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

        let converted = Workout(
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

        return clampLongRunDistance(converted,
                                    conversationalPace: conversationalPace,
                                    raceDistanceMeters: raceDistanceMeters,
                                    isCompetitive: isCompetitive,
                                    isBeginner: isBeginner,
                                    progressionFactor: progressionFactor)
    }

    /// Long-run subtypes whose duration is generated pace-blind (in minutes)
    /// and therefore needs a per-distance KM window applied at render so a fast
    /// runner's marathon long run doesn't balloon to 45+ km and a slow runner's
    /// doesn't shrink below the aerobic-development floor.
    private static let longRunSubtypes: Set<WorkoutSubtype> = [
        .long, .steadyLong, .progressiveLong,
        .raceRehearsalM, .raceRehearsalHM, .raceRehearsal10K, .fastFinish
    ]

    /// Clamps a long run into a per-distance KM window [floorKm, capKm].
    /// Long runs are generated pace-blind in minutes; at render a fast runner
    /// overshoots and a slow runner falls short, so scale duration uniformly to
    /// fit the window (paces, targets and the easy/fast split are preserved).
    private static func clampLongRunDistance(
        _ workout: Workout,
        conversationalPace: Int?,
        raceDistanceMeters: Int?,
        isCompetitive: Bool,
        isBeginner: Bool,
        progressionFactor: Double
    ) -> Workout {
        guard longRunSubtypes.contains(workout.subtype) else { return workout }
        // Easy pace anchors the minutes→km conversion for any interval that
        // somehow lacks a rendered pace. No easy pace → can't know the
        // distance, so leave the (minutes-based) workout untouched.
        guard let easyPace = conversationalPace, easyPace > 0 else { return workout }

        // Per-distance window [floorKm, capKm]. Marathon/half floor brings slow
        // runners up to race-relevant distance; 10K/5K are cap-only (their long
        // run wasn't short, and a floor would inflate it past Higdon norms).
        let floorKm: Double, capKm: Double
        switch raceDistanceMeters {
        // Competitive marathoners train longer long runs (Pfitz 18/85 ~35-38km).
        // Beginner marathoners cap shorter — the long run holds to ~190min (3:00-
        // 3:10), so a slow novice isn't run for 3.5h+ (see begMarathonLRCapMins).
        // Beginner marathon is CAP-ONLY (no floor): the HR-side longRunProgression
        // already ramps the long run 90→180min, so a km floor would inflate the
        // early base runs up to the cap and flatten the build. Cap (+ the 190min
        // ceiling below) just holds the top so a slow novice isn't run 3.5h+.
        case 42195: (floorKm, capKm) = isCompetitive ? (32, 38)
                                     : isBeginner ? (0, 28) : (30, 34)
        case 21097: (floorKm, capKm) = (16, 21)
        case 10000: (floorKm, capKm) = (0, 16)
        case 5000:  (floorKm, capKm) = (0, 12)
        default:    (floorKm, capKm) = (0, 34)
        }

        // Floor applies only in build phases — extending a taper/race-week long
        // run up to the floor would flatten the taper (it's meant to be short).
        let effectiveFloor = progressionFactor < 0.85 ? floorKm : 0
        // Size off the CONVERTED workout's rendered pace, not raw easy pace: a
        // long run renders ~15s/km faster (and MP/fast-finish segments faster
        // still), so duration/easyPace under-measures and the run overshoots
        // the window. Sum each interval's km = duration ÷ its rendered pace.
        let km = workout.intervals.reduce(0.0) { acc, iv in
            let paceSec: Double
            if case .paceTarget(let base, let rel) = iv.target {
                paceSec = Double(base) * rel
            } else {
                paceSec = Double(easyPace)
            }
            return paceSec > 0 ? acc + iv.duration / paceSec : acc
        }
        guard km > 0 else { return workout }
        let targetKm = min(max(km, effectiveFloor), capKm)
        guard abs(targetKm - km) >= 0.1 else { return workout }

        // Scaling every interval's duration by this factor scales rendered km by
        // the same factor (paces are unchanged), landing the run on targetKm.
        // Floor the factor so the run never drops below the engine's 60min
        // long-run minimum (a fast 5K runner's >12km run would otherwise scale
        // under 60min and violate the long-run floor).
        let minSec = Double(min(Int(workout.duration), 60 * 60))
        var factor = max(targetKm / km, minSec / Double(workout.duration))
        // Hard minute ceiling for the beginner marathon long run: km windows are
        // pace-relative, so the slowest novice could still cross 190min at the
        // 28km cap. Clamp the factor so the rendered run never exceeds the cap.
        if isBeginner, raceDistanceMeters == 42195 {
            let begMarathonLRCapMins = 190
            let capFactor = Double(begMarathonLRCapMins * 60) / Double(workout.duration)
            if capFactor > 0 { factor = min(factor, capFactor) }
        }
        let newDurationSec = Int((Double(workout.duration) * factor).rounded())

        func scale(_ v: Int64) -> Int64 { Int64((Double(v) * factor).rounded()) }
        let scaledIntervals = workout.intervals.map { iv in
            WorkoutInterval(
                id: iv.id,
                type: iv.type,
                duration: iv.duration * factor,
                distance: iv.distance,
                targetType: iv.targetType,
                target: iv.target
            )
        }

        return Workout(
            id: workout.id,
            title: workout.title,
            type: workout.type,
            subtype: workout.subtype,
            trainingType: workout.trainingType,
            targetType: workout.targetType,
            duration: Int64(newDurationSec),
            distance: workout.distance,
            key: workout.key,
            trainingLoad: scale(workout.trainingLoad),
            intervals: scaledIntervals,
            workRestRatio: workout.workRestRatio,
            workDuration: scale(workout.workDuration),
            restDuration: scale(workout.restDuration),
            workDistance: workout.workDistance,
            restDistance: workout.restDistance
        )
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
        speedPaceEnd: Int? = nil,
        raceDistanceMeters: Int? = nil,
        isCompetitive: Bool = false,
        isBeginner: Bool = false
    ) -> [WorkoutEvent] {
        let totalDuration = endDate.timeIntervalSince(startDate)

        guard totalDuration > 0 else { return events }

        // VDOT-progression mode: when projected (race-week) paces are supplied the
        // anchors interpolate current-VDOT (wk 1) → projected-VDOT (race wk) across
        // the plan — the projected fitness gain IS the progression. No end-paces →
        // legacy fixed-anchor behavior.
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
                vdotAnchored: vdotAnchored,
                raceDistanceMeters: raceDistanceMeters,
                isCompetitive: isCompetitive,
                isBeginner: isBeginner
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
