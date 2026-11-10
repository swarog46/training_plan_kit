//
//  Plan.swift
//  RunPlan
//
//  Created by Dan Sh on 16/01/2025.
//

import Foundation

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
    case fiveKCompetitive = "Sub-20 5K"
    case tenKCompetitive = "Sub-40 10K"
    case recovery = "Recovery"
    case maintenance = "Maintenance"
    // Daniels Phase III-style 8-week VO2 max block. Non-race fitness plan
    // focused on aerobic-power gains: weekly VO2 interval + tempo + long.
    case vo2max = "VO2 Max"
    // Open-ended fitness for busy weeks: every run under 40 min, one 50-60 min
    // run every 4th week. Maintenance's short-run sibling.
    case shortRuns = "Short Runs"
    // Classic 9-week run/walk protocol to a first 5K (C25KPlanGenerator).
    case couchTo5K = "Couch to 5K"
    case fifteenK = "15K"
    case tenMile = "10 Mile"
    case thirtyK = "30K"
    case fiftyK = "50K"
    // Fixed beginner protocols (FixedProtocol): six weeks of walking with jogs that hand
    // over to Couch to 5K, eight weeks from a 5K to a 10K, four weeks back from a break.
    case walkToRun = "Walk to Run"
    case fiveToTenK = "5K to 10K"
    case returnToRunning = "Return to Running"

    public var id: String { rawValue }

    /// The week-by-week protocol behind the plan, for the plans that are one.
    public var fixedProtocol: FixedProtocol? {
        switch self {
        case .walkToRun: return .walkToRun
        case .fiveToTenK: return .fiveToTenK
        case .returnToRunning: return .returnToRunning
        default: return nil
        }
    }

    /// A beginner plan with its own written progression: one level, heart rate only, fixed length.
    public var isBeginnerProtocol: Bool { isCouchTo5K || fixedProtocol != nil }

    /// Whether this category is a competitive (Pro) plan.
    /// Drives picker hiding and config routing.
    public var isCompetitive: Bool {
        switch self {
        case .marathonCompetitive, .halfMarathonCompetitive, .tenKCompetitive, .fiveKCompetitive: return true
        default: return false
        }
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

    /// Whether this is the Short Runs fitness plan
    public var isShortRuns: Bool { self == .shortRuns }

    /// Whether this is the Couch-to-5K run/walk plan
    public var isCouchTo5K: Bool { self == .couchTo5K }

    /// No race and no fixed end: maintenance and Short Runs.
    public var isOpenEnded: Bool { isMaintenance || isShortRuns }

    /// Whether this plan requires a race date selection
    public var requiresRaceDate: Bool { isRacePlan }

    // MARK: Distance & duration

    /// Target race distance in meters (nil for non-race plans)
    public var distance: Int? {
        switch self {
        case .fiveK, .fiveKCompetitive, .couchTo5K: return 5000
        case .tenK, .tenKCompetitive, .fiveToTenK: return 10000
        case .halfMarathon, .halfMarathonCompetitive: return 21097
        case .marathon, .marathonCompetitive: return 42195
        case .fifteenK: return 15000
        case .tenMile: return 16093
        case .thirtyK: return 30000
        case .fiftyK: return 50000
        case .recovery, .maintenance, .vo2max, .shortRuns, .walkToRun, .returnToRunning: return nil
        }
    }

    /// Minimum recommended plan duration in weeks
    public var minWeeks: Int {
        switch self {
        case .fiveK: return 6
        case .tenK: return 8
        case .halfMarathon: return 12
        case .marathon: return 14
        // Competitive minimums match the engine's phase-distribution minimums
        // (sum of minBase/Speed/Peak/Taper in PlanConfiguration); below these,
        // phases truncate and PEAK ends up shorter than TAPER, breaking the
        // build curve. 12 weeks still preserves a real PEAK > TAPER curve.
        case .halfMarathonCompetitive: return 12
        case .marathonCompetitive: return 12
        // Pro 5K/10K phase minimums sum to 10 (2+3+3+2).
        case .fiveKCompetitive, .tenKCompetitive: return 10
        case .recovery: return 3
        case .maintenance, .shortRuns: return 52
        // VO2 max adaptation window peaks around 6-8 weeks; longer blocks
        // plateau and risk overreaching. Fixed at 8 by min == max.
        case .vo2max: return 8
        // The protocol is 9 weeks; shorter would skip steps, longer repeats W9.
        case .couchTo5K: return 9
        // Fixed protocols run their written length.
        case .walkToRun: return 6
        case .fiveToTenK: return 8
        case .returnToRunning: return 4
        // Below 12 weeks the build loses its cutback weeks (R23 deload rhythm).
        case .fifteenK, .tenMile: return 12
        // 30K/50K phase minimums sum to 15 / 17 (Adv 30K, both 50K presets).
        case .thirtyK: return 16
        case .fiftyK: return 18
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
        // recommendedPlanWeeks clamps 12-24 for the build band.
        case .fiveKCompetitive, .tenKCompetitive: return 24
        case .recovery: return 4
        case .maintenance, .shortRuns: return 52
        case .vo2max: return 8
        case .couchTo5K: return 9
        case .walkToRun: return 6
        case .fiveToTenK: return 8
        case .returnToRunning: return 4
        case .fifteenK, .tenMile: return 14
        case .thirtyK: return 20
        // Past 22 weeks the 50K PEAK phase outgrows the certified marathon's (9-10).
        case .fiftyK: return 22
        }
    }

    // MARK: Training characteristics

    /// Weekly load increase percentage range for this plan type
    public var weeklyLoadIncreaseRange: ClosedRange<Double> {
        switch self {
        case .maintenance, .recovery, .shortRuns, .couchTo5K, .walkToRun, .fiveToTenK, .returnToRunning: return 5...10
        case .fiveK, .tenK, .vo2max, .fiveKCompetitive, .tenKCompetitive, .fifteenK, .tenMile: return 10...15
        case .halfMarathon, .marathon, .halfMarathonCompetitive, .marathonCompetitive, .thirtyK, .fiftyK: return 15...20
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
        // Pro 5K/10K default to 5 days; the runner may drop to 4.
        case .fiveKCompetitive, .tenKCompetitive: return 4...5
        case .recovery: return 2...3
        case .maintenance: return 2...4
        case .shortRuns: return 3...4
        case .vo2max: return 3...5
        case .couchTo5K, .walkToRun, .fiveToTenK, .returnToRunning: return 3...3
        // Presets: Beg 3 / Int 4 / Adv 5; 30K/50K have no beginner preset.
        case .fifteenK, .tenMile: return 3...5
        case .thirtyK, .fiftyK: return 4...5
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

    /// Preferred workout subtypes for the plan-detail "Types of runs" chip row.
    /// Aligned against `plan_debug dump` so the chips reflect what the engine
    /// actually schedules. Generic `.intervals` stays alongside specific
    /// subtypes because the engine schedules both. Order: easy → long → quality.
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
        case .fiveKCompetitive:
            return [.easy, .strides, .threshold, .intervals, .hillRepeats, .fivekPace, .timeTrial]
        case .tenKCompetitive:
            return [.easy, .strides, .long, .mediumLong, .threshold, .intervals, .hillRepeats, .tenkPace, .raceRehearsal10K]
        case .shortRuns:
            return [.easy, .strides, .intervals, .threshold, .hillRepeats, .progression]
        // Daniels Phase III VO2 max focus: aerobic-power intervals + threshold
        // for support, with easy + long for aerobic foundation.
        case .vo2max:
            return [.easy, .long, .threshold, .intervals, .hillRepeats, .fivekPace, .timeTrial, .strides]
        // Run/walk sessions are catalog `intervals`; the rest is easy running.
        case .couchTo5K, .walkToRun, .returnToRunning:
            return [.easy, .intervals]
        case .fiveToTenK:
            return [.easy]
        case .fifteenK, .tenMile:
            return [.easy, .strides, .long, .mediumLong, .progression, .threshold, .intervals, .hillRepeats, .mileRepeats, .tenkPace, .raceRehearsalHM, .timeTrial]
        case .thirtyK, .fiftyK:
            return [.easy, .strides, .long, .mediumLong, .progression, .threshold, .intervals, .hillRepeats, .mileRepeats, .raceRehearsalM]
        }
    }

    // MARK: Helpers

    /// Best-fit category for the `Plan.raceDistance` value (stored in METERS:
    /// 5000 / 10000 / 21097 / 42195, or 0 for maintenance). Returns nil for
    /// unrecognized values, and the base category (.marathon / .halfMarathon)
    /// for competitive distances — `Plan.category` adds the competitive variant
    /// via `difficultyLevel`.
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
        // Short Runs stores raceDistance = 2 (engine still runs at distance 0).
        case 2:     self = .shortRuns
        // Couch to 5K stores 3: a 5000 would read back as the Beginner 5K plan.
        case 3:     self = .couchTo5K
        // The fixed protocols store 4, 5 and 6 (5K to 10K's 10000 would read back as the 10K plan).
        case 4:     self = .walkToRun
        case 5:     self = .fiveToTenK
        case 6:     self = .returnToRunning
        case 15000: self = .fifteenK
        case 16093: self = .tenMile
        case 30000: self = .thirtyK
        case 50000: self = .fiftyK
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

    /// Type-safe view of `raceDistance` (prefer this over switching on the raw
    /// Int). Competitive plans share the same 21097 / 42195 as the base plans,
    /// so they're disambiguated here via the `difficultyLevel == .competitive`
    /// marker — every `.category` caller gets the right variant for free.
    public var category: PlanCategory? {
        if difficultyLevel == .competitive {
            switch raceDistance {
            case 21097: return .halfMarathonCompetitive
            case 42195: return .marathonCompetitive
            case 10000: return .tenKCompetitive
            case 5000:  return .fiveKCompetitive
            default: break
            }
        }
        return PlanCategory(raceDistanceMeters: raceDistance)
    }
}
