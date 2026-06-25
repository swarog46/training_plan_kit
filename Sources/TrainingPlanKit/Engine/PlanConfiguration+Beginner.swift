//
//  PlanConfiguration+Beginner.swift
//  RunPlan
//
//  Beginner-tier plan configs (5K / 10K / 21K / 42K). Each plan fully declares
//  its own shape — days, load (VolumeProfile), long-run cap + ramp — so beginner
//  generation reads here, not as branches in the shared engine. Day counts are
//  LOCKED (see the matrix in PlanConfiguration.swift): 5K=2, 10K=2, 21K=3, 42K=4.
//

import Foundation

extension PlanConfiguration {

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
        // 2 days/wk (Tue/Sat) — beginner 5K is intentionally minimal-frequency.
        // Locked by Q; do not "upgrade" to 3 days.
        trainingDays: [2, 6],
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: false,
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 17...25,
            phaseFinishDeloadPercent: 14...16,
            taperDeloadPercent: 35,
            initialWeeklyDuration: 62,
            initialLongRunDuration: 25...30,
            maxLongRunMinutes: 75,
            longRunProgression: nil,
            baseLoad: 4500
        )
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
        trainingDays: [2, 6], // 2 days/wk — LOCKED, see day-count matrix above
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: true,
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 18...26,
            phaseFinishDeloadPercent: 14...16,
            taperDeloadPercent: 35,
            initialWeeklyDuration: 113,
            initialLongRunDuration: 30...40,
            maxLongRunMinutes: 70,
            longRunProgression: (base: 60, speed: 70, peak: 80, taper: 60),
            baseLoad: 4500
        )
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
        trainingDays: [1, 3, 6], // 3 days/wk — LOCKED, see day-count matrix above
        longestWorkoutDay: 6,
        useSeparateDayForLongRun: true,
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 18...26,
            phaseFinishDeloadPercent: 14...16,
            taperDeloadPercent: 35,
            initialWeeklyDuration: 120,
            initialLongRunDuration: 35...40,
            // Raised 90→100 so a beginner half LR reaches ~15km instead of being
            // clamped to the 60min catalog floor all plan. The 100min
            // progressiveLong becomes selectable in SPEED/PEAK, so the LR climbs.
            maxLongRunMinutes: 100,
            longRunProgression: (base: 60, speed: 90, peak: 120, taper: 60),
            baseLoad: 4500
        )
    )

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
        volume: VolumeProfile(
            weeklyLoadIncreasePercent: 18...26,
            phaseFinishDeloadPercent: 14...16,
            taperDeloadPercent: 35,
            // Higdon Novice 1 Marathon: ~145 min/wk in week 1, peaks ~400 min/wk
            // (40 mi @ 10:00/mi). Bumped from 140 → 220 to align average ~250.
            initialWeeklyDuration: 285,
            initialLongRunDuration: 90...110,
            // Novice marathon long run caps at ~190min (3:00-3:10). The old
            // 205-215 peak (3:25-3:35) was too long for a beginner; the pace
            // converter also holds the rendered long run to this minute cap.
            maxLongRunMinutes: 190,
            longRunProgression: (base: 90, speed: 150, peak: 180, taper: 100),
            baseLoad: 4500
        )
    )
}


/// Beginner-tier behavioural profile. See PlanProfile.
public struct BeginnerProfile: PlanProfile {
    public init() {}
    public var intervalRestCapSeconds: Int { 75 }   // beginners tolerate longer rests
    // Steadier ramp ⇒ no quality-week sawtooth to make cutbacks visible, so the
    // mid-phase recovery week must explicitly dip below the prior week (long
    // beginner 42K/10K builds otherwise climb straight through their cutback).
    public var cutbackDipsBelowPriorWeek: Bool { true }
    public var startsIntervalsInBase: Bool { false }        // aerobic base first
    public var alternatesMilestoneInBase: Bool { false }    // plain base
    public func minIntervalMinutes(phase: TrainingPhase) -> Int {
        switch phase { case .base: 23; case .speed: 28; case .peak: 30; case .taper: 25; case .race: 22 }
    }
    public func qualityPools(intervals: [Workout], thresholds: [Workout],
                             allWorkouts: [Workout], isVO2Max: Bool,
                             hasZone5: (Workout) -> Bool) -> (intervals: [Workout], thresholds: [Workout]) {
        if isVO2Max {
            // VO2 block: keep the Z5 stimulus (hills, 5K-pace reps, TT) on a threshold base.
            let ints: Set<WorkoutSubtype> = [.hillRepeats, .timeTrial, .fivekPace]
            return (intervals.filter { ints.contains($0.subtype) },
                    thresholds.filter { $0.subtype == .threshold })
        }
        // Beginner quality = strides + hills + TT (no Z5 reps), on threshold/MP only.
        let thr: Set<WorkoutSubtype> = [.threshold, .marathonPace]
        return (filterWorkoutsBySubtypeV3(workouts: allWorkouts, subtypes: [.hillRepeats, .timeTrial, .strides]),
                thresholds.filter { !hasZone5($0) && thr.contains($0.subtype) })
    }
}
