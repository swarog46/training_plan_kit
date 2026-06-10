//
//  RaceDistance.swift
//  RunPlan
//
//  Created by Dan Sh on 21/10/2025.
//


// MARK: - Plan Type (Training methodology)

/// Defines the training methodology used for workout intensity targets
public enum PlanType: String, Codable, CaseIterable, Identifiable {
    case heartRate = "Heart Rate"
    case pace = "Pace"

    public var id: String { rawValue }

    /// User-friendly display name
    public var displayName: String { rawValue }

    /// Short description for UI
    public var tagline: String {
        switch self {
        case .heartRate: return "plan.type.heart_rate.tagline"
        case .pace:      return "plan.type.pace.tagline"
        }
    }

    /// Icon name for SF Symbols
    public var iconName: String {
        switch self {
        case .heartRate: return "heart.fill"
        case .pace: return "speedometer"
        }
    }

    /// Whether this plan type requires user pace input during configuration
    public var requiresPaceInput: Bool {
        self == .pace
    }

    /// The target type used in workout intervals
    public var intervalTargetType: TargetType {
        switch self {
        case .heartRate: return .heartRate
        case .pace: return .speed
        }
    }
}

// MARK: - Plan Category
// `PlanCategory` is now defined in `Shared/Plan.swift` so the watch can
// reuse it (notably `category.color`). All properties moved unchanged.

// MARK: - Plan Goal (picker filter)

/// Goal-based filter for the plan picker. Categories can belong to several
/// goals at once (overlapping tags): 5K is both Race and Fitness, and the
/// competitive plans are both Race and Pro.
public enum PlanGoal: String, CaseIterable, Identifiable {
    // Declaration order drives chip order: Race first (default), All last.
    case race, pro, fitness, all

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all:     return "All"
        case .race:    return "Race"
        case .pro:     return "Pro"
        case .fitness: return "Fitness"
        }
    }
}

extension PlanCategory {
    /// Goal tags used by the picker's filter chips. `.all` isn't stored here —
    /// it matches everything in the filtering code.
    public var goals: Set<PlanGoal> {
        switch self {
        case .fiveK:                                          return [.race]
        case .tenK, .halfMarathon, .marathon:                 return [.race]
        case .halfMarathonCompetitive, .marathonCompetitive:  return [.race, .pro]
        case .maintenance, .recovery, .vo2max:                return [.fitness]
        }
    }
}

// MARK: - Training Plan Definition

/// A complete training plan definition combining category and training methodology
public struct TrainingPlanDefinition: Identifiable, Hashable {
    public let id: String
    public let category: PlanCategory
    public let planType: PlanType
    public let isPaid: Bool
    public let isEnabled: Bool

    // MARK: - Delegated Properties (from PlanCategory)

    public var distance: Int? { category.distance }
    public var isRacePlan: Bool { category.isRacePlan }
    public var isMaintenance: Bool { category.isMaintenance }
    public var requiresRaceDate: Bool { category.requiresRaceDate }
    public var minWeeks: Int { category.minWeeks }
    public var maxWeeks: Int { category.maxWeeks }
    public var weeklyLoadIncreaseRange: ClosedRange<Double> { category.weeklyLoadIncreaseRange }
    public var trainingsPerWeekRange: ClosedRange<Int> { category.trainingsPerWeekRange }
    public var includesSpeedWork: Bool { category.includesSpeedWork }
    public var preferredWorkoutTypes: [WorkoutSubtype] { category.preferredWorkoutTypes }

    // MARK: - Delegated Properties (from PlanType)

    public var requiresPaceInput: Bool { planType.requiresPaceInput }
    public var basedOn: String { planType.tagline }
    public var planTypeIcon: String { planType.iconName }

    // MARK: - Formatted Display Properties

    public var weeksRange: String {
        if category.isMaintenance {
            return "plan.weeks_range.open_ended"
        }
        // Collapse to a single number for fixed-length plans (e.g. VO2 max
        // is always 8 weeks) so the card shows "8 weeks" instead of "8-8".
        if minWeeks == maxWeeks {
            return String(format: "%d weeks", minWeeks)
        }
        return String(format: "plan.weeks_range.range_format", minWeeks, maxWeeks)
    }

    public var trainingsPerWeek: String {
        let range = trainingsPerWeekRange
        // Collapse to a single number when the range is fixed (e.g. competitive
        // plans show "6 runs/week", not "6-6").
        if range.lowerBound == range.upperBound {
            return String(format: "plan.trainings_per_week.single_format", range.lowerBound)
        }
        return String(format: "plan.trainings_per_week.format", range.lowerBound, range.upperBound)
    }

    // MARK: - UI Metadata

    public var title: String {
        switch category {
        case .fiveK:                    return "plan.category.5k.title"
        case .tenK:                     return "plan.category.10k.title"
        case .halfMarathon:             return "plan.category.half_marathon.title"
        case .marathon:                 return "plan.category.marathon.title"
        case .halfMarathonCompetitive:  return "plan.category.half_marathon_competitive.title"
        case .marathonCompetitive:      return "plan.category.marathon_competitive.title"
        case .recovery:                 return "plan.category.recovery.title"
        case .maintenance:              return "plan.category.maintenance.title"
        case .vo2max:                   return "VO2 Max"
        }
    }

    public var levels: String {
        // Competitive (Sub-3 / Sub-1:30) plans are pitched at experienced
        // runners — labelled "master" instead of the generic "all levels".
        category.isCompetitive ? "plan.levels.master" : "plan.levels.all"
    }

    public var description: String {
        switch category {
        case .fiveK:                    return "plan.category.5k.description"
        case .tenK:                     return "plan.category.10k.description"
        case .halfMarathon:             return "plan.category.half_marathon.description"
        case .marathon:                 return "plan.category.marathon.description"
        case .halfMarathonCompetitive:  return "plan.category.half_marathon_competitive.description"
        case .marathonCompetitive:      return "plan.category.marathon_competitive.description"
        case .recovery:                 return "plan.category.recovery.description"
        case .maintenance:              return "plan.category.maintenance.description"
        case .vo2max:                   return "8-week aerobic-power block focused on VO2 max intervals, tempo support, and a weekly long run. Improves running economy and lactate threshold without targeting a specific race."
        }
    }

    // Hashable conformance
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: TrainingPlanDefinition, rhs: TrainingPlanDefinition) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Available Plans Registry
public struct AvailablePlans {
    // All available training plans
    public static let all: [TrainingPlanDefinition] = [
        // Heart Rate based plans
        TrainingPlanDefinition(
            id: "5k_hr",
            category: .fiveK,
            planType: .heartRate,
            isPaid: false,
            isEnabled: true
        ),
        TrainingPlanDefinition(
            id: "10k_hr",
            category: .tenK,
            planType: .heartRate,
            isPaid: false,
            isEnabled: true
        ),
        TrainingPlanDefinition(
            id: "half_marathon_hr",
            category: .halfMarathon,
            planType: .heartRate,
            isPaid: false,
            isEnabled: true
        ),
        TrainingPlanDefinition(
            id: "marathon_hr",
            category: .marathon,
            planType: .heartRate,
            isPaid: false,
            isEnabled: true
        ),

        // Recovery and Maintenance (coming soon)
        TrainingPlanDefinition(
            id: "recovery_hr",
            category: .recovery,
            planType: .heartRate,
            isPaid: false,
            isEnabled: false  // Coming soon
        ),
        TrainingPlanDefinition(
            id: "maintenance_hr",
            category: .maintenance,
            planType: .heartRate,
            isPaid: false,
            isEnabled: true  // Now available!
        ),

        // Pace based plans
        TrainingPlanDefinition(
            id: "5k_pace",
            category: .fiveK,
            planType: .pace,
            isPaid: false,
            isEnabled: true
        ),
        TrainingPlanDefinition(
            id: "10k_pace",
            category: .tenK,
            planType: .pace,
            isPaid: false,
            isEnabled: true
        ),
        TrainingPlanDefinition(
            id: "half_marathon_pace",
            category: .halfMarathon,
            planType: .pace,
            isPaid: false,
            isEnabled: true
        ),
        TrainingPlanDefinition(
            id: "marathon_pace",
            category: .marathon,
            planType: .pace,
            isPaid: false,
            isEnabled: true
        ),

        // Competitive plans — pace-only, single fixed config, no level picker.
        // These appear as separate cards in PlansView ("Sub-3:00 Marathon",
        // "Sub-1:30 Half"). Engine maps category → competitive42/21 config
        // in PlanConfigurationView.getPlanConfigurationForLevel.
        TrainingPlanDefinition(
            id: "marathon_competitive_pace",
            category: .marathonCompetitive,
            planType: .pace,
            isPaid: false,
            isEnabled: true
        ),
        TrainingPlanDefinition(
            id: "half_marathon_competitive_pace",
            category: .halfMarathonCompetitive,
            planType: .pace,
            isPaid: false,
            isEnabled: true
        ),

        TrainingPlanDefinition(
            id: "maintenance_pace",
            category: .maintenance,
            planType: .pace,
            isPaid: false,
            isEnabled: false  // Maintenance is HR-only
        ),

        // VO2 max — Daniels Phase III aerobic-power block. 8 weeks fixed.
        // Both HR and Pace variants ship enabled.
        TrainingPlanDefinition(
            id: "vo2max_hr",
            category: .vo2max,
            planType: .heartRate,
            isPaid: false,
            isEnabled: true
        ),
        TrainingPlanDefinition(
            id: "vo2max_pace",
            category: .vo2max,
            planType: .pace,
            isPaid: false,
            isEnabled: true
        ),
    ]

    // Convenience accessors
    public static var enabled: [TrainingPlanDefinition] {
        all.filter { $0.isEnabled }
    }

    /// One plan per category (for PlansView display). Defaults to HR variant.
    /// Plan type is selected in PlanConfigurationView.
    public static var uniqueCategories: [TrainingPlanDefinition] {
        var seen = Set<PlanCategory>()
        return enabled.filter { plan in
            if seen.contains(plan.category) { return false }
            seen.insert(plan.category)
            return true
        }
    }

    public static var free: [TrainingPlanDefinition] {
        all.filter { !$0.isPaid }
    }

    public static var paid: [TrainingPlanDefinition] {
        all.filter { $0.isPaid }
    }

    public static var racePlans: [TrainingPlanDefinition] {
        all.filter { $0.isRacePlan }
    }

    public static var specialPlans: [TrainingPlanDefinition] {
        all.filter { !$0.isRacePlan }
    }

    public static func plan(for id: String) -> TrainingPlanDefinition? {
        all.first { $0.id == id }
    }

    public static func plans(for category: PlanCategory) -> [TrainingPlanDefinition] {
        all.filter { $0.category == category }
    }
}

// MARK: - Legacy Support (RaceDistance enum for backward compatibility)
// This maintains compatibility with existing code while we migrate
public enum RaceDistance: String, CaseIterable, Identifiable {
    case fiveK = "5K"
    case tenK = "10K"
    case halfMarathon = "Half Marathon"
    case marathon = "Marathon"

    public var id: String { self.rawValue }

    // Convert to new TrainingPlanDefinition (default to heart rate plan)
    public var trainingPlan: TrainingPlanDefinition? {
        switch self {
        case .fiveK: return AvailablePlans.plan(for: "5k_hr")
        case .tenK: return AvailablePlans.plan(for: "10k_hr")
        case .halfMarathon: return AvailablePlans.plan(for: "half_marathon_hr")
        case .marathon: return AvailablePlans.plan(for: "marathon_hr")
        }
    }

    public var distance: Int {
        switch self {
        case .fiveK: return 5000
        case .tenK: return 10000
        case .halfMarathon: return 21097
        case .marathon: return 42195
        }
    }

    public var title: String {
        trainingPlan?.title ?? String(format: "plan.title.fallback_format", self.rawValue)
    }

    public var weeksRange: String {
        trainingPlan?.weeksRange ?? "plan.weeks_range.fallback"
    }

    public var trainingsPerWeek: String {
        trainingPlan?.trainingsPerWeek ?? "plan.trainings_per_week.fallback"
    }

    public var levels: String {
        trainingPlan?.levels ?? "plan.levels.all"
    }

    public var basedOn: String {
        trainingPlan?.basedOn ?? "plan.type.heart_rate.tagline"
    }

    public var description: String {
        trainingPlan?.description ?? ""
    }

    // New properties from TrainingPlanDefinition
    public var isPaid: Bool {
        trainingPlan?.isPaid ?? false
    }

    public var isEnabled: Bool {
        trainingPlan?.isEnabled ?? true
    }
}
