//
//  PlanConfiguration+Accessible.swift
//  RunPlan
//
//  Accessible-tier plan configs (own shape: days + VolumeProfile incl. long-run cap/ramp).
//  Aliases reuse a textbook twin where no lighter variant is warranted.
//

import Foundation

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
        // 2 days/wk — the locked beginner-5K day-count (below-textbook
        // frequency is intentional; accessible tier matches standard Beg 5K here).
        trainingDays: [2, 6], // accessible tier
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: false,
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 17...25,
            phaseFinishDeloadPercent: 14...16,
            taperDeloadPercent: 35,
            initialWeeklyDuration: 50,
            initialLongRunDuration: 25...30,
            maxLongRunMinutes: 75,
            longRunProgression: nil,
            baseLoad: 4500
        )
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
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 17...23,
            phaseFinishDeloadPercent: 14...16,
            taperDeloadPercent: 35,
            initialWeeklyDuration: 70,
            initialLongRunDuration: 30...35,
            maxLongRunMinutes: 75,
            longRunProgression: nil,
            baseLoad: 9200
        )
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
        // Accessible Adv 5K: 4 days/wk (matches the locked day-count matrix).
        // Load kept below the textbook Adv 5K twin (accessible = the lighter tier).
        trainingDays: [1, 3, 5, 6], // accessible tier — 4 days
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: false,
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 11...18,
            phaseFinishDeloadPercent: 15...17,
            taperDeloadPercent: 35,
            initialWeeklyDuration: 100,
            initialLongRunDuration: 45...50,
            maxLongRunMinutes: 75,
            longRunProgression: nil,
            baseLoad: 16100.0
        )
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
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 18...26,
            phaseFinishDeloadPercent: 14...16,
            taperDeloadPercent: 35,
            initialWeeklyDuration: 70,
            initialLongRunDuration: 30...40,
            maxLongRunMinutes: 70,
            longRunProgression: (base: 60, speed: 70, peak: 80, taper: 60),
            baseLoad: 4500
        )
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
        // Accessible Int 10K: 3 days/wk (matches the locked day-count matrix).
        // Load kept below the textbook Int 10K twin (accessible = the lighter tier).
        trainingDays: [1, 3, 6], // accessible tier — 3 days
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: true,
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 12...20,
            phaseFinishDeloadPercent: 15...17,
            taperDeloadPercent: 35,
            initialWeeklyDuration: 105,
            initialLongRunDuration: 45...55,
            maxLongRunMinutes: 75,
            longRunProgression: (base: 60, speed: 70, peak: 80, taper: 60),
            baseLoad: 11040
        )
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
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 15...25,
            phaseFinishDeloadPercent: 15...17,
            taperDeloadPercent: 35,
            // Bumped 180 → 220 + bumped LR duration 70-75 → 80-90 so 10K plan
            // visibly out-volumes 5K plan. Daniels Phase II Adv 10K is 70-90
            // km/wk; combined with baseLoad ×1.15 × 1.20 (5K/10K + 10K-specific
            // bumps), bump lands Adv 10K at ~90 km vs Adv 5K's 85 km — clean
            // step up matching user mental model "longer race = more training".
            initialWeeklyDuration: 185,
            initialLongRunDuration: 80...90,
            maxLongRunMinutes: 90,
            longRunProgression: (base: 70, speed: 75, peak: 80, taper: 70),
            baseLoad: 19320
        )
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
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 18...26,
            phaseFinishDeloadPercent: 14...16,
            taperDeloadPercent: 35,
            initialWeeklyDuration: 95,
            initialLongRunDuration: 35...40,
            maxLongRunMinutes: 90,
            longRunProgression: (base: 60, speed: 90, peak: 120, taper: 60),
            baseLoad: 4500
        )
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
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 17...26,
            phaseFinishDeloadPercent: 15...17,
            taperDeloadPercent: 35,
            initialWeeklyDuration: 165,
            initialLongRunDuration: 60...70,
            maxLongRunMinutes: 100,
            longRunProgression: (base: 70, speed: 100, peak: 135, taper: 70),
            baseLoad: 8000
        )
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
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 17...26,
            phaseFinishDeloadPercent: 15...17,
            taperDeloadPercent: 35,
            initialWeeklyDuration: 270,
            initialLongRunDuration: 95...105,
            maxLongRunMinutes: 200,
            longRunProgression: (base: 85, speed: 130, peak: 185, taper: 95),
            baseLoad: 10000
        )
    )

    /// Accessible advanced42Default — identical to the textbook plan.
    public static let accessibleAdvanced42Default = advanced42Default
}
