//
//  PlanConfiguration+Competitive.swift
//  RunPlan
//
//  Competitive-tier plan configs. Each plan fully declares its own shape — days, load
//  (VolumeProfile), long-run cap + ramp — so the shared engine never branches on
//  which plan it is. Day counts are LOCKED (see PlanConfiguration.swift matrix).
//

import Foundation

extension PlanConfiguration {

    // 21K Competitive — sub-1:30 target. 6 days/wk, longer LRs
    // (80-95min initial, peak ~120-135min ≈ 25-28km), more 5K-pace
    // intervals for speed reserve since HMP is close to threshold.
    // Sub-1:30 half plans mirror competitive42 on taper logic — a 2-week
    // taper after sub-1:30 peak volume (60-75 km/wk) leaves residual
    // fatigue. Pfitz/Daniels advanced half plans use 3-week tapers for
    // 16-18w cycles. minTaperPhaseWeeks 3 ≈ a real 3-week ramp-down.
    public static let competitive21Default = PlanConfiguration(
        raceDate: Date(),
        runnerLevel: .competitive,
        distance: 21097,
        basePhaseRatio: 0.22,
        speedPhaseRatio: 0.32,
        peakPhaseRatio: 0.31,
        taperPhaseRatio: 0.15,
        // Min phase weeks sum to 12 (2+3+4+3) so a sub-1:35 half runner
        // can pick a 12-week plan and still keep a real PEAK > TAPER curve.
        // Build-band runners get the longer recommended length via the
        // gate check.
        minBasePhaseWeeks: 2,
        minSpeedPhaseWeeks: 3,
        minPeakPhaseWeeks: 4,
        minTaperPhaseWeeks: 3,
        trainingDays: [1, 2, 3, 4, 5, 6], // 6 days/wk (Mon rest)
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: true,
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 13...22,
            phaseFinishDeloadPercent: 18...20,
            taperDeloadPercent: 30,
            // Over-set ~15% to compensate for the selector's volume undershoot.
            initialWeeklyDuration: 285, // 380×0.75 (sub-1:30 half trim baked in)
            initialLongRunDuration: 80...95,
            maxLongRunMinutes: 115,
            longRunProgression: (base: 85, speed: 125, peak: 145, taper: 90),
            baseLoad: 15000, loadScaleBaselineWeeks: 18
        )
    )

    // 42K Competitive — sub-3h target. Pfitzinger 18/70 inspired:
    // 6 days/wk (Mon rest), heavy peak phase for MP-specific volume,
    // longer LRs (110-125min initial, scaling to 150-180min in peak).
    // Gentler weekly ramp because absolute volume is higher.
    // 3-week taper per Pfitz/Daniels/Higdon Advanced — undertapering a
    // sub-3h athlete after 60-90 km/wk peak leaves lingering fatigue
    // that wrecks race day. taperPhaseRatio 0.15 ≈ 3 weeks of an 18w plan.
    public static let competitive42Default = PlanConfiguration(
        raceDate: Date(),
        runnerLevel: .competitive,
        distance: 42195,
        basePhaseRatio: 0.20,
        speedPhaseRatio: 0.25,
        peakPhaseRatio: 0.40,
        taperPhaseRatio: 0.15,
        // Min phase weeks sum to 12 (2+3+4+3) so a sub-3:20 marathon
        // runner can pick a 12-week plan and still keep a real PEAK >
        // TAPER curve. 3-week taper preserved — race-readiness sharpening
        // matters even for the compressed plan. Build-band runners still
        // get the longer recommended length via the gate check.
        minBasePhaseWeeks: 2,
        minSpeedPhaseWeeks: 3,
        minPeakPhaseWeeks: 4,
        minTaperPhaseWeeks: 3,
        trainingDays: [1, 2, 3, 4, 5, 6], // Tue–Sun, 6 days/wk (Mon rest)
        longestWorkoutDay: 6,
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 12...20,
            phaseFinishDeloadPercent: 18...20,
            taperDeloadPercent: 35,
            // Pfitz 18/70 target ~470min W1. Over-set to 560 to compensate for the
            // selector's ~15% volume undershoot.
            initialWeeklyDuration: 560,
            initialLongRunDuration: 110...125,
            maxLongRunMinutes: 220,
            longRunProgression: (base: 100, speed: 160, peak: 210, taper: 110),
            baseLoad: 20000, loadScaleBaselineWeeks: 18
        )
    )
}


/// Competitive-tier behavioural profile. See PlanProfile.
public struct CompetitiveProfile: PlanProfile {
    public init() {}
    public var recoveryWeekLoadMultiplier: Double { 0.75 }  // cuts recovery weeks harder
    public var longRunSnapLoadFraction: Double { 0.50 }
}
