//
//  PlanConfiguration+CouchTo5K.swift
//  TrainingPlanKit
//
//  Couch-to-5K config: 9 weeks, 3 days/wk, all-BASE (the protocol carries
//  its own progression — no phases, no deloads, no selector). VolumeProfile
//  values only feed the target model the C25K generator ignores; kept sane
//  so shared math never divides by surprise.
//

import Foundation

extension PlanConfiguration {
    public static var couchTo5K: PlanConfiguration {
        var c = PlanConfiguration(
            raceDate: Date(),
            runnerLevel: .beginner,
            distance: 5000,
            basePhaseRatio: 1.0,
            speedPhaseRatio: 0,
            peakPhaseRatio: 0,
            taperPhaseRatio: 0,
            minBasePhaseWeeks: 1,
            minSpeedPhaseWeeks: 0,
            minPeakPhaseWeeks: 0,
            minTaperPhaseWeeks: 0,
            trainingDays: [1, 3, 5], // Tue/Thu/Sat
            longestWorkoutDay: 5,
            useSeparateDayForLongRun: false,
            volume: VolumeProfile(
                weeklyLoadIncreasePercent: 5...10,
                phaseFinishDeloadPercent: 10...12,
                taperDeloadPercent: 20,
                initialWeeklyDuration: 90,
                initialLongRunDuration: 20...30,
                maxLongRunMinutes: 35,
                longRunProgression: nil,
                baseLoad: 3000
            )
        )
        c.isCouchTo5K = true
        return c
    }
}
