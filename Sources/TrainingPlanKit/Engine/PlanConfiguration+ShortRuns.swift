//
//  PlanConfiguration+ShortRuns.swift
//  TrainingPlanKit
//
//  Short Runs configs: open-ended fitness for busy weeks (distance 0, like
//  maintenance). Days per level match maintenance (3/3/4). The generator sets
//  its own minutes and quality ramp; VolumeProfile only feeds shared target
//  math (light-week labels), kept sane like C25K's.
//

import Foundation

extension PlanConfiguration {

    private static func shortRuns(level: RunnerLevel, days: [Int], weekly: Int, baseLoad: Double) -> PlanConfiguration {
        var c = PlanConfiguration(
            raceDate: Date().addingTimeInterval(60 * 24 * 3600),
            runnerLevel: level,
            distance: 0,
            basePhaseRatio: 0.4,
            speedPhaseRatio: 0.5,
            peakPhaseRatio: 0.0,
            taperPhaseRatio: 0.1,
            minBasePhaseWeeks: 2,
            minSpeedPhaseWeeks: 3,
            minPeakPhaseWeeks: 0,
            minTaperPhaseWeeks: 1,
            trainingDays: days,
            longestWorkoutDay: 6,
            useSeparateDayForLongRun: true,
            volume: VolumeProfile(
                weeklyLoadIncreasePercent: 5...10,
                phaseFinishDeloadPercent: 15...20,
                taperDeloadPercent: 25,
                initialWeeklyDuration: weekly,
                initialLongRunDuration: 30...35,
                maxLongRunMinutes: 60,
                longRunProgression: nil,
                baseLoad: baseLoad
            )
        )
        c.isShortRuns = true
        return c
    }

    public static var shortRunsBeginner: PlanConfiguration {
        shortRuns(level: .beginner, days: [1, 3, 6], weekly: 80, baseLoad: 4000)       // Mon, Wed, Sat
    }

    public static var shortRunsIntermediate: PlanConfiguration {
        shortRuns(level: .intermediate, days: [1, 3, 6], weekly: 95, baseLoad: 5500)   // Mon, Wed, Sat
    }

    public static var shortRunsAdvanced: PlanConfiguration {
        shortRuns(level: .advanced, days: [1, 3, 4, 6], weekly: 130, baseLoad: 8000)   // Mon, Wed, Thu, Sat
    }
}
