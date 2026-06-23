//
//  PlanProfile.swift
//  RunPlan
//
//  Per-plan-TYPE behavioral policy. The generator asks the profile for its
//  plan-specific decisions instead of branching on runnerLevel / distance /
//  isVO2Max. That keeps the shared engine plan-agnostic — it never re-derives
//  "which plan is this?" — and puts each type's behaviour in its own file
//  (BeginnerProfile lives in PlanConfiguration+Beginner.swift, etc.).
//
//  Migration in progress: decisions move here one at a time, each behaviour-
//  preserving (the default reproduces the engine's old "else" branch).
//

import Foundation

public protocol PlanProfile {
    /// Max recovery (seconds) an interval rep may have and still be selectable.
    /// Beginners tolerate longer rests; the fitter tiers keep recoveries tight.
    var intervalRestCapSeconds: Int { get }
    /// Whether the plan sprinkles "surprise" progressive weeks through speed/peak
    /// (beginners don't — they get a steadier ramp).
    var hasSurpriseProgressiveWeeks: Bool { get }
    /// Whether intervals already appear in the BASE phase (fitter tiers) vs only
    /// from SPEED on (beginners build aerobically first).
    var startsIntervalsInBase: Bool { get }
    /// Whether BASE alternates in a milestone quality subtype (fitter tiers) vs
    /// staying plain (beginners).
    var alternatesMilestoneInBase: Bool { get }
    /// Load multiplier applied on recovery/deload weeks (competitive cuts harder).
    var recoveryWeekLoadMultiplier: Double { get }
    /// Whether a mid-phase recovery week dips BELOW the prior week rather than
    /// just cutting the still-rising trajectory. Fitter tiers already sawtooth
    /// from quality-week alternation; the steadier beginner builds need the
    /// explicit dip or the cutback is invisible (climbs right through it).
    var cutbackDipsBelowPriorWeek: Bool { get }
    /// Load fraction used when snapping a too-light long run to the nearest
    /// aerobic run (competitive uses a higher fraction).
    var longRunSnapLoadFraction: Double { get }
    /// Minimum interval-session minutes by phase — reps lengthen as the plan
    /// sharpens, and the fitter tiers sustain longer sessions.
    func minIntervalMinutes(phase: TrainingPhase) -> Int
    /// Narrows the interval + threshold pools to what this plan type should use.
    /// Default keeps everything; only the gentler tiers restrict.
    func qualityPools(intervals: [Workout], thresholds: [Workout],
                      allWorkouts: [Workout], isVO2Max: Bool,
                      hasZone5: (Workout) -> Bool) -> (intervals: [Workout], thresholds: [Workout])
}

public extension PlanProfile {
    var intervalRestCapSeconds: Int { 60 }          // fitter-tier defaults
    var hasSurpriseProgressiveWeeks: Bool { true }
    var startsIntervalsInBase: Bool { true }
    var alternatesMilestoneInBase: Bool { true }
    var recoveryWeekLoadMultiplier: Double { 0.85 }
    var cutbackDipsBelowPriorWeek: Bool { false }
    var longRunSnapLoadFraction: Double { 0.35 }
    func minIntervalMinutes(phase: TrainingPhase) -> Int { 22 }   // competitive/default
    func qualityPools(intervals: [Workout], thresholds: [Workout],
                      allWorkouts: [Workout], isVO2Max: Bool,
                      hasZone5: (Workout) -> Bool) -> (intervals: [Workout], thresholds: [Workout]) {
        (intervals, thresholds)   // fitter tiers use the full pools
    }
}

public extension PlanConfiguration {
    /// The behavioural profile for this plan's type — the SINGLE place that maps
    /// a plan to its strategy. The generator calls `config.profile.…`, never a
    /// `runnerLevel` / `distance` switch of its own.
    var profile: PlanProfile {
        switch runnerLevel {
        case .beginner:     return BeginnerProfile()
        case .intermediate: return IntermediateProfile()
        case .advanced:     return AdvancedProfile()
        case .competitive:  return CompetitiveProfile()
        }
    }
}
