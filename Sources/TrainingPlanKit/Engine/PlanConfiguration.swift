//
//  PlanConfiguration.swift
//  RunPlan
//
//  Plan configuration types, enums, and default configurations.
//

import Foundation

// Updated PlanConfiguration struct to support flexible duration

// Enum to categorize workout types for our distribution algorithm
public enum WorkoutCategory {
    case easy
    case interval
    case quality
    case longRun
}

public enum RunnerLevel: String, Codable {
    case beginner
    case intermediate
    case advanced
    case competitive
}

public enum TrainingPhase: String {
    case base
    case speed
    case peak
    case taper
    case race

    /// User-facing phase name. Maintenance plans repurpose the phase slots
    /// (speed = the ongoing "maintenance" block, taper = a recovery week), and
    /// their volume holds/rises through the end by design — so the final phase
    /// must NOT read "taper". The rawValue is left untouched (it keys the
    /// phase-duration dictionary in the engine); this only affects display.
    public func displayName(isMaintenance: Bool) -> String {
        guard isMaintenance else { return rawValue }
        switch self {
        case .speed:  return "maintenance"
        case .taper:  return "recovery"
        default:      return rawValue
        }
    }
}

/// Per-plan volume policy: the load-ramp + starting-duration knobs that define a
/// plan's training volume. Split out of PlanConfiguration so each plan's volume is
/// tuned and guarded in isolation (see the volume-matrix test) without reaching
/// into shared generator logic or other plans.
public struct VolumeProfile {
    /// Starting weekly training-load anchor — each plan declares its own value
    /// (level base × distance shaping, all folded in) instead of the generator
    /// switching on level/distance. The competitive plan-length down-scaling is
    /// the one runtime piece (see loadScaleBaselineWeeks).
    public let baseLoad: Double
    /// nil = load/duration do NOT scale with plan length. Else: for plans longer
    /// than this many weeks, scale both down by baseline/totalWeeks (competitive
    /// "longer plan ⇒ less fit at W1 ⇒ start lower"). Keeps the generator from
    /// asking "is this competitive?".
    public let loadScaleBaselineWeeks: Int?
    public let weeklyLoadIncreasePercent: ClosedRange<Double>
    public let phaseFinishDeloadPercent: ClosedRange<Double>
    public let taperDeloadPercent: Double
    public let initialWeeklyDuration: Int
    public let initialLongRunDuration: ClosedRange<Int>
    /// Longest-run cap (minutes) — each plan declares its own ceiling.
    public let maxLongRunMinutes: Int
    /// Long-run duration ramp (base → speed → peak → taper, minutes). nil = no
    /// progressive long run (5K / maintenance).
    public let longRunProgression: (base: Int, speed: Int, peak: Int, taper: Int)?
    public init(weeklyLoadIncreasePercent: ClosedRange<Double>, phaseFinishDeloadPercent: ClosedRange<Double>, taperDeloadPercent: Double, initialWeeklyDuration: Int, initialLongRunDuration: ClosedRange<Int>, maxLongRunMinutes: Int = 90, longRunProgression: (base: Int, speed: Int, peak: Int, taper: Int)? = nil, baseLoad: Double = 8000, loadScaleBaselineWeeks: Int? = nil) {
        self.weeklyLoadIncreasePercent = weeklyLoadIncreasePercent
        self.phaseFinishDeloadPercent = phaseFinishDeloadPercent
        self.taperDeloadPercent = taperDeloadPercent
        self.initialWeeklyDuration = initialWeeklyDuration
        self.initialLongRunDuration = initialLongRunDuration
        self.maxLongRunMinutes = maxLongRunMinutes
        self.longRunProgression = longRunProgression
        self.baseLoad = baseLoad
        self.loadScaleBaselineWeeks = loadScaleBaselineWeeks
    }
}

public struct PlanConfiguration {
    // Race details
    public let raceDate: Date
    public let runnerLevel: RunnerLevel
    public let distance: Int64
    // True for the VO2 max fitness block — engine still treats distance
    // as 5000 (5K-style workout selection) but skips race-day creation,
    // and Plan storage uses the .vo2max sentinel for disambiguation.
    public var isVO2Max: Bool = false

    // Phase duration ratios (will be used to calculate actual duration)
    public let basePhaseRatio: Double  // e.g., 0.25 = 25% of total training period
    public let speedPhaseRatio: Double // e.g., 0.25 = 25% of total training period
    public let peakPhaseRatio: Double  // e.g., 0.40 = 40% of total training period
    public let taperPhaseRatio: Double // e.g., 0.10 = 10% of total training period
    
    // Minimum weeks for each phase (to ensure proper training stimulus)
    public let minBasePhaseWeeks: Int
    public let minSpeedPhaseWeeks: Int
    public let minPeakPhaseWeeks: Int
    public let minTaperPhaseWeeks: Int
    
    // Default training days (0 = Sunday, 1 = Monday, ..., 6 = Saturday)
    public var trainingDays: [Int]
    public var longestWorkoutDay: Int
    public var useSeparateDayForLongRun: Bool = true

    // Volume policy (load ramp + starting durations), grouped so each plan's
    // volume is tuned and guarded in isolation. See VolumeProfile.
    public let volume: VolumeProfile
    public var weeklyLoadIncreasePercent: ClosedRange<Double> { volume.weeklyLoadIncreasePercent }
    public var phaseFinishDeloadPercent: ClosedRange<Double> { volume.phaseFinishDeloadPercent }
    public var taperDeloadPercent: Double { volume.taperDeloadPercent }
    public var initialWeeklyDuration: Int { volume.initialWeeklyDuration }
    public var initialLongRunDuration: ClosedRange<Int> { volume.initialLongRunDuration }
    public var baseLoad: Double { volume.baseLoad }
    public var loadScaleBaselineWeeks: Int? { volume.loadScaleBaselineWeeks }

    // Long-run shape is declared per-plan in each config's VolumeProfile — no
    // shared per-level switch. These just forward to it.
    public var maxLongRunMinutes: Int { volume.maxLongRunMinutes }
    public var longRunProgression: (base: Int, speed: Int, peak: Int, taper: Int)? { volume.longRunProgression }

    // Workout type balance (percentages should sum to 100)
    public let easyRunsPercent: Double = 40
    public let intervalRunsPercent: Double = 20
    public let qualityRunsPercent: Double = 10
    public let longRunsPercent: Double = 30

    // ========================================================================
    // LOCKED DAY-COUNT MATRIX — training days/week per (level × distance).
    // This is a deliberate design choice set by Q. Days/week + load DEFINE the
    // plan; running below classic-plan (Higdon/Pfitz/Daniels) volume is
    // acceptable and intentional. DO NOT change any day count — or "upgrade" a
    // plan to more days because a textbook prescribes more — without an explicit
    // request from Q. Pinned by test_plans.py → TIER_DAYS.
    //
    //              5K    10K   21K   42K
    //   Beginner    2     2     3     4
    //   Intermed    3     3     4     4
    //   Advanced    4     4     5     5
    // ========================================================================

    // Function to calculate phase durations based on total available weeks
    public func calculatePhaseDurations(totalWeeks: Int) -> (base: Int, speed: Int, peak: Int, taper: Int) {
        // Calculate ideal durations based on ratios
        let idealBaseWeeks = Int(Double(totalWeeks) * basePhaseRatio)
        let idealSpeedWeeks = Int(Double(totalWeeks) * speedPhaseRatio)
        let idealPeakWeeks = Int(Double(totalWeeks) * peakPhaseRatio)
        let idealTaperWeeks = Int(Double(totalWeeks) * taperPhaseRatio)
        
        // Ensure minimum durations are met
        var baseWeeks = max(idealBaseWeeks, minBasePhaseWeeks)
        var speedWeeks = max(idealSpeedWeeks, minSpeedPhaseWeeks)
        var peakWeeks = max(idealPeakWeeks, minPeakPhaseWeeks)
        var taperWeeks = max(idealTaperWeeks, minTaperPhaseWeeks)

        // Marathon taper floor: 3-week ramp-down (Pfitzinger). The long run
        // peaks at the last PEAK week and only steps down in taper, so a 2-week
        // taper lands the peak long run too close (2 weeks out) to absorb.
        // Half/shorter keep shorter tapers (less volume to shed).
        if distance >= 30000 {
            taperWeeks = max(taperWeeks, 3)
        }

        // Calculate total of all phases after applying minimums
        let totalPlannedWeeks = baseWeeks + speedWeeks + peakWeeks + taperWeeks
        
        // If total planned weeks exceeds available weeks, we need to adjust
        if totalPlannedWeeks > totalWeeks {
            // Calculate how many weeks we need to trim
            let excessWeeks = totalPlannedWeeks - totalWeeks
            
            // Trim weeks based on priority (taper is least flexible, then peak, then speed, then base)
            // We'll try to maintain the taper duration as it's critical for race performance
            let weeksToTrimFromBase = min(max(0, baseWeeks - minBasePhaseWeeks), excessWeeks)
            baseWeeks -= weeksToTrimFromBase
            
            let remainingExcess = excessWeeks - weeksToTrimFromBase
            if remainingExcess > 0 {
                let weeksToTrimFromSpeed = min(max(0, speedWeeks - minSpeedPhaseWeeks), remainingExcess)
                speedWeeks -= weeksToTrimFromSpeed
                
                let stillRemainingExcess = remainingExcess - weeksToTrimFromSpeed
                if stillRemainingExcess > 0 {
                    let weeksToTrimFromPeak = min(max(0, peakWeeks - minPeakPhaseWeeks), stillRemainingExcess)
                    peakWeeks -= weeksToTrimFromPeak
                    
                    let finalRemainingExcess = stillRemainingExcess - weeksToTrimFromPeak
                    if finalRemainingExcess > 0 {
                        // Last resort: trim from taper (try to keep at least 1 week)
                        taperWeeks = max(1, taperWeeks - finalRemainingExcess)
                    }
                }
            }
        } else if totalPlannedWeeks < totalWeeks {
            // If we have extra weeks, distribute them proportionally
            let extraWeeks = totalWeeks - totalPlannedWeeks
            
            // Distribute extra weeks according to ratios
            let extraBaseWeeks = Int(Double(extraWeeks) * basePhaseRatio)
            let extraSpeedWeeks = Int(Double(extraWeeks) * speedPhaseRatio)
            let extraPeakWeeks = Int(Double(extraWeeks) * peakPhaseRatio)
            let extraTaperWeeks = extraWeeks - extraBaseWeeks - extraSpeedWeeks - extraPeakWeeks
            
            baseWeeks += extraBaseWeeks
            speedWeeks += extraSpeedWeeks
            peakWeeks += extraPeakWeeks
            taperWeeks += extraTaperWeeks
        }
        
        return (baseWeeks, speedWeeks, peakWeeks, taperWeeks)
    }

    // Calculate the recommended minimum weeks for this plan configuration
    public func recommendedWeeks() -> Int {
        return minBasePhaseWeeks + minSpeedPhaseWeeks + minPeakPhaseWeeks + minTaperPhaseWeeks
    }
}

// MARK: - Accessible ("real life") tier
// Lighter, more sustainable variants of the textbook plans above:
// fewer days/week, gentler beginner phase mix. SAME periodization
// structure (base->speed->peak->taper, deloads, taper). The textbook
// configs above are UNCHANGED; these are an additive, opt-in tier.
// 3 cells (Adv 21K, Beg 42K, Adv 42K) are unchanged from textbook and
// alias it directly. See articles/ACCESSIBLE_TIER_NOTES.md.
extension PlanConfiguration {
}

// MARK: - Tier switch (accessible vs textbook)

extension PlanConfiguration {
    /// Master switch: which non-competitive plan set the app generates.
    /// `true` → accessible tier (fewer days/week, ~72-90% textbook load, ships
    /// today); `false` → textbook tier (Higdon / Pfitzinger / Daniels). Flip
    /// this one value to switch the whole app — both selectors resolve through
    /// `raceConfig` below. Competitive/maintenance/VO2 are routed separately.
    public static var shipAccessibleTier = true

    /// Resolve the non-competitive (5K / 10K / 21K / 42K) config for a runner
    /// level + race distance, honoring `shipAccessibleTier`. Single source of
    /// truth for non-competitive plan selection.
    public static func raceConfig(level: RunnerLevel, distanceMeters: Int) -> PlanConfiguration {
        let acc = shipAccessibleTier
        switch distanceMeters {
        case 0..<7500: // 5K
            switch level {
            case .beginner:     return acc ? accessibleBeginner5Default     : beginner5Default
            case .intermediate: return acc ? accessibleIntermediate5Default : intermediate5Default
            default:            return acc ? accessibleAdvanced5Default      : advanced5Default
            }
        case 7500..<15000: // 10K
            switch level {
            case .beginner:     return acc ? accessibleBeginner10Default     : beginner10Default
            case .intermediate: return acc ? accessibleIntermediate10Default : intermediate10Default
            default:            return acc ? accessibleAdvanced10Default      : advanced10Default
            }
        case 15000..<30000: // 21K
            switch level {
            case .beginner:     return acc ? accessibleBeginner21Default     : beginner21Default
            case .intermediate: return acc ? accessibleIntermediate21Default : intermediate21Default
            default:            return acc ? accessibleAdvanced21Default      : advanced21Default
            }
        default: // Marathon
            switch level {
            case .beginner:     return acc ? accessibleBeginner42Default     : beginner42Default
            case .intermediate: return acc ? accessibleIntermediate42Default : intermediate42Default
            default:            return acc ? accessibleAdvanced42Default      : advanced42Default
            }
        }
    }
}

extension DifficultyLevel {
    /// Map the stored difficulty level to the engine's `RunnerLevel`.
    public var toRunnerLevel: RunnerLevel {
        switch self {
        case .beginner:     return .beginner
        case .intermediate: return .intermediate
        case .advanced:     return .advanced
        case .competitive:  return .competitive
        }
    }
}
