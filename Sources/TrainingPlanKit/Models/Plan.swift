//
//  Plan.swift
//  RunPlan
//
//  Created by Dan Sh on 16/01/2025.
//

import Foundation
import SwiftUI

// MARK: - PlanCategory

/// Type-safe representation of a plan's training category. Used as the
/// canonical source for plan-distance color, so iPhone and watch don't drift.
/// Lives in `Shared/` so both targets compile against the same definition.
/// All properties are pure value computations (no UIKit/iPhone-only deps).
public enum PlanCategory: String, Codable, CaseIterable, Identifiable {
    case fiveK = "5K"
    case tenK = "10K"
    case halfMarathon = "Half Marathon"
    case marathon = "Marathon"
    case halfMarathonCompetitive = "Sub-1:30 Half"
    case marathonCompetitive = "Sub-3:00 Marathon"
    case recovery = "Recovery"
    case maintenance = "Maintenance"
    // Daniels Phase III-style 8-week VO2 max block. Non-race fitness plan
    // focused on aerobic-power gains: weekly VO2 interval + tempo + long.
    case vo2max = "VO2 Max"

    public var id: String { rawValue }

    /// Whether this category is a competitive (sub-3 / sub-1:30) plan.
    /// Drives picker hiding and config routing.
    public var isCompetitive: Bool {
        self == .marathonCompetitive || self == .halfMarathonCompetitive
    }

    // MARK: Plan classification

    /// Whether this is a race-focused plan with a target distance
    public var isRacePlan: Bool { distance != nil }

    /// Whether this is a maintenance/fitness plan without a race target
    public var isMaintenance: Bool { self == .maintenance }

    /// Whether this is a recovery-focused plan
    public var isRecovery: Bool { self == .recovery }

    /// Whether this is a VO2 max-focused fitness plan
    public var isVO2Max: Bool { self == .vo2max }

    /// Whether this plan requires a race date selection
    public var requiresRaceDate: Bool { isRacePlan }

    // MARK: Distance & duration

    /// Target race distance in meters (nil for non-race plans)
    public var distance: Int? {
        switch self {
        case .fiveK: return 5000
        case .tenK: return 10000
        case .halfMarathon, .halfMarathonCompetitive: return 21097
        case .marathon, .marathonCompetitive: return 42195
        case .recovery, .maintenance, .vo2max: return nil
        }
    }

    /// Minimum recommended plan duration in weeks
    public var minWeeks: Int {
        switch self {
        case .fiveK: return 6
        case .tenK: return 8
        case .halfMarathon: return 12
        case .marathon: return 14
        // Competitive minimums match the engine's phase-distribution
        // minimums (sum of minBase/Speed/Peak/Taper in PlanConfiguration),
        // so any plan within [minWeeks, maxWeeks] respects all phase
        // constraints. Below these values phases get truncated and PEAK
        // ends up shorter than TAPER, breaking the build curve.
        // 12-week minimum for both competitive plans: at sub-3:20 marathon
        // / sub-1:35 half fitness the runner already has aerobic base, so
        // we can compress phases to base 2 / speed 3 / peak 5 / taper 2
        // (marathon) or 2 / 3 / 5 / 2 (half) and still preserve a real
        // PEAK > TAPER build curve.
        case .halfMarathonCompetitive: return 12
        case .marathonCompetitive: return 12
        case .recovery: return 3
        case .maintenance: return 52
        // VO2 max adaptation window peaks around 6-8 weeks; longer blocks
        // plateau and risk overreaching. Fixed at 8 by min == max.
        case .vo2max: return 8
        }
    }

    /// Maximum recommended plan duration in weeks. Used for the "X-Y weeks"
    /// label on plan cards — sets user expectation for training commitment.
    /// Marathon is intentionally longer than half: standard marathon plans
    /// (Higdon, Pfitzinger, Daniels) range 18-24 weeks.
    public var maxWeeks: Int {
        switch self {
        case .fiveK: return 8
        case .tenK: return 10
        case .halfMarathon: return 16
        case .marathon: return 20
        // Competitive plans accept longer cycles to accommodate the "build
        // band" runners (VDOT 54-57) whose recommended weeks formula lands
        // at 26-30 for half / 30-34 for marathon. See CompetitiveGate.swift.
        case .halfMarathonCompetitive: return 32
        case .marathonCompetitive: return 36
        case .recovery: return 4
        case .maintenance: return 52
        case .vo2max: return 8
        }
    }

    // MARK: Training characteristics

    /// Weekly load increase percentage range for this plan type
    public var weeklyLoadIncreaseRange: ClosedRange<Double> {
        switch self {
        case .maintenance, .recovery: return 5...10
        case .fiveK, .tenK, .vo2max:  return 10...15
        case .halfMarathon, .marathon, .halfMarathonCompetitive, .marathonCompetitive: return 15...20
        }
    }

    /// Recommended number of training sessions per week range
    public var trainingsPerWeekRange: ClosedRange<Int> {
        switch self {
        case .fiveK: return 2...4
        case .tenK: return 2...4
        case .halfMarathon: return 3...5
        case .marathon: return 4...6
        // Displayed runs/week on the plan card. Both competitive plans train
        // a fixed 6-day week in the engine (competitive42/21Default
        // trainingDays). Labels match the engine so the card and the
        // generated plan agree.
        case .marathonCompetitive: return 6...6
        case .halfMarathonCompetitive: return 6...6
        case .recovery: return 2...3
        case .maintenance: return 2...4
        case .vo2max: return 3...5
        }
    }

    /// Whether interval/speed workouts should be included
    public var includesSpeedWork: Bool {
        switch self {
        case .recovery: return false
        case .maintenance: return true
        default: return true
        }
    }

    /// Preferred workout subtypes for this category. Used by the plan-detail
    /// "Types of runs" chip row — shows runners what their plan actually
    /// schedules. Aligned against `plan_debug dump` output so the chips
    /// reflect what the engine produces for Int/Adv variants of each
    /// category. Generic `.intervals` is kept alongside specific subtypes
    /// (hillRepeats, mileRepeats, yasso800, etc.) because the engine
    /// schedules both. Order: easy → long → quality.
    public var preferredWorkoutTypes: [WorkoutSubtype] {
        switch self {
        case .maintenance:
            return [.easy, .long, .progression, .strides]
        case .recovery:
            return [.easy]
        case .fiveK:
            return [.easy, .strides, .progression, .threshold, .intervals, .hillRepeats, .fivekPace, .timeTrial]
        case .tenK:
            return [.easy, .strides, .long, .threshold, .intervals, .hillRepeats, .tenkPace, .raceRehearsal10K, .timeTrial]
        case .halfMarathon:
            return [.easy, .strides, .long, .mediumLong, .threshold, .intervals, .hillRepeats, .mileRepeats, .raceRehearsalHM]
        case .marathon:
            return [.easy, .strides, .long, .mediumLong, .threshold, .intervals, .hillRepeats, .mileRepeats, .raceRehearsalM, .progression]
        case .halfMarathonCompetitive:
            return [.easy, .strides, .long, .mediumLong, .threshold, .intervals, .hillRepeats, .mileRepeats, .fivekPace, .raceRehearsalHM]
        case .marathonCompetitive:
            return [.easy, .strides, .long, .mediumLong, .threshold, .intervals, .hillRepeats, .mileRepeats, .yasso800, .raceRehearsalM]
        // Daniels Phase III VO2 max focus: aerobic-power intervals + threshold
        // for support, with easy + long for aerobic foundation.
        case .vo2max:
            return [.easy, .long, .threshold, .intervals, .hillRepeats, .fivekPace, .timeTrial, .strides]
        }
    }

    // MARK: Color

    /// Canonical accent color per category. Single source of truth — replaces
    /// the older `DistanceUtils.planColor(for: Int)` which had a meters/km
    /// switch bug (callers passed km, switch keyed on meters → everything
    /// fell through to indigo). Use `plan.category?.color` everywhere.
    public var color: Color {
        switch self {
        case .fiveK:                    return Theme.indigo
        case .tenK:                     return Theme.mint
        case .halfMarathon:             return Theme.orange
        case .marathon:                 return Theme.pink
        case .halfMarathonCompetitive:  return Color.red.opacity(0.85)   // distinct from .halfMarathon orange
        case .marathonCompetitive:      return Color.red                  // intense, distinct from .marathon pink
        case .recovery:                 return Theme.cyan
        case .maintenance:              return Theme.purple
        case .vo2max:                   return Theme.green                // separated from race-distance palette
        }
    }

    // MARK: Helpers

    /// Best-fit category for the legacy `Plan.raceDistance` value.
    /// Despite the field's misleading earlier docstring, plans actually store
    /// the race distance in **meters** (5000, 10000, 21097, 42195, or 0 for
    /// maintenance) — see PlanConfigurationView, which sets `raceDistance`
    /// from `planDefinition.distance` (meters). Returns nil for unrecognized
    /// values.
    ///
    /// Note: This init returns the base category (.marathon / .halfMarathon),
    /// not the competitive variants — distinguishing those requires the
    /// `difficultyLevel`, handled by `Plan.category` (see `Plan` struct).
    public init?(raceDistanceMeters meters: Int) {
        switch meters {
        case 5000:  self = .fiveK
        case 10000: self = .tenK
        case 21097: self = .halfMarathon
        case 42195: self = .marathon
        case 0:     self = .maintenance
        // VO2 max plans store raceDistance = 1 as the disambiguator from
        // maintenance (which also has no race target = 0). Mirrors the
        // pattern competitive plans use difficultyLevel == .competitive to
        // separate themselves from .marathon / .halfMarathon.
        case 1:     self = .vo2max
        default: return nil
        }
    }
}

// MARK: - DifficultyLevel

public enum DifficultyLevel: Int16, Codable, CaseIterable {
    case beginner = 1
    case intermediate = 2
    case advanced = 3
    case competitive = 4

    public var flameCount: Int {
        return Int(self.rawValue)
    }

    public var displayName: String {
        switch self {
        case .beginner:     return "difficulty.beginner"
        case .intermediate: return "difficulty.intermediate"
        case .advanced:     return "difficulty.advanced"
        case .competitive:  return "difficulty.competitive"
        }
    }
}

public struct Plan: Identifiable, Codable, Hashable {
    public let id: UUID
    public var name: String
    public var startDate: Date
    public var endDate: Date
    public var events: [WorkoutEvent]
    public var isActive: Bool
    public var isCompleted: Bool
    public var completionDate: Date?  // Date the plan was completed (either end date or race day)
    public var difficultyLevel: DifficultyLevel
    public var raceDistance: Int  // Race distance in meters (5000 / 10000 / 21097 / 42195, or 0 for maintenance)

    public init(id: UUID = UUID(), name: String, startDate: Date, endDate: Date, events: [WorkoutEvent], isActive: Bool = false, isCompleted: Bool = false, completionDate: Date? = nil, difficultyLevel: DifficultyLevel = .beginner, raceDistance: Int = 5000) {
        self.id = id
        self.name = name
        self.startDate = startDate
        self.endDate = endDate
        self.events = events
        self.isActive = isActive
        self.isCompleted = isCompleted
        self.completionDate = completionDate
        self.difficultyLevel = difficultyLevel
        self.raceDistance = raceDistance
    }

    /// Type-safe view of `raceDistance`. Use `category?.color` instead of
    /// switching on the raw Int.
    ///
    /// Competitive plans (Sub-3 Marathon / Sub-1:30 Half) are detected by
    /// the `difficultyLevel == .competitive` marker — `raceDistance` alone
    /// is the same 21097 / 42195 as the base plans, so this disambiguation
    /// has to live somewhere. We do it here so every caller of `.category`
    /// gets the right variant without thinking about it.
    public var category: PlanCategory? {
        if difficultyLevel == .competitive {
            switch raceDistance {
            case 21097: return .halfMarathonCompetitive
            case 42195: return .marathonCompetitive
            default: break
            }
        }
        return PlanCategory(raceDistanceMeters: raceDistance)
    }
}
