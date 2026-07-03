//
//  PlanConfiguration+Accessible.swift
//  RunPlan
//
//  Accessible-tier plan configs. Each family is genuinely lighter than its
//  textbook twin (~12-16% lower training load) via a uniformly scaled-down
//  VolumeProfile — baseLoad + durations + long-run cap/ramp — while keeping the
//  LOCKED day-count matrix (Beg 2/2/3/4, Int 3/3/4/4, Adv 4/4/5/5) and the same
//  periodization, taper, and safety rails. No alias reuses a textbook twin.
//

import Foundation

extension PlanConfiguration {

    public static let accessibleBeginner5Default = PlanConfiguration(
        raceDate: Date(),
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
        trainingDays: [2, 6], // accessible tier — locked day-count
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: false,
        // Already >=10% lighter than textbook (verbatim).
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
        trainingDays: [1, 3, 6], // accessible tier — locked day-count
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: false,
        // Accessible = textbook twin VolumeProfile x0.70 (long-run x0.70; ~lighter tier).
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 17...23,
            phaseFinishDeloadPercent: 14...16,
            taperDeloadPercent: 35,
            initialWeeklyDuration: 56,
            initialLongRunDuration: 25...30,
            maxLongRunMinutes: 72,
            longRunProgression: nil,
            baseLoad: 6440
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
        trainingDays: [1, 3, 5, 6], // accessible tier — locked day-count
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: false,
        // Accessible = textbook twin VolumeProfile x0.72 (long-run x0.72; ~lighter tier).
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 15...25,
            phaseFinishDeloadPercent: 15...17,
            taperDeloadPercent: 35,
            initialWeeklyDuration: 108,
            initialLongRunDuration: 32...37,
            maxLongRunMinutes: 72,
            longRunProgression: nil,
            baseLoad: 11592
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
        trainingDays: [2, 6], // accessible tier — locked day-count
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: true,
        // Already >=10% lighter than textbook (verbatim).
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
        trainingDays: [1, 3, 6], // accessible tier — locked day-count
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: true,
        // Accessible = textbook twin VolumeProfile x0.68 (long-run x0.68; ~lighter tier).
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 17...26,
            phaseFinishDeloadPercent: 15...17,
            taperDeloadPercent: 35,
            initialWeeklyDuration: 116,
            initialLongRunDuration: 31...37,
            maxLongRunMinutes: 74,
            longRunProgression: (base: 60, speed: 67, peak: 74, taper: 60),
            baseLoad: 7507
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
        trainingDays: [1, 3, 5, 6], // accessible tier — locked day-count
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: true,
        // Accessible = textbook twin VolumeProfile x0.70 (long-run x0.70; ~lighter tier).
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 15...25,
            phaseFinishDeloadPercent: 15...17,
            taperDeloadPercent: 35,
            initialWeeklyDuration: 154,
            initialLongRunDuration: 56...63,
            maxLongRunMinutes: 72,
            longRunProgression: (base: 60, speed: 64, peak: 67, taper: 60),
            baseLoad: 13524
        )
    )

    public static let accessibleBeginner21Default = PlanConfiguration(
        raceDate: Date(),
        runnerLevel: .beginner,
        distance: 21097,
        basePhaseRatio: 0.30,
        speedPhaseRatio: 0.30,
        peakPhaseRatio: 0.30,
        taperPhaseRatio: 0.10,
        minBasePhaseWeeks: 4,
        minSpeedPhaseWeeks: 4,
        minPeakPhaseWeeks: 4,
        minTaperPhaseWeeks: 2,
        trainingDays: [1, 3, 6], // accessible tier — locked day-count
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: true,
        // Accessible = textbook twin VolumeProfile x0.60 (long-run x0.55; ~lighter tier).
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 18...26,
            phaseFinishDeloadPercent: 14...16,
            taperDeloadPercent: 35,
            initialWeeklyDuration: 72,
            initialLongRunDuration: 19...22,
            maxLongRunMinutes: 110,
            longRunProgression: (base: 60, speed: 72, peak: 72, taper: 60),
            baseLoad: 2700
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
        trainingDays: [1, 3, 5, 6], // accessible tier — locked day-count
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: true,
        // Accessible = textbook twin VolumeProfile x0.46 (long-run x0.55; ~lighter tier).
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 17...26,
            phaseFinishDeloadPercent: 15...17,
            taperDeloadPercent: 35,
            initialWeeklyDuration: 92,
            initialLongRunDuration: 33...38,
            maxLongRunMinutes: 120,
            longRunProgression: (base: 60, speed: 72, peak: 72, taper: 60),
            baseLoad: 3680
        )
    )

    public static let accessibleAdvanced21Default = PlanConfiguration(
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
        trainingDays: [1, 3, 4, 5, 6], // accessible tier — locked day-count
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: true,
        // Accessible = textbook twin VolumeProfile x0.78 (long-run x0.78; ~lighter tier).
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 15...25,
            phaseFinishDeloadPercent: 15...17,
            taperDeloadPercent: 35,
            initialWeeklyDuration: 156,
            initialLongRunDuration: 62...66,
            maxLongRunMinutes: 113,
            longRunProgression: (base: 62, speed: 85, peak: 113, taper: 62),
            baseLoad: 16380
        )
    )

    public static let accessibleBeginner42Default = PlanConfiguration(
        raceDate: Date(),
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
        trainingDays: [1, 3, 5, 6], // accessible tier — locked day-count
        longestWorkoutDay: 6,
        // Accessible = textbook twin VolumeProfile x0.78 (long-run x0.78; ~lighter tier).
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 18...26,
            phaseFinishDeloadPercent: 14...16,
            taperDeloadPercent: 35,
            initialWeeklyDuration: 222,
            initialLongRunDuration: 70...86,
            maxLongRunMinutes: 168,
            longRunProgression: (base: 70, speed: 117, peak: 160, taper: 78),
            baseLoad: 3510
        )
    )

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
        trainingDays: [1, 3, 5, 6], // accessible tier — locked day-count
        longestWorkoutDay: 6,
        // Accessible = textbook twin VolumeProfile x0.72 (long-run x0.72; ~lighter tier).
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 17...26,
            phaseFinishDeloadPercent: 15...17,
            taperDeloadPercent: 35,
            initialWeeklyDuration: 230,
            initialLongRunDuration: 68...76,
            maxLongRunMinutes: 170,
            longRunProgression: (base: 61, speed: 93, peak: 133, taper: 68),
            baseLoad: 7200
        )
    )

    public static let accessibleAdvanced42Default = PlanConfiguration(
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
        trainingDays: [1, 3, 4, 5, 6], // accessible tier — locked day-count
        longestWorkoutDay: 6,
        // Accessible = textbook twin VolumeProfile x0.78 (long-run x0.78; ~lighter tier).
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 15...25,
            phaseFinishDeloadPercent: 15...17,
            taperDeloadPercent: 35,
            initialWeeklyDuration: 328,
            initialLongRunDuration: 70...78,
            maxLongRunMinutes: 164,
            longRunProgression: (base: 70, speed: 109, peak: 152, taper: 82),
            baseLoad: 13650
        )
    )
}
