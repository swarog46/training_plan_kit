//
//  PlanConfiguration.swift
//  RunPlan
//
//  Plan configuration types, enums, and default configurations.
//

import Foundation

// Updated PlanConfiguration struct to support flexible duration

// Enum to categorize workout types for our distribution algorithm
public enum WorkoutCategory {
    case easy
    case interval
    case quality
    case longRun
}

public enum RunnerLevel: String, Codable {
    case beginner
    case intermediate
    case advanced
    case competitive
}

public enum TrainingPhase: String {
    case base
    case speed
    case peak
    case taper
    case race
}

public struct PlanConfiguration {
    // Race details
    public let raceDate: Date
    public let runnerLevel: RunnerLevel
    public let distance: Int64
    // True for the VO2 max fitness block — engine still treats distance
    // as 5000 (5K-style workout selection) but skips race-day creation,
    // and Plan storage uses the .vo2max sentinel for disambiguation.
    public var isVO2Max: Bool = false
    
    // Phase duration ratios (will be used to calculate actual duration)
    public let basePhaseRatio: Double  // e.g., 0.25 = 25% of total training period
    public let speedPhaseRatio: Double // e.g., 0.25 = 25% of total training period
    public let peakPhaseRatio: Double  // e.g., 0.40 = 40% of total training period
    public let taperPhaseRatio: Double // e.g., 0.10 = 10% of total training period
    
    // Minimum weeks for each phase (to ensure proper training stimulus)
    public let minBasePhaseWeeks: Int
    public let minSpeedPhaseWeeks: Int
    public let minPeakPhaseWeeks: Int
    public let minTaperPhaseWeeks: Int
    
    // Default training days (0 = Sunday, 1 = Monday, ..., 6 = Saturday)
    public var trainingDays: [Int]
    public var longestWorkoutDay: Int
    public var useSeparateDayForLongRun: Bool = true

    // Load progression parameters
    public let weeklyLoadIncreasePercent: ClosedRange<Double> // e.g., 7-10%
    public let phaseFinishDeloadPercent: ClosedRange<Double>  // e.g., 15-17%
    public let taperDeloadPercent: Double // e.g., 30%

    // Initial durations in minutes
    public let initialWeeklyDuration: Int // Initial total weekly duration in minutes
    public let initialLongRunDuration: ClosedRange<Int> // Initial long run duration range in minutes

    // Workout type balance (percentages should sum to 100)
    public let easyRunsPercent: Double = 40
    public let intervalRunsPercent: Double = 20
    public let qualityRunsPercent: Double = 10
    public let longRunsPercent: Double = 30

    // Default configuration for a beginner with flexible durations
    public static let beginner42Default = PlanConfiguration(
        raceDate: Date(), // This should be set by the caller
        runnerLevel: .beginner,
        distance: 42195,
        basePhaseRatio: 0.25,
        speedPhaseRatio: 0.25,
        peakPhaseRatio: 0.40,
        taperPhaseRatio: 0.10,
        minBasePhaseWeeks: 4,
        minSpeedPhaseWeeks: 4,
        minPeakPhaseWeeks: 6,
        minTaperPhaseWeeks: 2,
        trainingDays: [1, 3, 5, 6], // Tue, Thu, Sat, Sun
        longestWorkoutDay: 6,
        weeklyLoadIncreasePercent: 18...26,
        phaseFinishDeloadPercent: 14...16,
        taperDeloadPercent: 35,
        // Higdon Novice 1 Marathon: ~145 min/wk in week 1, peaks ~400 min/wk
        // (40 mi @ 10:00/mi). Bumped from 140 → 220 to align average ~250.
        initialWeeklyDuration: 220,
        initialLongRunDuration: 90...110
    )
    
    // Default configuration for a beginner with flexible durations
    public static let beginner5Default = PlanConfiguration(
        raceDate: Date(), // This should be set by the caller
        runnerLevel: .beginner,
        distance: 5000,
        basePhaseRatio: 0.23,
        speedPhaseRatio: 0.35,
        peakPhaseRatio: 0.30,
        taperPhaseRatio: 0.12,
        minBasePhaseWeeks: 2,
        minSpeedPhaseWeeks: 3,
        minPeakPhaseWeeks: 2,
        minTaperPhaseWeeks: 1,
        // Higdon Novice 5K / Couch-to-5K both prescribe 3 days/wk minimum
        // (often with optional cross-training on top). Previous [2, 6]
        // (Wed/Sun) was 2 days, which left adaptation frequency too low
        // for true beginners: each session had to carry too much, and
        // missing one of the two reset the rhythm. Tue/Thu/Sun spaces
        // training across the week and matches Int 5K's pattern for a
        // clean tier ladder.
        trainingDays: [1, 3, 6],
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: false,
        weeklyLoadIncreasePercent: 17...25,
        phaseFinishDeloadPercent: 14...16,
        taperDeloadPercent: 35,
        initialWeeklyDuration: 50,
        initialLongRunDuration: 25...30
    )
    
    // Default configuration for intermediate runner with flexible durations
    public static let intermediate42Default = PlanConfiguration(
        raceDate: Date(),
        runnerLevel: .intermediate,
        distance: 42195,
        basePhaseRatio: 0.15,
        speedPhaseRatio: 0.30,
        peakPhaseRatio: 0.45,
        taperPhaseRatio: 0.10,
        minBasePhaseWeeks: 4,
        minSpeedPhaseWeeks: 4,
        minPeakPhaseWeeks: 6,
        minTaperPhaseWeeks: 2,
        // Higdon Intermediate 1 marathon = 5 days (Mon off, Tue/Wed/Thu, Fri off,
        // Sat pace, Sun long). Beg uses 4 days; the 5th day differentiates Int's
        // higher volume tier from Beg.
        trainingDays: [1, 2, 3, 5, 6], // Tue, Wed, Thu, Sat, Sun
        longestWorkoutDay: 6,
        weeklyLoadIncreasePercent: 17...26,
        phaseFinishDeloadPercent: 15...17,
        taperDeloadPercent: 35,
        initialWeeklyDuration: 320,
        initialLongRunDuration: 95...105
    )
    
    public static let intermediate5Default = PlanConfiguration(
        raceDate: Date(),
        runnerLevel: .intermediate,
        distance: 5000,
        basePhaseRatio: 0.23,
        speedPhaseRatio: 0.35,
        peakPhaseRatio: 0.30,
        taperPhaseRatio: 0.12,
        minBasePhaseWeeks: 2,
        minSpeedPhaseWeeks: 3,
        minPeakPhaseWeeks: 3,
        minTaperPhaseWeeks: 1,
        // Int 5K: 4 days/wk (Tue/Thu/Sat/Sun). Was 3 days (Wed/Fri/Sun);
        // Daniels' Int 5K Phase II prescribes 5-6 days. Going to 4 is a
        // measured move — keeps tier-distinct from Adv 5K (5 days) while
        // matching Pfitz's "5K Intermediate" guidance more honestly.
        trainingDays: [1, 3, 5, 6],
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: false,
        weeklyLoadIncreasePercent: 17...23,
        phaseFinishDeloadPercent: 14...16,
        taperDeloadPercent: 35,
        initialWeeklyDuration: 80,
        initialLongRunDuration: 30...35
    )

    // Default configuration for advanced runner with flexible durations
    public static let advanced42Default = PlanConfiguration(
        raceDate: Date(),
        runnerLevel: .advanced,
        distance: 42195,
        basePhaseRatio: 0.23,
        speedPhaseRatio: 0.27,
        peakPhaseRatio: 0.40,
        taperPhaseRatio: 0.10,
        minBasePhaseWeeks: 4,
        minSpeedPhaseWeeks: 4,
        minPeakPhaseWeeks: 6,
        minTaperPhaseWeeks: 2,
        trainingDays: [1, 3, 4, 5, 6], // Tue, Thu, Fri, Sun
        longestWorkoutDay: 6,
        weeklyLoadIncreasePercent: 15...25,
        phaseFinishDeloadPercent: 15...17,
        taperDeloadPercent: 35,
        // Pfitzinger 18/55: ~33-55 mi/wk = 280-470 min. Bumped 360 → 420 to
        // close the gap against Pfitz Advanced — peak now lands ~390 min/wk,
        // ~83% of 18/55 peak. Still below 18/70 (Cmp territory) which keeps
        // the tier distinction meaningful.
        initialWeeklyDuration: 420,
        initialLongRunDuration: 90...100
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
        weeklyLoadIncreasePercent: 12...20,
        phaseFinishDeloadPercent: 18...20,
        taperDeloadPercent: 35,
        // Pfitz 18/70: starts ~80 km/wk ≈ 470 min, peaks ~110 km/wk ≈ 650 min.
        // Bumped 470 → 560 to compensate for the selector's tendency to
        // underdeliver vs configured target by ~15%. With initial 560,
        // W1 lands at ~470 (Pfitz target) instead of 390 (~77% of target).
        // Average week climbs from 464 to ~550, closing most of the gap.
        initialWeeklyDuration: 560,
        initialLongRunDuration: 110...125
    )
    
    public static let advanced5Default = PlanConfiguration(
        raceDate: Date(),
        runnerLevel: .advanced,
        distance: 5000,
        basePhaseRatio: 0.23,
        speedPhaseRatio: 0.35,
        peakPhaseRatio: 0.30,
        taperPhaseRatio: 0.12,
        minBasePhaseWeeks: 3,
        minSpeedPhaseWeeks: 4,
        minPeakPhaseWeeks: 4,
        minTaperPhaseWeeks: 1,
        // Adv 5K: 5 days/wk (Tue/Wed/Thu/Sat/Sun). Was 4 days (Tue/Wed/Fri/Sun);
        // Daniels' Adv 5K Phase II prescribes 6-7 days. 5 days is the
        // honest middle — keeps tier distinct from Cmp (6 days) and
        // matches Pfitz's 5K Advanced guidance. Tue-Thu block lets Q1/Q2
        // alternate with a recovery easy in between (Daniels pattern).
        trainingDays: [1, 2, 3, 5, 6],
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: false,
        weeklyLoadIncreasePercent: 15...25,
        phaseFinishDeloadPercent: 15...17,
        taperDeloadPercent: 35,
        initialWeeklyDuration: 150,
        initialLongRunDuration: 45...50
    )

    // 10K configurations
    public static let beginner10Default = PlanConfiguration(
        raceDate: Date(),
        runnerLevel: .beginner,
        distance: 10000,
        basePhaseRatio: 0.25,
        speedPhaseRatio: 0.35,
        peakPhaseRatio: 0.30,
        taperPhaseRatio: 0.10,
        minBasePhaseWeeks: 2,
        minSpeedPhaseWeeks: 3,
        minPeakPhaseWeeks: 2,
        minTaperPhaseWeeks: 1,
        trainingDays: [1, 3, 6], // Tue, Thu, Sun - 3 workouts/week (Higdon Novice 10K = 3 days)
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: true,
        weeklyLoadIncreasePercent: 18...26,
        phaseFinishDeloadPercent: 14...16,
        taperDeloadPercent: 35,
        initialWeeklyDuration: 90,
        initialLongRunDuration: 30...40
    )

    public static let intermediate10Default = PlanConfiguration(
        raceDate: Date(),
        runnerLevel: .intermediate,
        distance: 10000,
        basePhaseRatio: 0.20,
        speedPhaseRatio: 0.40,
        peakPhaseRatio: 0.30,
        taperPhaseRatio: 0.10,
        minBasePhaseWeeks: 2,
        minSpeedPhaseWeeks: 3,
        minPeakPhaseWeeks: 2,
        minTaperPhaseWeeks: 1,
        // Int 10K: 5 days/wk (Tue/Wed/Thu/Sat/Sun). Was 4 days (Tue/Thu/Sat/Sun);
        // Pfitz Int 10K prescribes 5-6 days. Adding a Wednesday recovery
        // easy fills the gap between Tuesday Q1 and Thursday Q2 — Daniels'
        // standard pattern.
        trainingDays: [1, 2, 3, 5, 6],
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: true,
        weeklyLoadIncreasePercent: 17...26,
        phaseFinishDeloadPercent: 15...17,
        taperDeloadPercent: 35,
        // Bumped 140 → 170 so 10K plan visibly out-volumes 5K plan (matches
        // user mental model "longer race = more training"). Daniels' Phase II
        // Int 10K is 50-65 km/wk — bump lands ~58 km vs 5K's 48 km, clean
        // step up.
        initialWeeklyDuration: 170,
        initialLongRunDuration: 45...55
    )

    public static let advanced10Default = PlanConfiguration(
        raceDate: Date(),
        runnerLevel: .advanced,
        distance: 10000,
        basePhaseRatio: 0.25,
        speedPhaseRatio: 0.35,
        peakPhaseRatio: 0.30,
        taperPhaseRatio: 0.10,
        minBasePhaseWeeks: 2,
        minSpeedPhaseWeeks: 3,
        minPeakPhaseWeeks: 3,
        minTaperPhaseWeeks: 1,
        // Adv 10K: 5 days/wk (Tue/Wed/Thu/Sat/Sun). Was 4 days; Daniels'
        // Adv 10K prescribes 6 days. Going to 5 keeps tier distinct from
        // Cmp marathon (6 days) while letting the runner do Q1/easy/Q2/
        // easy/long — Daniels' standard.
        trainingDays: [1, 2, 3, 5, 6],
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: true,
        weeklyLoadIncreasePercent: 15...25,
        phaseFinishDeloadPercent: 15...17,
        taperDeloadPercent: 35,
        // Bumped 180 → 220 + bumped LR duration 70-75 → 80-90 so 10K plan
        // visibly out-volumes 5K plan. Daniels Phase II Adv 10K is 70-90
        // km/wk; combined with baseLoad ×1.15 × 1.20 (5K/10K + 10K-specific
        // bumps), bump lands Adv 10K at ~90 km vs Adv 5K's 85 km — clean
        // step up matching user mental model "longer race = more training".
        initialWeeklyDuration: 220,
        initialLongRunDuration: 80...90
    )

    // 21K (Half Marathon) configurations
    public static let beginner21Default = PlanConfiguration(
        raceDate: Date(),
        runnerLevel: .beginner,
        distance: 21097,
        // Beginner half-marathoners need MORE base than intermediate/advanced
        // (cardio least adapted, highest injury risk). Inverted previously
        // (0.08 / 1 week min) — likely a transcription error from 5K config.
        basePhaseRatio: 0.30,
        speedPhaseRatio: 0.30,
        peakPhaseRatio: 0.30,
        taperPhaseRatio: 0.10,
        minBasePhaseWeeks: 4,
        minSpeedPhaseWeeks: 4,
        minPeakPhaseWeeks: 4,
        minTaperPhaseWeeks: 2,
        trainingDays: [1, 3, 5, 6], // Tue, Thu, Sat, Sun - 4 days (Higdon Novice 1 Half)
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: true,
        weeklyLoadIncreasePercent: 18...26,
        phaseFinishDeloadPercent: 14...16,
        taperDeloadPercent: 35,
        initialWeeklyDuration: 95,
        initialLongRunDuration: 35...40
    )

    public static let intermediate21Default = PlanConfiguration(
        raceDate: Date(),
        runnerLevel: .intermediate,
        distance: 21097,
        basePhaseRatio: 0.25,
        speedPhaseRatio: 0.35,
        peakPhaseRatio: 0.30,
        taperPhaseRatio: 0.10,
        minBasePhaseWeeks: 4,
        minSpeedPhaseWeeks: 3,
        minPeakPhaseWeeks: 4,
        minTaperPhaseWeeks: 2,
        // Higdon Intermediate 1 Half = 5 days. The 5th day differentiates Int from
        // Beg's 4-day plan (otherwise volume gap collapses to ~7%).
        trainingDays: [1, 2, 3, 5, 6], // Tue, Wed, Thu, Sat, Sun - 5 workouts/week
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: true,
        weeklyLoadIncreasePercent: 17...26,
        phaseFinishDeloadPercent: 15...17,
        taperDeloadPercent: 35,
        initialWeeklyDuration: 200,
        initialLongRunDuration: 60...70
    )

    public static let advanced21Default = PlanConfiguration(
        raceDate: Date(),
        runnerLevel: .advanced,
        distance: 21097,
        basePhaseRatio: 0.25,
        speedPhaseRatio: 0.35,
        peakPhaseRatio: 0.30,
        taperPhaseRatio: 0.10,
        minBasePhaseWeeks: 3,
        minSpeedPhaseWeeks: 4,
        minPeakPhaseWeeks: 4,
        minTaperPhaseWeeks: 2,
        trainingDays: [1, 3, 4, 5, 6], // Tue, Wed, Thu, Sat, Sun - 5 workouts/week
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: true,
        weeklyLoadIncreasePercent: 15...25,
        phaseFinishDeloadPercent: 15...17,
        taperDeloadPercent: 35,
        initialWeeklyDuration: 200,
        initialLongRunDuration: 80...85
    )

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
        weeklyLoadIncreasePercent: 13...22,
        phaseFinishDeloadPercent: 18...20,
        taperDeloadPercent: 30,
        // Same selector-undershoot compensation as competitive42 (~15%).
        // 320 → 380 lands W1 at ~320 (target) and average ~430 → ~500.
        initialWeeklyDuration: 380,
        initialLongRunDuration: 80...95
    )

    // MARK: - Maintenance Plans
    // Goal of maintenance: "couple of workouts a week, no pressure, but
    // fitness gradually increases over the cycle". With only 2 sessions/wk
    // the selector couldn't absorb the phaseBoost duration growth — vol
    // stayed flat ~65min/wk across all 12 weeks. Bumped to 3 days/wk
    // (Tue/Thu/Sun) matching maintenanceIntermediate's cadence, which is
    // still "a couple" for a beginner runner and lets the phaseBoost
    // actually deliver a 50→90 min/wk progression.
    public static let maintenanceBeginner = PlanConfiguration(
        raceDate: Date().addingTimeInterval(60 * 24 * 3600), // 60 days default
        runnerLevel: .beginner,
        distance: 0, // No race target for maintenance
        basePhaseRatio: 0.4,
        speedPhaseRatio: 0.5, // Repurposed as "maintenance" phase
        peakPhaseRatio: 0.0,
        taperPhaseRatio: 0.1, // Repurposed as "recovery" week
        minBasePhaseWeeks: 2,
        minSpeedPhaseWeeks: 3,
        minPeakPhaseWeeks: 0,
        minTaperPhaseWeeks: 1,
        trainingDays: [1, 3, 6], // 3 days/week: Tue, Thu, Sun
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: true,
        weeklyLoadIncreasePercent: 5...10, // SLOW progression
        phaseFinishDeloadPercent: 15...20,
        taperDeloadPercent: 25,
        initialWeeklyDuration: 60,
        initialLongRunDuration: 25...30
    )

    public static let maintenanceIntermediate = PlanConfiguration(
        raceDate: Date().addingTimeInterval(60 * 24 * 3600),
        runnerLevel: .intermediate,
        distance: 0,
        basePhaseRatio: 0.4,
        speedPhaseRatio: 0.5,
        peakPhaseRatio: 0.0,
        taperPhaseRatio: 0.1,
        minBasePhaseWeeks: 2,
        minSpeedPhaseWeeks: 3,
        minPeakPhaseWeeks: 0,
        minTaperPhaseWeeks: 1,
        trainingDays: [1, 3, 6], // 3 days/week: Tue, Thu, Sun
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: true,
        weeklyLoadIncreasePercent: 6...10,
        phaseFinishDeloadPercent: 15...20,
        taperDeloadPercent: 25,
        initialWeeklyDuration: 120,
        initialLongRunDuration: 45...50
    )

    public static let maintenanceAdvanced = PlanConfiguration(
        raceDate: Date().addingTimeInterval(60 * 24 * 3600),
        runnerLevel: .advanced,
        distance: 0,
        basePhaseRatio: 0.4,
        speedPhaseRatio: 0.5,
        peakPhaseRatio: 0.0,
        taperPhaseRatio: 0.1,
        minBasePhaseWeeks: 3,
        minSpeedPhaseWeeks: 4,
        minPeakPhaseWeeks: 0,
        minTaperPhaseWeeks: 1,
        trainingDays: [1, 3, 4, 6], // 4 days/week: Tue, Thu, Fri, Sun
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: true,
        weeklyLoadIncreasePercent: 5...8,
        phaseFinishDeloadPercent: 15...20,
        taperDeloadPercent: 25,
        initialWeeklyDuration: 200,
        initialLongRunDuration: 75...80
    )

    // MARK: - VO2 Max Plans
    //
    // 8-week fitness block routed internally as a 5K plan: the 5K workout
    // selection already prioritizes VO2 intervals + tempo + threshold +
    // easy + short long runs, which matches the VO2-max focus. The only
    // differences from a 5K race plan:
    //   1. No race-day workout at the end (gated by isVO2Max).
    //   2. Length fixed at 8 weeks (min == max in PlanCategory).
    //
    // Configs delegate to beginner5Default / intermediate5Default /
    // advanced5Default with isVO2Max=true. Defined as functions (not
    // statics) because mutating a `var` field on a `let` static requires
    // building a copy.

    public static var vo2maxBeginner: PlanConfiguration {
        var c = PlanConfiguration.beginner5Default
        c.isVO2Max = true
        return c
    }

    public static var vo2maxIntermediate: PlanConfiguration {
        var c = PlanConfiguration.intermediate5Default
        c.isVO2Max = true
        return c
    }

    public static var vo2maxAdvanced: PlanConfiguration {
        var c = PlanConfiguration.advanced5Default
        c.isVO2Max = true
        return c
    }

    // Function to calculate phase durations based on total available weeks
    public func calculatePhaseDurations(totalWeeks: Int) -> (base: Int, speed: Int, peak: Int, taper: Int) {
        // Calculate ideal durations based on ratios
        let idealBaseWeeks = Int(Double(totalWeeks) * basePhaseRatio)
        let idealSpeedWeeks = Int(Double(totalWeeks) * speedPhaseRatio)
        let idealPeakWeeks = Int(Double(totalWeeks) * peakPhaseRatio)
        let idealTaperWeeks = Int(Double(totalWeeks) * taperPhaseRatio)
        
        // Ensure minimum durations are met
        var baseWeeks = max(idealBaseWeeks, minBasePhaseWeeks)
        var speedWeeks = max(idealSpeedWeeks, minSpeedPhaseWeeks)
        var peakWeeks = max(idealPeakWeeks, minPeakPhaseWeeks)
        var taperWeeks = max(idealTaperWeeks, minTaperPhaseWeeks)
        
        // Calculate total of all phases after applying minimums
        let totalPlannedWeeks = baseWeeks + speedWeeks + peakWeeks + taperWeeks
        
        // If total planned weeks exceeds available weeks, we need to adjust
        if totalPlannedWeeks > totalWeeks {
            // Calculate how many weeks we need to trim
            let excessWeeks = totalPlannedWeeks - totalWeeks
            
            // Trim weeks based on priority (taper is least flexible, then peak, then speed, then base)
            // We'll try to maintain the taper duration as it's critical for race performance
            let weeksToTrimFromBase = min(max(0, baseWeeks - minBasePhaseWeeks), excessWeeks)
            baseWeeks -= weeksToTrimFromBase
            
            let remainingExcess = excessWeeks - weeksToTrimFromBase
            if remainingExcess > 0 {
                let weeksToTrimFromSpeed = min(max(0, speedWeeks - minSpeedPhaseWeeks), remainingExcess)
                speedWeeks -= weeksToTrimFromSpeed
                
                let stillRemainingExcess = remainingExcess - weeksToTrimFromSpeed
                if stillRemainingExcess > 0 {
                    let weeksToTrimFromPeak = min(max(0, peakWeeks - minPeakPhaseWeeks), stillRemainingExcess)
                    peakWeeks -= weeksToTrimFromPeak
                    
                    let finalRemainingExcess = stillRemainingExcess - weeksToTrimFromPeak
                    if finalRemainingExcess > 0 {
                        // Last resort: trim from taper (try to keep at least 1 week)
                        taperWeeks = max(1, taperWeeks - finalRemainingExcess)
                    }
                }
            }
        } else if totalPlannedWeeks < totalWeeks {
            // If we have extra weeks, distribute them proportionally
            let extraWeeks = totalWeeks - totalPlannedWeeks
            
            // Distribute extra weeks according to ratios
            let extraBaseWeeks = Int(Double(extraWeeks) * basePhaseRatio)
            let extraSpeedWeeks = Int(Double(extraWeeks) * speedPhaseRatio)
            let extraPeakWeeks = Int(Double(extraWeeks) * peakPhaseRatio)
            let extraTaperWeeks = extraWeeks - extraBaseWeeks - extraSpeedWeeks - extraPeakWeeks
            
            baseWeeks += extraBaseWeeks
            speedWeeks += extraSpeedWeeks
            peakWeeks += extraPeakWeeks
            taperWeeks += extraTaperWeeks
        }
        
        return (baseWeeks, speedWeeks, peakWeeks, taperWeeks)
    }

    // Calculate the recommended minimum weeks for this plan configuration
    public func recommendedWeeks() -> Int {
        return minBasePhaseWeeks + minSpeedPhaseWeeks + minPeakPhaseWeeks + minTaperPhaseWeeks
    }
}

// MARK: - Accessible ("real life") tier
// Lighter, more sustainable variants of the textbook plans above:
// fewer days/week, gentler beginner phase mix. SAME periodization
// structure (base->speed->peak->taper, deloads, taper). The textbook
// configs above are UNCHANGED; these are an additive, opt-in tier.
// 3 cells (Adv 21K, Beg 42K, Adv 42K) are unchanged from textbook and
// alias it directly. See articles/ACCESSIBLE_TIER_NOTES.md.
extension PlanConfiguration {
    public static let accessibleBeginner5Default = PlanConfiguration(
        raceDate: Date(), // This should be set by the caller
        runnerLevel: .beginner,
        distance: 5000,
        basePhaseRatio: 0.50,
        speedPhaseRatio: 0.18,
        peakPhaseRatio: 0.20,
        taperPhaseRatio: 0.12,
        minBasePhaseWeeks: 4,
        minSpeedPhaseWeeks: 2,
        minPeakPhaseWeeks: 1,
        minTaperPhaseWeeks: 1,
        // Higdon Novice 5K / Couch-to-5K both prescribe 3 days/wk minimum
        // (often with optional cross-training on top). Previous [2, 6]
        // (Wed/Sun) was 2 days, which left adaptation frequency too low
        // for true beginners: each session had to carry too much, and
        // missing one of the two reset the rhythm. Tue/Thu/Sun spaces
        // training across the week and matches Int 5K's pattern for a
        // clean tier ladder.
        trainingDays: [2, 6], // accessible tier
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: false,
        weeklyLoadIncreasePercent: 17...25,
        phaseFinishDeloadPercent: 14...16,
        taperDeloadPercent: 35,
        initialWeeklyDuration: 50,
        initialLongRunDuration: 25...30
    )

    public static let accessibleIntermediate5Default = PlanConfiguration(
        raceDate: Date(),
        runnerLevel: .intermediate,
        distance: 5000,
        basePhaseRatio: 0.23,
        speedPhaseRatio: 0.35,
        peakPhaseRatio: 0.30,
        taperPhaseRatio: 0.12,
        minBasePhaseWeeks: 2,
        minSpeedPhaseWeeks: 3,
        minPeakPhaseWeeks: 3,
        minTaperPhaseWeeks: 1,
        // Int 5K: 4 days/wk (Tue/Thu/Sat/Sun). Was 3 days (Wed/Fri/Sun);
        // Daniels' Int 5K Phase II prescribes 5-6 days. Going to 4 is a
        // measured move — keeps tier-distinct from Adv 5K (5 days) while
        // matching Pfitz's "5K Intermediate" guidance more honestly.
        trainingDays: [1, 3, 6], // accessible tier
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: false,
        weeklyLoadIncreasePercent: 17...23,
        phaseFinishDeloadPercent: 14...16,
        taperDeloadPercent: 35,
        initialWeeklyDuration: 70,
        initialLongRunDuration: 30...35
    )

    public static let accessibleAdvanced5Default = PlanConfiguration(
        raceDate: Date(),
        runnerLevel: .advanced,
        distance: 5000,
        basePhaseRatio: 0.23,
        speedPhaseRatio: 0.35,
        peakPhaseRatio: 0.30,
        taperPhaseRatio: 0.12,
        minBasePhaseWeeks: 3,
        minSpeedPhaseWeeks: 4,
        minPeakPhaseWeeks: 4,
        minTaperPhaseWeeks: 1,
        // Adv 5K: 5 days/wk (Tue/Wed/Thu/Sat/Sun). Was 4 days (Tue/Wed/Fri/Sun);
        // Daniels' Adv 5K Phase II prescribes 6-7 days. 5 days is the
        // honest middle — keeps tier distinct from Cmp (6 days) and
        // matches Pfitz's 5K Advanced guidance. Tue-Thu block lets Q1/Q2
        // alternate with a recovery easy in between (Daniels pattern).
        trainingDays: [1, 3, 5, 6], // accessible tier
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: false,
        weeklyLoadIncreasePercent: 15...25,
        phaseFinishDeloadPercent: 15...17,
        taperDeloadPercent: 35,
        initialWeeklyDuration: 125,
        initialLongRunDuration: 45...50
    )

    public static let accessibleBeginner10Default = PlanConfiguration(
        raceDate: Date(),
        runnerLevel: .beginner,
        distance: 10000,
        basePhaseRatio: 0.55,
        speedPhaseRatio: 0.15,
        peakPhaseRatio: 0.20,
        taperPhaseRatio: 0.10,
        minBasePhaseWeeks: 4,
        minSpeedPhaseWeeks: 2,
        minPeakPhaseWeeks: 1,
        minTaperPhaseWeeks: 1,
        trainingDays: [2, 6], // accessible tier
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: true,
        weeklyLoadIncreasePercent: 18...26,
        phaseFinishDeloadPercent: 14...16,
        taperDeloadPercent: 35,
        initialWeeklyDuration: 70,
        initialLongRunDuration: 30...40
    )

    public static let accessibleIntermediate10Default = PlanConfiguration(
        raceDate: Date(),
        runnerLevel: .intermediate,
        distance: 10000,
        basePhaseRatio: 0.20,
        speedPhaseRatio: 0.40,
        peakPhaseRatio: 0.30,
        taperPhaseRatio: 0.10,
        minBasePhaseWeeks: 2,
        minSpeedPhaseWeeks: 3,
        minPeakPhaseWeeks: 2,
        minTaperPhaseWeeks: 1,
        // Int 10K: 5 days/wk (Tue/Wed/Thu/Sat/Sun). Was 4 days (Tue/Thu/Sat/Sun);
        // Pfitz Int 10K prescribes 5-6 days. Adding a Wednesday recovery
        // easy fills the gap between Tuesday Q1 and Thursday Q2 — Daniels'
        // standard pattern.
        trainingDays: [1, 3, 6], // accessible tier
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: true,
        weeklyLoadIncreasePercent: 17...26,
        phaseFinishDeloadPercent: 15...17,
        taperDeloadPercent: 35,
        // Bumped 140 → 170 so 10K plan visibly out-volumes 5K plan (matches
        // user mental model "longer race = more training"). Daniels' Phase II
        // Int 10K is 50-65 km/wk — bump lands ~58 km vs 5K's 48 km, clean
        // step up.
        initialWeeklyDuration: 130,
        initialLongRunDuration: 45...55
    )

    public static let accessibleAdvanced10Default = PlanConfiguration(
        raceDate: Date(),
        runnerLevel: .advanced,
        distance: 10000,
        basePhaseRatio: 0.25,
        speedPhaseRatio: 0.35,
        peakPhaseRatio: 0.30,
        taperPhaseRatio: 0.10,
        minBasePhaseWeeks: 2,
        minSpeedPhaseWeeks: 3,
        minPeakPhaseWeeks: 3,
        minTaperPhaseWeeks: 1,
        // Adv 10K: 5 days/wk (Tue/Wed/Thu/Sat/Sun). Was 4 days; Daniels'
        // Adv 10K prescribes 6 days. Going to 5 keeps tier distinct from
        // Cmp marathon (6 days) while letting the runner do Q1/easy/Q2/
        // easy/long — Daniels' standard.
        trainingDays: [1, 3, 5, 6], // accessible tier
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: true,
        weeklyLoadIncreasePercent: 15...25,
        phaseFinishDeloadPercent: 15...17,
        taperDeloadPercent: 35,
        // Bumped 180 → 220 + bumped LR duration 70-75 → 80-90 so 10K plan
        // visibly out-volumes 5K plan. Daniels Phase II Adv 10K is 70-90
        // km/wk; combined with baseLoad ×1.15 × 1.20 (5K/10K + 10K-specific
        // bumps), bump lands Adv 10K at ~90 km vs Adv 5K's 85 km — clean
        // step up matching user mental model "longer race = more training".
        initialWeeklyDuration: 185,
        initialLongRunDuration: 80...90
    )

    public static let accessibleBeginner21Default = PlanConfiguration(
        raceDate: Date(),
        runnerLevel: .beginner,
        distance: 21097,
        // Beginner half-marathoners need MORE base than intermediate/advanced
        // (cardio least adapted, highest injury risk). Inverted previously
        // (0.08 / 1 week min) — likely a transcription error from 5K config.
        basePhaseRatio: 0.30,
        speedPhaseRatio: 0.30,
        peakPhaseRatio: 0.30,
        taperPhaseRatio: 0.10,
        minBasePhaseWeeks: 4,
        minSpeedPhaseWeeks: 4,
        minPeakPhaseWeeks: 4,
        minTaperPhaseWeeks: 2,
        trainingDays: [1, 3, 6], // accessible tier
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: true,
        weeklyLoadIncreasePercent: 18...26,
        phaseFinishDeloadPercent: 14...16,
        taperDeloadPercent: 35,
        initialWeeklyDuration: 95,
        initialLongRunDuration: 35...40
    )

    public static let accessibleIntermediate21Default = PlanConfiguration(
        raceDate: Date(),
        runnerLevel: .intermediate,
        distance: 21097,
        basePhaseRatio: 0.25,
        speedPhaseRatio: 0.35,
        peakPhaseRatio: 0.30,
        taperPhaseRatio: 0.10,
        minBasePhaseWeeks: 4,
        minSpeedPhaseWeeks: 3,
        minPeakPhaseWeeks: 4,
        minTaperPhaseWeeks: 2,
        // Higdon Intermediate 1 Half = 5 days. The 5th day differentiates Int from
        // Beg's 4-day plan (otherwise volume gap collapses to ~7%).
        trainingDays: [1, 3, 5, 6], // accessible tier
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: true,
        weeklyLoadIncreasePercent: 17...26,
        phaseFinishDeloadPercent: 15...17,
        taperDeloadPercent: 35,
        initialWeeklyDuration: 165,
        initialLongRunDuration: 60...70
    )

    /// Accessible advanced21Default — identical to the textbook plan.
    public static let accessibleAdvanced21Default = advanced21Default

    /// Accessible beginner42Default — identical to the textbook plan.
    public static let accessibleBeginner42Default = beginner42Default

    public static let accessibleIntermediate42Default = PlanConfiguration(
        raceDate: Date(),
        runnerLevel: .intermediate,
        distance: 42195,
        basePhaseRatio: 0.15,
        speedPhaseRatio: 0.30,
        peakPhaseRatio: 0.45,
        taperPhaseRatio: 0.10,
        minBasePhaseWeeks: 4,
        minSpeedPhaseWeeks: 4,
        minPeakPhaseWeeks: 6,
        minTaperPhaseWeeks: 2,
        // Higdon Intermediate 1 marathon = 5 days (Mon off, Tue/Wed/Thu, Fri off,
        // Sat pace, Sun long). Beg uses 4 days; the 5th day differentiates Int's
        // higher volume tier from Beg.
        trainingDays: [1, 3, 5, 6], // accessible tier
        longestWorkoutDay: 6,
        weeklyLoadIncreasePercent: 17...26,
        phaseFinishDeloadPercent: 15...17,
        taperDeloadPercent: 35,
        initialWeeklyDuration: 270,
        initialLongRunDuration: 95...105
    )

    /// Accessible advanced42Default — identical to the textbook plan.
    public static let accessibleAdvanced42Default = advanced42Default

}

// MARK: - Tier switch (accessible vs textbook)

extension PlanConfiguration {
    /// Master switch: which non-competitive plan set the app generates.
    ///
    /// `true`  → the **accessible** tier (fewer days/week, gentler beginners,
    ///           ~72-90% of textbook load) — what RunPlan ships today.
    /// `false` → the **textbook** tier (Higdon / Pfitzinger / Daniels
    ///           day-counts and volumes).
    ///
    /// Flip this one value to switch the whole app. Both of the app's config
    /// selectors resolve through `raceConfig(level:distanceMeters:)` below, so
    /// they can never drift apart. Competitive (Pro), maintenance, and VO2
    /// plans are unaffected — they're routed to their own configs by the
    /// caller before reaching here.
    public static var shipAccessibleTier = true

    /// Resolve the non-competitive (5K / 10K / 21K / 42K) config for a runner
    /// level + race distance, honoring `shipAccessibleTier`. Single source of
    /// truth for non-competitive plan selection.
    public static func raceConfig(level: RunnerLevel, distanceMeters: Int) -> PlanConfiguration {
        let acc = shipAccessibleTier
        switch distanceMeters {
        case 0..<7500: // 5K
            switch level {
            case .beginner:     return acc ? accessibleBeginner5Default     : beginner5Default
            case .intermediate: return acc ? accessibleIntermediate5Default : intermediate5Default
            default:            return acc ? accessibleAdvanced5Default      : advanced5Default
            }
        case 7500..<15000: // 10K
            switch level {
            case .beginner:     return acc ? accessibleBeginner10Default     : beginner10Default
            case .intermediate: return acc ? accessibleIntermediate10Default : intermediate10Default
            default:            return acc ? accessibleAdvanced10Default      : advanced10Default
            }
        case 15000..<30000: // 21K
            switch level {
            case .beginner:     return acc ? accessibleBeginner21Default     : beginner21Default
            case .intermediate: return acc ? accessibleIntermediate21Default : intermediate21Default
            default:            return acc ? accessibleAdvanced21Default      : advanced21Default
            }
        default: // Marathon
            switch level {
            case .beginner:     return acc ? accessibleBeginner42Default     : beginner42Default
            case .intermediate: return acc ? accessibleIntermediate42Default : intermediate42Default
            default:            return acc ? accessibleAdvanced42Default      : advanced42Default
            }
        }
    }
}

extension DifficultyLevel {
    /// Map the stored difficulty level to the engine's `RunnerLevel`.
    public var toRunnerLevel: RunnerLevel {
        switch self {
        case .beginner:     return .beginner
        case .intermediate: return .intermediate
        case .advanced:     return .advanced
        case .competitive:  return .competitive
        }
    }
}
