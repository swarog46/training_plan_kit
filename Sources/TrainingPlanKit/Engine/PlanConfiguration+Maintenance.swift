//
//  PlanConfiguration+Maintenance.swift
//  RunPlan
//
//  Maintenance-tier plan configs (own shape: days + VolumeProfile incl. long-run cap/ramp).
//  Aliases reuse a textbook twin where no lighter variant is warranted.
//

import Foundation

extension PlanConfiguration {

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
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 5...10, // SLOW progression
            phaseFinishDeloadPercent: 15...20,
            taperDeloadPercent: 25,
            initialWeeklyDuration: 60,
            initialLongRunDuration: 25...30,
            maxLongRunMinutes: 90,
            longRunProgression: nil,
            baseLoad: 4500
        )
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
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 6...10,
            phaseFinishDeloadPercent: 15...20,
            taperDeloadPercent: 25,
            initialWeeklyDuration: 120,
            initialLongRunDuration: 45...50,
            maxLongRunMinutes: 90,
            longRunProgression: nil,
            baseLoad: 8000
        )
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
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 5...8,
            phaseFinishDeloadPercent: 15...20,
            taperDeloadPercent: 25,
            initialWeeklyDuration: 200,
            initialLongRunDuration: 75...80,
            maxLongRunMinutes: 90,
            longRunProgression: nil,
            baseLoad: 14000
        )
    )
}
