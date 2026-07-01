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
}
