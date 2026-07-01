//
//  PlanConfiguration+Advanced.swift
//  RunPlan
//
//  Advanced-tier plan configs. Each plan fully declares its own shape — days, load
//  (VolumeProfile), long-run cap + ramp — so the shared engine never branches on
//  which plan it is. Day counts are LOCKED (see PlanConfiguration.swift matrix).
//

import Foundation

extension PlanConfiguration {

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
        trainingDays: [1, 3, 5, 6], // 4 days/wk — LOCKED, see day-count matrix above
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: false,
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 15...25,
            phaseFinishDeloadPercent: 15...17,
            taperDeloadPercent: 35,
            initialWeeklyDuration: 150,
            initialLongRunDuration: 45...50,
            maxLongRunMinutes: 75,
            longRunProgression: nil,
            baseLoad: 16100.0
        )
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
        trainingDays: [1, 3, 5, 6], // 4 days/wk — LOCKED, see day-count matrix above
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
            initialWeeklyDuration: 220,
            initialLongRunDuration: 80...90,
            maxLongRunMinutes: 90,
            longRunProgression: (base: 70, speed: 75, peak: 80, taper: 70),
            baseLoad: 19320
        )
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
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 15...25,
            phaseFinishDeloadPercent: 15...17,
            taperDeloadPercent: 35,
            initialWeeklyDuration: 200,
            initialLongRunDuration: 80...85,
            maxLongRunMinutes: 105,
            longRunProgression: (base: 80, speed: 110, peak: 145, taper: 80),
            baseLoad: 21000
        )
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
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 15...25,
            phaseFinishDeloadPercent: 15...17,
            taperDeloadPercent: 35,
            // Pfitzinger 18/55: ~33-55 mi/wk = 280-470 min. Bumped 360 → 420 to
            // close the gap against Pfitz Advanced — peak now lands ~390 min/wk,
            // ~83% of 18/55 peak. Still below 18/70 (Cmp territory) which keeps
            // the tier distinction meaningful.
            initialWeeklyDuration: 420,
            initialLongRunDuration: 90...100,
            maxLongRunMinutes: 210,
            longRunProgression: (base: 90, speed: 140, peak: 195, taper: 105),
            baseLoad: 17500
        )
    )
}


/// Advanced-tier behavioural profile (fitter-tier defaults). See PlanProfile.
public struct AdvancedProfile: PlanProfile {
    public init() {}
    public func minIntervalMinutes(phase: TrainingPhase) -> Int {
        switch phase { case .base: 28; case .speed: 38; case .peak: 45; case .taper: 30; case .race: 22 }
    }
}
