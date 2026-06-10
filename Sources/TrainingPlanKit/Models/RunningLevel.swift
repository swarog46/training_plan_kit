//
//  RunningLevel.swift
//  RunPlan
//
//  UI-facing running level enum with display names and descriptions.
//


// Reference to the race distance enum defined in PlansView.swift
public enum RunningLevel: String, CaseIterable, Identifiable {
    case beginner = "Beginner"
    case intermediate = "Intermediate"
    case advanced = "Advanced"

    public var id: String { self.rawValue }

    /// Returns the number of training days per week the plan actually
    /// generates for the given (level, distance). Used by the plan-setup
    /// UI to advise users on what they're signing up for. MUST match the
    /// `trainingDays.count` in the corresponding `PlanConfiguration` —
    /// drift here means the UI lies to the user about their plan.
    ///
    /// Sourced from each tier's `trainingDays` array in PlanConfiguration.swift.
    /// If you change a plan's training-days, update this function too.
    public func recommendedTrainingsPerWeek(for distance: Int) -> Int {
        switch distance {

        case 0..<7500: // 5K
            switch self {
            case .beginner: return 3      // Higdon Novice 5K / Couch-to-5K
            case .intermediate: return 4  // Pfitz/Daniels Int 5K (was 3)
            case .advanced: return 5      // Daniels Adv 5K Phase II (was 4)
            }
        case 7500..<15000: // 10K
            switch self {
            case .beginner: return 3      // Higdon Novice 10K
            case .intermediate: return 5  // Pfitz Int 10K (was 3 — undercounted by 2)
            case .advanced: return 5      // Daniels Adv 10K (was 4)
            }
        case 15000..<30000: // 21K
            switch self {
            case .beginner: return 4      // Pfitz "Just Finish" HM (was 3)
            case .intermediate: return 5  // Pfitz 12-wk HM (was 4)
            case .advanced: return 5      // Pfitz 12/47 HM
            }
        default: // Marathon
            switch self {
            case .beginner: return 4      // Higdon Novice 1
            case .intermediate: return 5  // Pfitz 18/55
            case .advanced: return 5      // Pfitz 18/70 (was 6 — overstated by 1!)
            }
        }
    }

    /// Mirror conversion to the engine-side `RunnerLevel` enum (which
    /// also has a `.competitive` case — RunningLevel doesn't because the
    /// level picker is hidden for competitive plans).
    public var toRunnerLevel: RunnerLevel {
        switch self {
        case .beginner:     return .beginner
        case .intermediate: return .intermediate
        case .advanced:     return .advanced
        }
    }

    public var toDifficultyLevel: DifficultyLevel {
        switch self {
        case .beginner: return .beginner
        case .intermediate: return .intermediate
        case .advanced: return .advanced
        }
    }
}

// Extension to add descriptions for RunningLevel
extension RunningLevel {
    public var description: String {
        switch self {
        case .beginner:
            return "Perfect if you're new to running or getting back after a break. Focuses on consistency, building endurance, and injury prevention with plenty of recovery."
        case .intermediate:
            return "Ideal for runners with some experience who want to improve speed and endurance. Includes more structured workouts like tempos and intervals."
        case .advanced:
            return "For seasoned runners aiming to race their fastest. High volume, focused intensity, and minimal rest days to push your limits and peak on race day."
        }
    }
}

