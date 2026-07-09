//
//  PlanConfiguration+Intermediate.swift
//  RunPlan
//
//  Intermediate-tier plan configs. Each plan fully declares its own shape — days, load
//  (VolumeProfile), long-run cap + ramp — so the shared engine never branches on
//  which plan it is. Day counts are LOCKED (see PlanConfiguration.swift matrix).
//

import Foundation

extension PlanConfiguration {

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
        trainingDays: [1, 3, 6], // 3 days/wk — LOCKED, see day-count matrix above
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: false,
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 17...23,
            phaseFinishDeloadPercent: 14...16,
            taperDeloadPercent: 35,
            initialWeeklyDuration: 80,
            initialLongRunDuration: 30...35,
            maxLongRunMinutes: 75,
            longRunProgression: nil,
            baseLoad: 9200
        )
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
        trainingDays: [1, 3, 6], // 3 days/wk — LOCKED, see day-count matrix above
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: true,
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 17...26,
            phaseFinishDeloadPercent: 15...17,
            taperDeloadPercent: 35,
            // Bumped 140 → 170 so 10K plan visibly out-volumes 5K plan (matches
            // user mental model "longer race = more training"). Daniels' Phase II
            // Int 10K is 50-65 km/wk — bump lands ~58 km vs 5K's 48 km, clean
            // step up.
            initialWeeklyDuration: 170,
            initialLongRunDuration: 45...55,
            maxLongRunMinutes: 75,
            longRunProgression: (base: 60, speed: 70, peak: 80, taper: 60),
            baseLoad: 11040
        )
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
        trainingDays: [1, 3, 5, 6], // Tue, Thu, Sat, Sun - 4 workouts/week
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: true,
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 17...26,
            phaseFinishDeloadPercent: 15...17,
            taperDeloadPercent: 35,
            initialWeeklyDuration: 200,
            initialLongRunDuration: 60...70,
            maxLongRunMinutes: 100,
            longRunProgression: (base: 70, speed: 100, peak: 135, taper: 70),
            baseLoad: 8000
        )
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
        trainingDays: [1, 3, 5, 6], // Tue, Thu, Sat, Sun - 4 workouts/week
        longestWorkoutDay: 6,
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 17...26,
            phaseFinishDeloadPercent: 15...17,
            taperDeloadPercent: 35,
            initialWeeklyDuration: 320,
            initialLongRunDuration: 95...105,
            maxLongRunMinutes: 200,
            longRunProgression: (base: 85, speed: 130, peak: 185, taper: 95),
            baseLoad: 10000
        )
    )

    // 15K — HM-lite: intermediate 21K shape at ~0.85 volume.
    public static let intermediate15Default = PlanConfiguration(
        raceDate: Date(),
        runnerLevel: .intermediate,
        distance: 15000,
        basePhaseRatio: 0.25,
        speedPhaseRatio: 0.35,
        peakPhaseRatio: 0.3,
        taperPhaseRatio: 0.1,
        minBasePhaseWeeks: 2,
        minSpeedPhaseWeeks: 3,
        minPeakPhaseWeeks: 3,
        minTaperPhaseWeeks: 2,
        trainingDays: [1, 3, 5, 6],
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: true,
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 17...26,
            phaseFinishDeloadPercent: 15...17,
            taperDeloadPercent: 35,
            initialWeeklyDuration: 170,
            initialLongRunDuration: 50...60,
            maxLongRunMinutes: 85,
            longRunProgression: (base: 85, speed: 95, peak: 115, taper: 70),
            baseLoad: 8000
        )
    )

    // 10 mile — same band as 15K, slightly longer.
    public static let intermediate10MiDefault = PlanConfiguration(
        raceDate: Date(),
        runnerLevel: .intermediate,
        distance: 16093,
        basePhaseRatio: 0.25,
        speedPhaseRatio: 0.35,
        peakPhaseRatio: 0.3,
        taperPhaseRatio: 0.1,
        minBasePhaseWeeks: 2,
        minSpeedPhaseWeeks: 3,
        minPeakPhaseWeeks: 3,
        minTaperPhaseWeeks: 2,
        trainingDays: [1, 3, 5, 6],
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: true,
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 17...26,
            phaseFinishDeloadPercent: 15...17,
            taperDeloadPercent: 35,
            initialWeeklyDuration: 180,
            initialLongRunDuration: 55...65,
            maxLongRunMinutes: 90,
            longRunProgression: (base: 85, speed: 95, peak: 120, taper: 70),
            baseLoad: 8000
        )
    )

    // 30K — marathon-lite: 42K shape at ~0.88 volume; render window peaks LR 22-27km.
    public static let intermediate30Default = PlanConfiguration(
        raceDate: Date(),
        runnerLevel: .intermediate,
        distance: 30000,
        basePhaseRatio: 0.15,
        speedPhaseRatio: 0.3,
        peakPhaseRatio: 0.45,
        taperPhaseRatio: 0.1,
        minBasePhaseWeeks: 3,
        minSpeedPhaseWeeks: 4,
        minPeakPhaseWeeks: 5,
        minTaperPhaseWeeks: 2,
        trainingDays: [1, 3, 5, 6],
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: true,
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 17...26,
            phaseFinishDeloadPercent: 15...17,
            taperDeloadPercent: 35,
            initialWeeklyDuration: 280,
            initialLongRunDuration: 85...95,
            maxLongRunMinutes: 175,
            longRunProgression: (base: 80, speed: 115, peak: 165, taper: 85),
            baseLoad: 10000
        )
    )

    // 50K — ultra entry: 42K + time-on-feet (LR render-capped 28-34km), gentler ramp, 3-week taper.
    public static let intermediate50Default = PlanConfiguration(
        raceDate: Date(),
        runnerLevel: .intermediate,
        distance: 50000,
        basePhaseRatio: 0.2,
        speedPhaseRatio: 0.25,
        peakPhaseRatio: 0.45,
        taperPhaseRatio: 0.1,
        minBasePhaseWeeks: 4,
        minSpeedPhaseWeeks: 4,
        minPeakPhaseWeeks: 6,
        minTaperPhaseWeeks: 3,
        trainingDays: [1, 3, 5, 6],
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: true,
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 15...24,
            phaseFinishDeloadPercent: 15...17,
            taperDeloadPercent: 35,
            initialWeeklyDuration: 340,
            initialLongRunDuration: 100...115,
            maxLongRunMinutes: 215,
            longRunProgression: (base: 95, speed: 140, peak: 200, taper: 105),
            baseLoad: 10000
        )
    )
}


/// Intermediate-tier behavioural profile (fitter-tier defaults). See PlanProfile.
public struct IntermediateProfile: PlanProfile {
    public init() {}
    public func minIntervalMinutes(phase: TrainingPhase) -> Int {
        switch phase { case .base: 25; case .speed: 32; case .peak: 38; case .taper: 28; case .race: 22 }
    }
}
