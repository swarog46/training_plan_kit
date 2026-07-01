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
}


/// Intermediate-tier behavioural profile (fitter-tier defaults). See PlanProfile.
public struct IntermediateProfile: PlanProfile {
    public init() {}
    public func minIntervalMinutes(phase: TrainingPhase) -> Int {
        switch phase { case .base: 25; case .speed: 32; case .peak: 38; case .taper: 28; case .race: 22 }
    }
}
