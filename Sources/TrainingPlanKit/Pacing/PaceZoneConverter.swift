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
        vdotAnchored: Bool = false,
        goalLocked: Bool = false
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
            // Goal-locked (competitive): fitness is at goal from day 1 — no gain to
            // model, no easing (it eroded Pro easy to ~MP+5% by taper). And Pro easy
            // must be truly conversational: floor at Pfitz's GA band, ~MP+18%
            // (VDOT-easy at elite fitness sits only ~MP+11%). Z1 scales via base.
            if goalLocked { return max(flat, 1.18 * (base / 1.15)) }
            if vdotAnchored { return flat }
            // Legacy mode: ~6.5% easing over the WHOLE plan as a modeled slice of the
            // projected fitness gain (same effort, pace drifts down as the runner
            // adapts). 5s-quantized downstream. Guardrail, not a target.
            // Floor at 1.03, not 1.0: easy must stay visibly slower than race/MP.
            // At 1.0 a small easy↔race gap (low-VDOT runners) collapsed a race
            // rehearsal's warmup/cooldown onto its MP block — three identical paces.
            let p = max(0, min(1.0, progressionFactor))
            return max(1.03, flat * (1.0 - 0.065 * p))
        }

        // Build-band easy (the one easy case left: qualityLocked config with a
        // real current↔goal gap): ease the runner's CURRENT easy toward the
        // goal-easy multiplier across the plan. Explicit and linear — the only
        // sanctioned non-anchor easy progression, because build-band anchors
        // are goal-fixed by design (quality locked at goal from day 1).
        if base > 1.0 {
            let p = max(0, min(1.0, progressionFactor))
            // Start-depth = initialAdjustment (0.5 for build-band): W1 sits halfway
            // between goal-easy and the runner's current easy — deliberately not the
            // full current easy (that's the at-goal flat route), so a build-band
            // runner feels goal-ward pull from day 1. Ends at goal easy.
            let full = max(base, gapRatio)
            let start = base + (full - base) * config.initialAdjustment
            return start + (base - start) * p
        }

        // Zone 3 (Marathon Pace): ALWAYS the race anchor, exactly. A "Marathon
        // Pace" workout exists to practice race-day pacing; all progression
        // lives in the moving anchor (current → projected), never in a blend.
        if zone == 3 { return base }

        // Fast zones (4/5) without a 5K anchor: fixed base multipliers on the
        // race anchor. The old "conservative blend" engine (conservativeTarget /
        // initialAdjustment easing) is deleted — it stacked a second progression
        // on top of the anchors and produced intervals slower than easy runs.
        return max(base, config.minMultiplier)
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
        // depth per level via initialAdjustment. The band closes by 60% of the
        // plan (pEff), NOT race week: a marathoner's PEAK-phase "Intervals" must
        // run at true VO2 pace, not linger just under 5K pace to the very end.
        let target: Double = tenK ? 1.01 : (z5Target ?? 0.96)
        let band: Double = 0.06
        if config.qualityZonesAlwaysAtTarget { return target }
        // The slow end is capped so "Intervals" NEVER render slower than the
        // runner's current 5K pace (1.03 for 10K-pace work — a touch over 10K).
        // A VO2 session slower than 5K isn't a VO2 session.
        let slow: Double = min(target + band, tenK ? 1.03 : 1.0)
        let p = min(1.0, max(0, progressionFactor) / 0.6)
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
        vdotAnchored: Bool = false,
        racePaceFinal: Int? = nil,
        speedPaceFinal: Int? = nil,
        raceDistanceMeters: Int? = nil,
        isCompetitive: Bool = false
    ) -> WorkoutInterval {
        // Race-pace work is prescribed at the PLANNED race-day pace — Daniels/
        // Pfitz: you practice THE pace; the progression is dose (60→70→90min
        // rungs), never a slower rehearsal pace. Without end anchors (Pro,
        // legacy) this equals racePace, so goal-locked plans are unchanged.
        let plannedRacePace = racePaceFinal ?? racePace
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
                let plannedSpeedPace = speedPaceFinal ?? speedPace
                // Ladders/pyramids and hills are interval WORK whatever their HR
                // tag says (short-rung ladders are Z4-tagged in the catalog and
                // rendered at threshold — slower than hills in the same plan).
                // "Intervals"/ladders/pyramids are interval WORK whatever the
                // catalog's HR tag says — a Z4-tagged "Intervals" rendering at
                // threshold pace is the R8 complaint, not a design choice.
                let isLadder = subtype == .intervals || subtype == .ladderIntervals
                    || subtype == .pyramidIntervals
                let isHills = subtype == .hillRepeats
                let isTenKWork = subtype == .tenkPace || subtype == .raceRehearsal10K
                if isTenKWork, raceDistanceMeters == 10000 {
                    // 10K-plan race-pace work is race-pace practice, same rule as
                    // Z3/MP: the PLANNED race pace, exact.
                    roundToFive = false
                    newTarget = .paceTarget(basePace: plannedRacePace, relative: 1.0)
                } else if isTenKWork {
                    // Half/marathon "10K Pace" quality: planned-fitness 10K
                    // (1.01×planned 5K), flat — dose ramps, pace doesn't.
                    newTarget = .paceTarget(basePace: plannedSpeedPace, relative: 1.01)
                } else if zone >= 5 || isHills || isLadder {
                    // VO2/rep work anchors to the PLANNED 5K, flat, rep-length-
                    // aware — same philosophy as MP: practice destination pace,
                    // progress the dose. Short reps run FASTER than 5K (R/I-pace):
                    // ≤90s→0.88, ≤3min→0.92, longer + hills→0.96 (I-pace).
                    let target: Double = isHills ? 0.96
                        : (interval.duration <= 90 ? 0.88
                            : (interval.duration <= 180 ? 0.92 : 0.96))
                    // Never slower than the planned race on 5K/10K (speed ≈ race).
                    let rel = min(target, Double(plannedRacePace) / Double(plannedSpeedPace))
                    newTarget = .paceTarget(basePace: plannedSpeedPace, relative: rel)
                } else {
                    // Z4 threshold-family (threshold, mile repeats, tempo): a
                    // CURRENT-fitness physiological stimulus — rides the moving 5K
                    // anchor with the LT→tempo emphasis curve (see qualityRelative).
                    var relative = qualityRelative(
                        zone: zone, interval: interval, subtype: subtype,
                        progressionFactor: progressionFactor, config: config,
                        racePace: racePace, speedPace: speedPace)
                    // HALF/MARATHON only: threshold must stay faster than race-day
                    // MP (early-plan LT on low-VDOT runners can cross the flat
                    // planned MP) — cap it 5s/km under. NEVER on 5K/10K, where race
                    // pace sits AT/above threshold and the cap would collapse every
                    // threshold session onto race effort (R12 Adv finding).
                    if let dist = raceDistanceMeters, dist >= 21097 {
                        let mpCap = (Double(plannedRacePace) - 5) / Double(speedPace)
                        if mpCap > 0 { relative = min(relative, mpCap) }
                    }
                    newTarget = .paceTarget(basePace: speedPace, relative: relative)
                }
            } else {
                // Z1/Z2 (easy) anchored to the CURRENT race pace; Z3 (marathon
                // pace / rehearsal MP blocks) at the PLANNED race-day pace, exact.
                if zone == 3 {
                    roundToFive = false
                    newTarget = .paceTarget(basePace: plannedRacePace, relative: 1.0)
                    break
                }
                // Easy/recovery only — Z4/Z5 without a speed anchor run FASTER than
                // race (0.93/0.85×) and must never be floored up to race pace.
                if zone <= 2 { floorAtBasePace = true }
                var relative = progressiveMultiplier(
                    for: zone,
                    racePace: racePace,
                    conversationalPace: conversationalPace,
                    progressionFactor: progressionFactor,
                    config: config,
                    vdotAnchored: vdotAnchored,
                    goalLocked: isCompetitive
                )
                // Long-family Z2 WORK runs quicker than plain easy
                // (Pfitz: GA 15-25% off MP, long/ML 10-20%) — easy is the
                // slowest non-recovery run. Warmups/recoveries stay true easy.
                // 5% ≈ the mid-band Pfitz gap (was 3%, read as too subtle).
                // Competitive included: with Pro easy floored at MP+18%, the
                // bump lands Pro longs at ~MP+12.1% — inside the Pfitz band.
                if zone == 2, interval.type == .work,
                   subtype == .long || subtype == .mediumLong || subtype == .steadyLong {
                    relative *= 0.95
                }
                newTarget = .paceTarget(basePace: racePace, relative: relative)
            }
        case .noRange:
            // Warmup/rest/cooldown render at easy pace. RECOVERY-type intervals
            // render at the zone-1 multiplier (the slower between-reps jog):
            // the catalog's short recoveries are noRange for HR honesty (HR
            // can't reach Z1 in 60-90s), but their PACE must stay the Z1 jog —
            // this keeps the Z1→noRange catalog sweep a byte-exact noop.
            floorAtBasePace = true
            let easyRelative = progressiveMultiplier(
                for: (interval.type == .recovery || interval.type == .rest) ? 1 : 2,
                racePace: racePace,
                conversationalPace: conversationalPace,
                progressionFactor: progressionFactor,
                config: config,
                vdotAnchored: vdotAnchored,
                goalLocked: isCompetitive
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

    // MARK: - Quality pace policy (THE table)
    //
    // Every quality pace is a fixed relation × the runner's 5K-speed anchor.
    // Fitness progression lives EXCLUSIVELY in the moving anchors; the only
    // curves here are training-design ramps (threshold LT→tempo emphasis, the
    // Z5 ease-in that closes by 60% of the plan), never fitness knobs.
    private static func qualityRelative(
        zone: Int,
        interval: WorkoutInterval,
        subtype: WorkoutSubtype?,
        progressionFactor: Double,
        config: PaceProgressionConfig,
        racePace: Int,
        speedPace: Int
    ) -> Double {
        // Flat specials: subtypes whose Z-tag describes HR, not intent.
        if subtype == .fastFinish, interval.type == .work {
            return 1.00   // 5K-effort surge tail, faster than threshold
        }
        if subtype == .strides {
            return 0.85   // neuromuscular turnover (~800m-mile effort), not VO2
        }
        if subtype == .timeTrial {
            return 1.00   // sustained race-effort test at ~5K pace
        }

        // Only Z4 threshold-family work reaches this point (Z5/hills/ladders and
        // 10K-pace work anchor to PLANNED fitness upstream in convertIntervalToPace).
        var r = qualitySpeedMultiplier(
            for: zone, progressionFactor: progressionFactor, config: config)
        // Z4 threshold race floor for 10K-and-longer (racePace slower
        // than 5K speed): the true-LT (1.07) end would otherwise render
        // early 10K threshold/mile-reps at/below 10K race pace. No-op on
        // 5K (race==speed) and half/marathon (Z4 already faster than race).
        if zone == 4, racePace > speedPace {
            r = min(r, Double(racePace) / Double(speedPace))
        }
        return r
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
        isBeginner: Bool = false,
        isAdvanced: Bool = false,
        isTaperWeek: Bool = false,
        floorRampEnd: Double = 0.60,
        racePaceFinal: Int? = nil,
        speedPaceFinal: Int? = nil
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
                vdotAnchored: vdotAnchored,
                racePaceFinal: racePaceFinal,
                speedPaceFinal: speedPaceFinal,
                raceDistanceMeters: raceDistanceMeters,
                isCompetitive: isCompetitive
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

        let clamped = clampLongRunDistance(converted,
                                    conversationalPace: conversationalPace,
                                    raceDistanceMeters: raceDistanceMeters,
                                    isCompetitive: isCompetitive,
                                    isBeginner: isBeginner,
                                    isAdvanced: isAdvanced,
                                    isTaperWeek: isTaperWeek,
                                    progressionFactor: progressionFactor,
                                    floorRampEnd: floorRampEnd)
        return quantizeAerobicDuration(tickLongSegments(clamped))
    }

    /// Structured long runs (race rehearsals, fast finish) are km-scaled as a
    /// whole, which leaves segments at ragged minutes (107:59 @ MP). Round every
    /// major segment (≥10min) to the 5-min tick and rebuild the total from the
    /// segments, so warmup, work block and cooldown all read as prescriptions.
    private static let segmentTickSubtypes: Set<WorkoutSubtype> = [
        .raceRehearsalM, .raceRehearsalHM, .raceRehearsal10K, .fastFinish
    ]

    private static func tickLongSegments(_ w: Workout) -> Workout {
        guard segmentTickSubtypes.contains(w.subtype), w.duration > 0 else { return w }
        var changed = false
        var intervals = w.intervals.map { iv -> WorkoutInterval in
            // ≥10min segments tick to 5min; shorter WU/CD tick to whole minutes
            // (a 9:38 cooldown reads as 10:00, not a raw scale artifact).
            let unit: Double = iv.duration >= 600 ? 300.0 : 60.0
            let ticked = max(60.0, (iv.duration / unit).rounded() * unit)
            if ticked != iv.duration { changed = true }
            return WorkoutInterval(id: iv.id, type: iv.type, duration: ticked,
                                   distance: iv.distance, targetType: iv.targetType,
                                   target: iv.target)
        }
        guard changed else { return w }
        // Ticking each segment can swallow a small km-floor scale (every segment
        // rounds back down). Reconcile: pad the LONGEST slower segment in 5-min
        // steps until the ticked total is within 2.5min of the pre-tick total.
        let rawSum = w.intervals.reduce(0.0) { $0 + $1.duration }
        var tickedSum = intervals.reduce(0.0) { $0 + $1.duration }
        while tickedSum <= rawSum - 150 {
            let fastest = intervals.compactMap { iv -> Double? in
                if case .paceTarget(let b, let rel) = iv.target { return Double(b) * rel }
                return nil
            }.min() ?? 0
            guard let big = intervals.indices
                .filter({ iv in
                    if case .paceTarget(let b, let rel) = intervals[iv].target {
                        return Double(b) * rel > fastest + 5
                    }
                    return true
                })
                .max(by: { intervals[$0].duration < intervals[$1].duration })
            else { break }
            let iv = intervals[big]
            intervals[big] = WorkoutInterval(id: iv.id, type: iv.type,
                                             duration: iv.duration + 300,
                                             distance: iv.distance,
                                             targetType: iv.targetType, target: iv.target)
            tickedSum += 300
        }
        let newDur = Int64(intervals.reduce(0.0) { $0 + $1.duration }.rounded())
        guard newDur > 0 else { return w }
        let factor = Double(newDur) / Double(w.duration)
        func s(_ v: Int64) -> Int64 { Int64((Double(v) * factor).rounded()) }
        return Workout(id: w.id, title: w.title, type: w.type, subtype: w.subtype,
                       trainingType: w.trainingType, targetType: w.targetType,
                       duration: newDur, distance: w.distance, key: w.key,
                       trainingLoad: s(w.trainingLoad), intervals: intervals,
                       workRestRatio: w.workRestRatio, workDuration: s(w.workDuration),
                       restDuration: s(w.restDuration), workDistance: w.workDistance,
                       restDistance: w.restDistance)
    }

    /// Aerobic continuous runs read as round numbers by nature — quantize their
    /// rendered minutes to a 5-min tick so a plan reads 120/115/110, not the 1-min
    /// jitter that pace-easing + clamp scaling produce. Excludes structured work
    /// (intervals, threshold, race rehearsals) whose minutes are dose-driven.
    private static let fiveMinTickSubtypes: Set<WorkoutSubtype> = [
        .easy, .recovery, .long, .steadyLong, .mediumLong, .progressiveLong, .progression
    ]

    private static func quantizeAerobicDuration(_ w: Workout) -> Workout {
        guard fiveMinTickSubtypes.contains(w.subtype), w.duration > 0 else { return w }
        let tick = 300.0  // 5 min
        let target = Int64((Double(w.duration) / tick).rounded() * tick)
        let ragged = w.intervals.count > 1
            && w.intervals.contains { $0.duration.truncatingRemainder(dividingBy: 60) != 0 }
        guard target > 0, target != w.duration || ragged else { return w }
        let factor = Double(target) / Double(w.duration)
        func s(_ v: Int64) -> Int64 { Int64((Double(v) * factor).rounded()) }
        var intervals = w.intervals.map { iv in
            WorkoutInterval(id: iv.id, type: iv.type, duration: iv.duration * factor,
                            distance: iv.distance, targetType: iv.targetType, target: iv.target)
        }
        // Multi-segment runs (progressions): proportional rescale leaves ragged
        // segments (2:56 WU · 19:31 · 14:38). Round each to whole minutes (5-min
        // tick from 10min up) and give the residual to the LARGEST segment, so
        // segments read as prescriptions and the total keeps its 5-min tick.
        if intervals.count > 1 {
            var rounded = intervals.map { iv -> WorkoutInterval in
                let unit = iv.duration >= 600 ? 300.0 : 60.0
                let d = max(60.0, (iv.duration / unit).rounded() * unit)
                return WorkoutInterval(id: iv.id, type: iv.type, duration: d,
                                       distance: iv.distance, targetType: iv.targetType,
                                       target: iv.target)
            }
            if let big = rounded.indices.max(by: { rounded[$0].duration < rounded[$1].duration }) {
                let others = rounded.indices.filter { $0 != big }
                    .reduce(0.0) { $0 + rounded[$1].duration }
                let residual = Double(target) - others
                if residual >= 300 {
                    let iv = rounded[big]
                    rounded[big] = WorkoutInterval(id: iv.id, type: iv.type, duration: residual,
                                                   distance: iv.distance,
                                                   targetType: iv.targetType, target: iv.target)
                    intervals = rounded
                }
            }
        }
        return Workout(id: w.id, title: w.title, type: w.type, subtype: w.subtype,
                       trainingType: w.trainingType, targetType: w.targetType,
                       duration: target, distance: w.distance, key: w.key,
                       trainingLoad: s(w.trainingLoad), intervals: intervals,
                       workRestRatio: w.workRestRatio, workDuration: s(w.workDuration),
                       restDuration: s(w.restDuration), workDistance: w.workDistance,
                       restDistance: w.restDistance)
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
        isAdvanced: Bool,
        isTaperWeek: Bool,
        progressionFactor: Double,
        floorRampEnd: Double = 0.60
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
        // Non-competitive marathoners peak 28-32km REGARDLESS of level — a
        // marathon build without a near-30km run isn't marathon prep (R8; was
        // cap-only for beginners, which let the peak long run sit at ~17km).
        // Competitive stays higher (Pfitz 18/85 ~35-38km).
        case 42195: (floorKm, capKm) = isCompetitive ? (32, 35) : (28, 33)
        // Half peaks 16-18km for beginners, 16-21km Int/Adv/Cmp (R8; the old
        // 13km beginner floor let a half build finish without a race-relevant run).
        case 21097: (floorKm, capKm) = isCompetitive ? (18, 22)
                                     : isBeginner ? (16, 18) : (16, 21)
        case 10000: (floorKm, capKm) = (0, 16)
        case 5000:  (floorKm, capKm) = (0, 12)
        default:    (floorKm, capKm) = (0, 34)
        }

        // Floor RAMPS with the plan, it is NOT flat across the build. A flat floor
        // pins every build week at the floor distance from week 1, erasing the
        // HR-side long-run build (renders a flat/declining minute curve once easy-
        // easing kicks in). Ramp it 0→full by ~70% in: early base runs keep their
        // (short) generated length so the build shows; only the late-peak long runs
        // are brought up to race-relevant distance for slow runners. Taper: floor 0.
        let floorRamp = min(1.0, progressionFactor / max(0.01, floorRampEnd))
        // No floor in the TAPER. The km-floor exists for aerobic development during the
        // BUILD; in the taper the long run must decline. The pf<0.85 cutoff alone let the
        // FIRST taper week (pf~0.83 in an 18wk/3wk plan) still take the full 30km floor —
        // rendering the plan's LONGEST run ~2 weeks pre-race for slow runners. Gate on the
        // real taper flag. (Deload long-run cuts live in the #171 clamp, applyPaceProgression.)
        // Gate on the real taper flag; the pf backstop sits at 0.90 (peak weeks
        // land at pf≈0.86 and must still take the floor — R9 Int finding: 21K
        // peaks missed 16km by 0.2km because 0.85 cut the floor one week early).
        let effectiveFloor = (progressionFactor < 0.90 && !isTaperWeek) ? floorKm * floorRamp : 0
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
        let effectiveCap = capKm
        let targetKm = min(max(km, effectiveFloor), effectiveCap)
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
            // 245min (~4h) ceiling: high enough that a slow novice can still reach
            // the 28km floor (Galloway runs beginners to 4h+); low enough to stop
            // a pathological pace from rendering a 5h run.
            let begMarathonLRCapMins = 245
            let capFactor = Double(begMarathonLRCapMins * 60) / Double(workout.duration)
            if capFactor > 0 { factor = min(factor, capFactor) }
        }
        // Advanced marathon long run: hold to ~190-195min (3:10-3:15). The 30km
        // km floor re-inflates a slow runner's long run past 210min (pace-relative),
        // a touch too long — clamp the factor so it never exceeds the ceiling.
        if isAdvanced, raceDistanceMeters == 42195 {
            let advMarathonLRCapMins = 195
            let capFactor = Double(advMarathonLRCapMins * 60) / Double(workout.duration)
            if capFactor > 0 { factor = min(factor, capFactor) }
        }
        // #199 tick discipline: floor-lifts tick UP (the window minimum is a
        // guarantee), cap-clamps tick DOWN (the ceiling is a promise) — nearest
        // rounding leaked both ways (34.15km past a 33 cap; 31.7 under a 32 floor).
        let rawSec = Double(workout.duration) * factor
        let ticked = factor > 1
            ? (rawSec / 300).rounded(.up) * 300
            : (rawSec / 300).rounded(.down) * 300
        factor = max(ticked, minSec) / Double(workout.duration)
        var newDurationSec = Int((Double(workout.duration) * factor).rounded())

        func scale(_ v: Int64) -> Int64 { Int64((Double(v) * factor).rounded()) }
        var scaledIntervals: [WorkoutInterval]
        // Rehearsals/fast-finish: the titled WORK dose ("90min @ MP") is the
        // prescription — km-fitting stretches/shrinks only the easy WU/CD
        // segments and delivers the work block exactly as titled (#178).
        // "Work" by PACE INTENT, not interval type: the HM rehearsal catalog
        // types its easy WU/CD segments as Work (Z2-targeted), which made
        // flexSec 0 and silently disabled dose preservation. The dose = the
        // fastest pace group (within 5s/km of the fastest segment).
        func paceOf(_ iv: WorkoutInterval) -> Double {
            if case .paceTarget(let b, let rel) = iv.target { return Double(b) * rel }
            return Double(easyPace)
        }
        let fastest = workout.intervals.map(paceOf).min() ?? 0
        let workSec = workout.intervals.filter { paceOf($0) <= fastest + 5 }
            .reduce(0.0) { $0 + $1.duration }
        let flexSec = Double(workout.duration) - workSec
        let flexTarget = Double(workout.duration) * factor - workSec
        if segmentTickSubtypes.contains(workout.subtype), workSec > 0, flexSec > 0 {
            // The work dose is NEVER shaved to fit the km window — when WU/CD
            // can't absorb the whole compression (fFlex would fall under 0.3),
            // they clamp at 0.3× / 5min each and the run simply comes out a bit
            // longer than the window target. The dose is the prescription.
            let fFlex = max(0.3, flexTarget / flexSec)
            scaledIntervals = workout.intervals.map { iv in
                let isDose = paceOf(iv) <= fastest + 5
                let d = isDose ? iv.duration : max(300.0, iv.duration * fFlex)
                return WorkoutInterval(id: iv.id, type: iv.type, duration: d,
                                       distance: iv.distance, targetType: iv.targetType,
                                       target: iv.target)
            }
            newDurationSec = Int(scaledIntervals.reduce(0.0) { $0 + $1.duration }.rounded())
        } else {
            scaledIntervals = workout.intervals.map { iv in
                WorkoutInterval(
                    id: iv.id,
                    type: iv.type,
                    duration: iv.duration * factor,
                    distance: iv.distance,
                    targetType: iv.targetType,
                    target: iv.target
                )
            }
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

    // LAYER CONTRACT: generation (PlanGeneratorV3) owns STRUCTURE — which workout,
    // which week, deload/taper flags. This render pass owns FIT-TO-RUNNER — zone→pace,
    // km window, deload ~20% long-run dip, taper floor-off, 5-min tick. Duration policy
    // lives HERE only; don't add a second copy generation-side (and vice versa).

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
        isBeginner: Bool = false,
        isAdvanced: Bool = false
    ) -> [WorkoutEvent] {
        let totalDuration = endDate.timeIntervalSince(startDate)
        // "Go slower on long plans": the km floor completes ~6 weeks of runway
        // before race day (≈4 peak weeks + taper) at ANY length, instead of a
        // fixed 60% — a 27w plan otherwise pins six pre-taper weeks at ~28km.
        let planWeeks = max(6.0, totalDuration / (7 * 86400))
        let floorRampEnd = max(0.60, 1.0 - 6.0 / planWeeks)

        guard totalDuration > 0 else { return events }

        // VDOT-progression mode: when projected (race-week) paces are supplied the
        // anchors interpolate current-VDOT (wk 1) → projected-VDOT (race wk) across
        // the plan — the projected fitness gain IS the progression. No end-paces →
        // legacy fixed-anchor behavior.
        let vdotAnchored = racePaceEnd != nil

        var rendered = events.map { event in
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
                isBeginner: isBeginner,
                isAdvanced: isAdvanced,
                isTaperWeek: event.isTaperWeek,  // no km-floor in the taper (see clampLongRunDistance)
                floorRampEnd: floorRampEnd,
                racePaceFinal: racePaceEnd ?? racePace,   // MP/rehearsals at PLANNED race pace
                speedPaceFinal: speedPaceEnd ?? speedPace // VO2/reps at PLANNED 5K
            )

            // Create updated event
            var updatedEvent = event
            updatedEvent.workout = convertedWorkout
            return updatedEvent
        }

        // #171 — Deload long-run clamp. Each BUILD-phase deload week's long run renders
        // at ~0.80x the prior non-deload week's DELIVERED long run: an exact ~20% dip
        // across tiers AND fitness levels, reaching weeks whose HR-side long run didn't
        // dip (cut-vs-trajectory, or a reused MP rehearsal) that a render coefficient
        // can't. Keys on the generator's real deload flag (event.isDeloadWeek).
        // Beginner 42K peak-exposure backstop: at most THREE runs ≥3h,
        // whatever the plan length (30w earns more base, not more peaks —
        // Higdon-Novice-class exposure). The length-aware floor ramp already
        // spreads the build; this trims the odd extra on very long plans by
        // scaling the EARLIEST over-3h runs to 175min (rehearsal titles rebuild
        // correctly under scaling since #178). Runs BEFORE the #171 clamp so
        // deload weeks track the adjusted values.
        if isBeginner, raceDistanceMeters == 42195 {
            let scalable = longRunSubtypes
            var overIdx: [Int] = []
            for (i, e) in rendered.enumerated()
            where longRunSubtypes.contains(e.workout.subtype)
                && !e.isDeloadWeek && !e.isTaperWeek
                && e.workout.duration >= 180 * 60 {
                overIdx.append(i)
            }
            var excess = overIdx.count - 3
            if excess > 0 {
                for i in overIdx where excess > 0 && scalable.contains(rendered[i].workout.subtype) {
                    rendered[i].workout = scaleWorkout(rendered[i].workout, toSeconds: 175 * 60)
                    excess -= 1
                }
            }
        }
        var out = rendered
        // The long run = the LONGEST long-run-subtype workout in a week (a week can also
        // hold a short mid-week run of the same subtype). Group by plan week so the clamp
        // and the prior-week reference both key off the real long run, not the short one.
        var longestIdxByWeek: [Int: Int] = [:]
        for (i, e) in out.enumerated() where longRunSubtypes.contains(e.workout.subtype) {
            if let cur = longestIdxByWeek[e.planWeekIndex], out[cur].workout.duration >= e.workout.duration { continue }
            longestIdxByWeek[e.planWeekIndex] = i
        }
        var prevNonDeloadLongSec: Int64? = nil
        let clampWeeks = longestIdxByWeek.keys.sorted()
        for (wi, wk) in clampWeeks.enumerated() {
            let i = longestIdxByWeek[wk]!
            if out[i].isDeloadWeek {
                if let prev = prevNonDeloadLongSec {
                    // ~20% cut, but never below the 60-min aerobic long-run floor (base-phase
                    // deloads off a short prior run would otherwise dip under it).
                    var target = max(Int64(3600), Int64((Double(prev) * 0.80).rounded()))
                    // Beg 42K: a deload immediately before a HIGHER peak long run
                    // renders a valley-then-spike (200→160→210). Soften to a ~10%
                    // cutback so the run-up to the peak is smooth — Pfitz approaches
                    // the peak long run cleanly, not via a deep cut one week out.
                    // Held strictly under 180min so it never adds a 4th ≥3h beginner
                    // exposure week (the ≤3 backstop, #180).
                    if isBeginner, raceDistanceMeters == 42195, wi + 1 < clampWeeks.count {
                        let nIdx = longestIdxByWeek[clampWeeks[wi + 1]]!
                        if !out[nIdx].isDeloadWeek, !out[nIdx].isTaperWeek,
                           out[nIdx].workout.duration > prev {
                            target = max(target, min(Int64((Double(prev) * 0.90).rounded()), Int64(175 * 60)))
                        }
                    }
                    out[i].workout = scaleWorkout(out[i].workout, toSeconds: target)
                }
            } else {
                prevNonDeloadLongSec = out[i].workout.duration
            }
        }
        // R14 "soften it": a BEGINNER marathon must not repeat the identical
        // floor-pinned peak long run two build weeks running (Slow tier read
        // 3.5h x2 back-to-back). The SECOND consecutive same-length peak LR
        // steps down to 0.90x — an absorption week; the peak itself stays.
        if isBeginner, raceDistanceMeters == 42195 {
            var lrIdxByWeek: [Int: Int] = [:]
            for (i, e) in out.enumerated()
            where longRunSubtypes.contains(e.workout.subtype) && !e.isDeloadWeek && !e.isTaperWeek {
                if let cur = lrIdxByWeek[e.planWeekIndex],
                   out[cur].workout.duration >= e.workout.duration { continue }
                lrIdxByWeek[e.planWeekIndex] = i
            }
            let weeks = lrIdxByWeek.keys.sorted()
            for (a, b) in zip(weeks, weeks.dropFirst()) where b == a + 1 {
                let da = out[lrIdxByWeek[a]!].workout.duration
                let ib = lrIdxByWeek[b]!
                let db = out[ib].workout.duration
                if abs(Double(da - db)) <= 300, Double(da) >= 150 * 60 {
                    let target = Int64((Double(db) * 0.90 / 300.0).rounded() * 300.0)
                    out[ib].workout = scaleWorkout(out[ib].workout, toSeconds: target)
                }
            }
        }

        // #174 — long-run build-chain growth cap: week-over-week, a non-deload
        // long run may exceed the LAST NON-DELOAD long run by at most +25%
        // (or +15min, whichever is larger). Kills the phase-boundary cliffs the
        // 27w Beg 42K showed (70→120min, +71%; slow tier 3h20 arriving in one
        // step) — the excess spreads forward since later weeks' targets stand.
        // Rehearsals/fastFinish keep their titled dose (never capped, #178) but
        // do advance the chain; deload/taper weeks neither cap nor advance it.
        var chainIdxByWeek: [Int: Int] = [:]
        for (i, e) in out.enumerated() where longRunSubtypes.contains(e.workout.subtype) {
            if let cur = chainIdxByWeek[e.planWeekIndex],
               out[cur].workout.duration >= e.workout.duration { continue }
            chainIdxByWeek[e.planWeekIndex] = i
        }
        let growthCappable = longRunSubtypes   // rehearsals too (#178 makes scaling safe)
        var chainPrevSec: Int64? = nil
        for wk in chainIdxByWeek.keys.sorted() {
            let i = chainIdxByWeek[wk]!
            if out[i].isDeloadWeek || out[i].isTaperWeek { continue }
            if let prev = chainPrevSec, growthCappable.contains(out[i].workout.subtype) {
                // Cap WINS over the km floor: the length-aware ramp raises the
                // floor gradually, so a capped week reaches full floor within
                // +25% steps a week later — no cliff, marathon prep intact.
                var cap = max(prev + 900, Int64((Double(prev) * 1.25).rounded()))
                // #199: ceiling — tick nearest unless that crosses it, then drop
                // one tick (blanket tick-down cascaded -5min through the chain).
                let nearestTick = Int64((Double(cap) / 300).rounded()) * 300
                cap = nearestTick <= cap ? nearestTick : nearestTick - 300
                if out[i].workout.duration > cap {
                    out[i].workout = scaleWorkout(out[i].workout, toSeconds: cap)
                }
            }
            chainPrevSec = out[i].workout.duration
        }

        // #197 — Cmp marathon 32km guarantee: a competitive build must deliver
        // >=2 long runs >=32km (the 20-mile-class runs race day is built on).
        // The ramped floor gives slower goals (3:15-3:45) only ONE such week on
        // most lengths — their second candidate lands pre-full-ramp at 27-31km.
        // Lift the LARGEST near-misses (>=28km, non-deload/taper) to 32km,
        // tick-UP, until two qualify. Rehearsal titles rebuild under scaling (#178).
        if isCompetitive, raceDistanceMeters == 42195 {
            func kmOf(_ w: Workout) -> Double {
                w.intervals.reduce(0.0) { acc, iv in
                    if case .paceTarget(let b, let rel) = iv.target, b > 0 {
                        return acc + iv.duration / (Double(b) * rel)
                    }
                    return acc
                }
            }
            var candidates: [(idx: Int, km: Double)] = []
            var qualifying = 0
            for (i, e) in out.enumerated()
            where longRunSubtypes.contains(e.workout.subtype)
                && !e.isDeloadWeek && !e.isTaperWeek {
                let km = kmOf(e.workout)
                if km >= 32.0 { qualifying += 1 }
                else if km >= 28.0 { candidates.append((i, km)) }
            }
            candidates.sort { $0.km > $1.km }
            var c = 0
            while qualifying < 2, c < candidates.count {
                let (i, km) = candidates[c]; c += 1
                let w = out[i].workout
                let targetSec = Double(w.duration) * (32.0 / km)
                let ticked = Int64((targetSec / 300).rounded(.up) * 300)
                out[i].workout = scaleWorkout(w, toSeconds: ticked)
                qualifying += 1
            }
        }

        // R12/R13 — medium-long ceiling (runs AFTER the #171 deload clamp: the
        // clamp can shrink a deload week's long run below an MLR that was valid
        // pre-clamp — R13 Cmp finding, 6/81 Half deload weeks inverted): after every clamp, no week's mediumLong
        // may out-last its long-family run (the km window can shrink the long
        // run AFTER generation swapped them; this pass makes the invariant
        // hold at render, whatever generation did).
                var longestByWeek: [Int: Double] = [:]
        for e in out where e.planWeekIndex >= 0 {
            let sub = e.workout.subtype
            if sub == .long || sub == .steadyLong || sub == .progressiveLong
                || sub == .raceRehearsalM || sub == .raceRehearsalHM
                || sub == .raceRehearsal10K || sub == .fastFinish {
                longestByWeek[e.planWeekIndex] = max(longestByWeek[e.planWeekIndex] ?? 0,
                                                     Double(e.workout.duration))
            }
        }
        out = out.map { e in
            guard e.workout.subtype == .mediumLong || e.workout.subtype == .easy
                    || e.workout.subtype == .recovery,
                  e.planWeekIndex >= 0,
                  let longest = longestByWeek[e.planWeekIndex], longest > 0,
                  Double(e.workout.duration) > longest else { return e }
            var out = e
            let target = Int64((longest / 300.0).rounded(.down) * 300.0)
            out.workout = scaleWorkout(e.workout, toSeconds: max(target, 1800))
            return out
        }


        return out
    }

    /// Scale a workout to an exact target duration (seconds) — intervals + load scaled —
    /// then 5-min-ticking aerobic runs. Used by the deload long-run clamp.
    private static func scaleWorkout(_ w: Workout, toSeconds target: Int64) -> Workout {
        guard w.duration > 0, target > 0, target != w.duration else { return w }
        let factor = Double(target) / Double(w.duration)
        func s(_ v: Int64) -> Int64 { Int64((Double(v) * factor).rounded()) }
        let intervals = w.intervals.map { iv in
            WorkoutInterval(id: iv.id, type: iv.type, duration: iv.duration * factor,
                            distance: iv.distance, targetType: iv.targetType, target: iv.target)
        }
        let scaled = Workout(id: w.id, title: w.title, type: w.type, subtype: w.subtype,
                             trainingType: w.trainingType, targetType: w.targetType,
                             duration: target, distance: w.distance, key: w.key,
                             trainingLoad: s(w.trainingLoad), intervals: intervals,
                             workRestRatio: w.workRestRatio, workDuration: s(w.workDuration),
                             restDuration: s(w.restDuration), workDistance: w.workDistance,
                             restDistance: w.restDistance)
        return quantizeAerobicDuration(scaled)
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
