//
//  PlanDistribution.swift
//  RunPlan
//
//  Workout type distribution logic and run count tracking.
//

import Foundation

public func determineWorkoutCategory(workout: Workout) -> WorkoutCategory {
    switch workout.subtype {
    case .long, .steadyLong:
        return .longRun
    case .intervals, .pyramidIntervals, .ladderIntervals, .fartlek:
        return .interval
    case .tempo, .threshold, .speed:
        return .quality
    case .recovery:
        return .easy
    default:
        // Default to easy if we don't know the specific type
        return .easy
    }
}

// Helper function to determine workout distribution based on phase and available days
public func determineEnduranceWorkoutTypeDistribution(
    daysCount: Int,
    phase: TrainingPhase,
    weekInPhase: Int,
    weekIndex: Int,
    runnerLevel: RunnerLevel,
    distance: Int64,
    isDeloading: Bool = false
) -> RunCounts {
    var runCounts = RunCounts()
    
    // Base distribution strategy by phase
    switch phase {
    case .base:
        // Base phase focuses on building aerobic capacity

        // For 5K beginner/intermediate: no long runs (too short for 60+ min runs)
        if distance == 5000 && (runnerLevel == .beginner || runnerLevel == .intermediate) {
            runCounts.longRunsCount = 0  // No long runs for 5K
            runCounts.progressionRunsCount = 0
            runCounts.easyRunsCount = max(0, daysCount)
        }
        // For 10K beginner: long run every other week (alternating weeks)
        else if distance == 10000 && runnerLevel == .beginner {
            // Long run every other week for 10K beginner
            if weekIndex % 2 == 0 {
                runCounts.longRunsCount = 1  // BASE: only progressive, SPEED/PEAK: mix
                runCounts.progressionRunsCount = 0  // No progression run on long run weeks
            } else {
                runCounts.longRunsCount = 0  // No long run this week
                runCounts.progressionRunsCount = 1  // Add progression run instead
            }

            if daysCount > 2 {
                runCounts.intervalRunsCount = 1
            }
        }
        // For 21K+ beginners: 1 long + 1 progression + 1 easy
        else if distance >= 21000 && runnerLevel == .beginner {
            runCounts.longRunsCount = 1  // Will allow all long run types
            runCounts.progressionRunsCount = 1  // One progression run
            runCounts.easyRunsCount = 1  // One easy run to fill the third slot
        } else {
            runCounts.longRunsCount = 1
            runCounts.easyRunsCount = max(1, daysCount - 2)

            if daysCount > 2 {
                runCounts.intervalRunsCount = 1
            }

            if daysCount > 4 {
                runCounts.progressionRunsCount += 1
            }

            if daysCount > 5 {
                runCounts.progressionRunsCount += 1
            }
        }
        
    case .speed:
        // Speed phase increases quality workouts

        // For 5K beginner/intermediate: no long runs (too short for 60+ min runs)
        if distance == 5000 && (runnerLevel == .beginner || runnerLevel == .intermediate) {
            runCounts.longRunsCount = 0  // No long runs for 5K
            runCounts.progressionRunsCount = 0
        }
        // For 10K beginner: long run every other week (alternating)
        else if distance == 10000 && runnerLevel == .beginner {
            if weekIndex % 2 == 0 {
                runCounts.longRunsCount = 1  // Long run on even weeks
            } else {
                runCounts.longRunsCount = 0  // No long run on odd weeks
            }
        }
        // For 21K+ beginners: regular long runs every week
        else {
            runCounts.longRunsCount = 1  // 21K: all types allowed
        }

        runCounts.intervalRunsCount = 1 // min(1, max(0, daysCount - 2))

        if weekInPhase % 3 == 0 {
            runCounts.intervalRunsCount = 0
            runCounts.ultraIntervalRunsCount = 1
        }

        if runnerLevel == .beginner {
            while runCounts.ultraIntervalRunsCount + runCounts.intervalRunsCount + runCounts.qualityRunsCount + runCounts.fartlekRunsCount < daysCount - 2 {
                runCounts.incrementRandomQualityOrIntervalRunCount()
            }

            // For 10K+ beginners: prefer progressive runs over easy runs
            if distance >= 10000 {
                runCounts.progressionRunsCount = 1
            } else if distance == 5000 {
                // 5K beginners: use easy runs to fill remaining slots
                runCounts.easyRunsCount = max(0, daysCount - runCounts.progressionRunsCount - 1)
            } else {
                runCounts.easyRunsCount = 1
            }
        } else if runnerLevel == .intermediate {
            // 5K intermediate already has progressive run handled above
            if distance != 5000 || runCounts.progressionRunsCount == 0 {
                runCounts.progressionRunsCount = 1
            }

            // Intermediate/advanced get more quality
            while runCounts.ultraIntervalRunsCount + runCounts.intervalRunsCount + runCounts.qualityRunsCount + runCounts.fartlekRunsCount < daysCount - 3 {
                runCounts.incrementRandomQualityOrIntervalRunCount()
            }
            runCounts.incrementRandomNonIntervalRunCount() // max(0, daysCount - 3 - runCounts.fartlekRunsCount)
        } else if runnerLevel == .advanced {
            runCounts.progressionRunsCount = 2

            // Intermediate/advanced get more quality
            while runCounts.ultraIntervalRunsCount + runCounts.intervalRunsCount + runCounts.qualityRunsCount + runCounts.fartlekRunsCount < daysCount - 3 {
                runCounts.incrementRandomQualityOrIntervalRunCount()
            }
            
//            runCounts.incrementRandomNonIntervalRunCount() // max(0, daysCount - 3 - runCounts.fartlekRunsCount)
        }
        
    case .peak:
        // Peak phase has highest intensity

        // For 5K beginner/intermediate: no long runs (too short for 60+ min runs)
        if distance == 5000 && (runnerLevel == .beginner || runnerLevel == .intermediate) {
            runCounts.longRunsCount = 0  // No long runs for 5K
            runCounts.progressionRunsCount = 0
        }
        // For 10K beginner: long run every other week (alternating)
        else if distance == 10000 && runnerLevel == .beginner {
            if weekIndex % 2 == 0 {
                runCounts.longRunsCount = 1  // Long run on even weeks
            } else {
                runCounts.longRunsCount = 0  // No long run on odd weeks
            }
        }
        // For 21K+ beginners: regular long runs every week
        else {
            runCounts.longRunsCount = 1  // 21K: all types allowed
        }

        runCounts.qualityRunsCount = 1

        // TODO: periodically add surprise weeks when there is a hardcore workout + 2 easy

        if runnerLevel == .beginner {
            while runCounts.ultraIntervalRunsCount + runCounts.intervalRunsCount + runCounts.qualityRunsCount + runCounts.fartlekRunsCount < daysCount - 2 {
                runCounts.incrementRandomIntervalRunCount()
            }

            if weekInPhase % 4 == 0 && runCounts.intervalRunsCount > 0 {
                runCounts.intervalRunsCount -= 1
                runCounts.ultraIntervalRunsCount = 1
            }

            // For 10K+ beginners: prefer progressive runs over easy runs
            if distance >= 10000 {
                runCounts.progressionRunsCount += 1
            } else if distance == 5000 {
                // 5K beginners: use easy runs to fill remaining slots
                runCounts.easyRunsCount = max(0, daysCount - runCounts.progressionRunsCount - 1)
            } else {
                runCounts.incrementRandomNonIntervalRunCount()
            }
        } else if runnerLevel == .intermediate {
            // Intermediate/advanced get more quality and progression
            runCounts.incrementRandomIntervalRunCount()

            if weekInPhase % 4 == 0 && runCounts.intervalRunsCount > 0 {
                runCounts.intervalRunsCount -= 1
                runCounts.ultraIntervalRunsCount = 1
            }

//            runCounts.easyRunsCount = 1

            // 5K intermediate already has progressive run handled above
            if distance != 5000 || runCounts.progressionRunsCount == 0 {
                runCounts.progressionRunsCount = min(1, daysCount - runCounts.progressionRunsCount)
            }
//            runCounts.easyRunsCount = max(0, daysCount - 3 - runCounts.progressionRunsCount)
        } else if runnerLevel == .advanced {
            // Intermediate/advanced get more quality and progression
            runCounts.incrementRandomIntervalRunCount()
            
            if weekInPhase % 4 == 0 && runCounts.intervalRunsCount > 0 {
                runCounts.intervalRunsCount -= 1
                runCounts.ultraIntervalRunsCount = 1
            }
            
            runCounts.qualityRunsCount = min(1, max(0, daysCount - 4))
//            runCounts.easyRunsCount = 1
            
            runCounts.progressionRunsCount = min(1, max(0, daysCount - runCounts.totalWorkoutCount()))
        }
        
    case .taper:
        // Taper phase reduces volume but maintains some quality
        // First week of taper maintains quality, second week reduces it
        if weekInPhase == 0 {
            runCounts.intervalRunsCount = 1
            runCounts.longRunsCount = 1

            while runCounts.intervalRunsCount + runCounts.fartlekRunsCount + runCounts.qualityRunsCount < daysCount - 2 {
                runCounts.incrementRandomQualityOrIntervalRunCount()
            }
            runCounts.incrementRandomNonIntervalRunCount()
        } else {
            runCounts.longRunsCount = 1
            runCounts.progressionRunsCount = 1
            
//            runCounts.intervalRunsCount = 1
            runCounts.incrementRandomQualityOrIntervalRunCount()
//            runCounts.incrementRandomIntervalRunCount()
            
            // Later taper weeks have fewer quality sessions
            while runCounts.progressionRunsCount + runCounts.easyRunsCount < daysCount - 3 {
                runCounts.incrementRandomNonIntervalRunCount()
            }
        }
        
    case .race:
        runCounts.easyRunsCount = 1
        runCounts.intervalRunsCount = 1
        // Race week - only easy runs
        while runCounts.progressionRunsCount + runCounts.easyRunsCount < daysCount - 1 {
            runCounts.incrementRandomNonIntervalRunCount()
        }
    }
    
    // Adjust counts to ensure we don't exceed available days
    let totalWorkouts = runCounts.totalWorkoutCount()
    if totalWorkouts > daysCount {
        // Reduce workouts to fit available days (prioritize quality and long runs)
        let excessWorkouts = totalWorkouts - daysCount
        
        // Reduce easy runs first
        let easyRunsToRemove = min(runCounts.easyRunsCount, excessWorkouts)
        runCounts.easyRunsCount -= easyRunsToRemove
        
        // If we still have too many, reduce progression runs
        if easyRunsToRemove < excessWorkouts {
            let progressionRunsToRemove = min(runCounts.progressionRunsCount, excessWorkouts - easyRunsToRemove)
            runCounts.progressionRunsCount -= progressionRunsToRemove
        }
    } else if totalWorkouts < daysCount {
        // Add more easy runs to fill available days
        runCounts.easyRunsCount += (daysCount - totalWorkouts)
    }
    
    return runCounts
}

// Helper function to determine workout distribution based on phase and available days
public func determineSpeedWorkoutTypeDistribution(
    daysCount: Int,
    phase: TrainingPhase,
    weekInPhase: Int,
    runnerLevel: RunnerLevel,
    isDeloading: Bool = false
) -> RunCounts {
    var runCounts = RunCounts()
    
    // Base distribution strategy by phase
    switch phase {
    case .base:
        // Base phase focuses on building aerobic capacity with more easy runs
        runCounts.longRunsCount = 1
        runCounts.progressionRunsCount = 1

        if daysCount > 2 {
            runCounts.intervalRunsCount = 1
        }
        
        // TODO: this >4 looks strange. are we missing something?
        if daysCount > 4 {
            runCounts.progressionRunsCount += 1
        }
        
        if daysCount > 5 {
            runCounts.progressionRunsCount += 1
        }
        
    case .speed:
        // Speed phase increases quality workouts
        runCounts.progressionRunsCount = 1
        runCounts.intervalRunsCount = 1 // min(1, max(0, daysCount - 2))

        if weekInPhase % 3 == 0 {
            runCounts.intervalRunsCount = 0
            runCounts.ultraIntervalRunsCount = 1
        }
        
        if runnerLevel == .beginner {
            while runCounts.totalWorkoutCount() < daysCount {
                runCounts.incrementRandomIntervalRunCount()
            }

        } else if runnerLevel == .intermediate {
            runCounts.progressionRunsCount = 1

            // Intermediate/advanced get more quality
            while runCounts.totalWorkoutCount() < daysCount {
                runCounts.incrementRandomQualityOrIntervalRunCount()
            }
//            runCounts.incrementRandomNonIntervalRunCount() // max(0, daysCount - 3 - runCounts.fartlekRunsCount)
        } else if runnerLevel == .advanced {
            runCounts.progressionRunsCount += 1

            // Intermediate/advanced get more quality
            while runCounts.totalWorkoutCount() < daysCount {
                runCounts.incrementRandomQualityOrIntervalRunCount()
            }
            
//            runCounts.incrementRandomNonIntervalRunCount() // max(0, daysCount - 3 - runCounts.fartlekRunsCount)
        }
        
    case .peak:
        // Peak phase has highest intensity
        runCounts.progressionRunsCount = 1
        runCounts.qualityRunsCount = 1
                
        if runnerLevel == .beginner {
            while runCounts.totalWorkoutCount() < daysCount {
                runCounts.incrementRandomIntervalRunCount()
            }
            
            if weekInPhase % 3 == 0 && runCounts.intervalRunsCount > 0 {
                runCounts.intervalRunsCount -= 1
                runCounts.ultraIntervalRunsCount = 1
            }
        } else if runnerLevel == .intermediate {
            // Intermediate/advanced get more quality and progression
            runCounts.incrementRandomIntervalRunCount()
            
            if weekInPhase % 4 == 0 && runCounts.intervalRunsCount > 0 {
                runCounts.intervalRunsCount -= 1
                runCounts.ultraIntervalRunsCount = 1
            }
            
            runCounts.progressionRunsCount += (daysCount - runCounts.totalWorkoutCount())
//            runCounts.easyRunsCount = max(0, daysCount - 3 - runCounts.progressionRunsCount)
        } else if runnerLevel == .advanced {
            // Intermediate/advanced get more quality and progression
            runCounts.incrementRandomIntervalRunCount()
            runCounts.incrementRandomIntervalRunCount()

            if weekInPhase % 4 == 0 && runCounts.intervalRunsCount > 0 {
                runCounts.intervalRunsCount -= 1
                runCounts.ultraIntervalRunsCount = 1
            }

            runCounts.progressionRunsCount += (daysCount - runCounts.totalWorkoutCount())
        }
        
    case .taper:
        // Taper phase reduces volume but maintains some quality
        // First week of taper maintains quality, second week reduces it
        if weekInPhase == 0 {
            runCounts.intervalRunsCount = 1
            runCounts.progressionRunsCount = 1

            while runCounts.totalWorkoutCount() < daysCount {
                runCounts.incrementRandomQualityOrIntervalRunCount()
            }
            runCounts.incrementRandomNonIntervalRunCount()
        } else {
            runCounts.progressionRunsCount = 2
            
//            runCounts.intervalRunsCount = 1
            runCounts.incrementRandomQualityOrIntervalRunCount()
//            runCounts.incrementRandomIntervalRunCount()
            
            // Later taper weeks have fewer quality sessions
            while runCounts.totalWorkoutCount() < daysCount {
                runCounts.incrementRandomNonIntervalRunCount()
            }
        }
        
    case .race:
        runCounts.progressionRunsCount = 1
        runCounts.intervalRunsCount = 1
        // Race week - only easy runs
        while runCounts.totalWorkoutCount() < daysCount {
            runCounts.incrementRandomNonIntervalRunCount()
        }
    }
    
    // Adjust counts to ensure we don't exceed available days
    let totalWorkouts = runCounts.totalWorkoutCount()
    if totalWorkouts > daysCount {
        // Reduce workouts to fit available days (prioritize quality and long runs)
        let excessWorkouts = totalWorkouts - daysCount
        
        // Reduce easy runs first
        let easyRunsToRemove = min(runCounts.easyRunsCount, excessWorkouts)
        runCounts.easyRunsCount -= easyRunsToRemove
        
        // If we still have too many, reduce progression runs
        if easyRunsToRemove < excessWorkouts {
            let progressionRunsToRemove = min(runCounts.progressionRunsCount, excessWorkouts - easyRunsToRemove)
            runCounts.progressionRunsCount -= progressionRunsToRemove
        }
    } else if totalWorkouts < daysCount {
        // Add more easy runs to fill available days
        runCounts.easyRunsCount += (daysCount - totalWorkouts)
    }
    
    return runCounts
}

// Struct to hold the run counts
public struct RunCounts {
    public var easyRunsCount: Int
    public var intervalRunsCount: Int
    public var ultraIntervalRunsCount: Int
    public var qualityRunsCount: Int
    public var progressionRunsCount: Int
    public var recoveryRunsCount: Int
    public var longRunsCount: Int
    public var fartlekRunsCount: Int
    
    // Initialize with default values
    public init(easyRunsCount: Int = 0,
         intervalRunsCount: Int = 0,
         qualityRunsCount: Int = 0,
         progressionRuns: Int = 0,
         recoveryRuns: Int = 0,
         longRunsCount: Int = 0,
         fartlekRunsCount: Int = 0) {
        self.easyRunsCount = easyRunsCount
        self.intervalRunsCount = intervalRunsCount
        self.qualityRunsCount = qualityRunsCount
        self.progressionRunsCount = progressionRuns
        self.recoveryRunsCount = recoveryRuns
        self.longRunsCount = longRunsCount
        self.fartlekRunsCount = fartlekRunsCount
        
        self.ultraIntervalRunsCount = 0
    }
    
    // Function to increment a random run count
    mutating func incrementRandomNonIntervalRunCount() {
        // Select a random key path
        let randomIndex = Int.random(in: 0..<12)
        if randomIndex > 4 {
            progressionRunsCount += 1
        }
        else {
            easyRunsCount += 1
        }
    }
    
    // Function to increment a random run count
    mutating func incrementRandomQualityOrIntervalRunCount() {
        let randomIndex = Int.random(in: 0..<20)

        if randomIndex < 3 {
            fartlekRunsCount += 1
        }
        else if randomIndex < 10 {
            qualityRunsCount += 1
        }
        else if randomIndex <= 20 {
            intervalRunsCount += 1
        }
    }
    
    // Function to increment a random run count
    mutating func incrementRandomIntervalRunCount() {
        let randomIndex = Int.random(in: 0..<15)

        if randomIndex < 5 {
            fartlekRunsCount += 1
        }
        else if randomIndex <= 15 {
            intervalRunsCount += 1
        }
    }
}


// Helper to get total workout count
extension RunCounts {
    public func totalWorkoutCount() -> Int {
        return easyRunsCount + intervalRunsCount + qualityRunsCount +
        progressionRunsCount + recoveryRunsCount + longRunsCount + fartlekRunsCount + ultraIntervalRunsCount
    }
    
    // Helper to get only quality workout count (excluding easy, recovery, long)
    public func totalQualityCount() -> Int {
        return intervalRunsCount + qualityRunsCount + progressionRunsCount + fartlekRunsCount + ultraIntervalRunsCount
    }
    
    // Helper to randomly select quality workout type
    mutating func setRandomQualityWorkout() {
        // Reset all quality workouts
        intervalRunsCount = 0
        qualityRunsCount = 0
        progressionRunsCount = 0
        fartlekRunsCount = 0
        
        // Randomly select one type
        let random = Int.random(in: 0..<4)
        switch random {
        case 0:
            intervalRunsCount = 1
        case 1:
            qualityRunsCount = 1
        case 2:
            progressionRunsCount = 1
        default:
            fartlekRunsCount = 1
        }
    }
}
