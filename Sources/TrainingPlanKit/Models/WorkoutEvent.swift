//
//  WorkoutEvent.swift
//  RunPlan
//
//  Created by Dan Sh on 16/01/2025.
//

import Foundation

public struct WorkoutEvent: Identifiable, Codable, Hashable {
    public var workout: Workout // Reference to the workout template (mutable to update with actual data)
    public let id: UUID
    public let planId: UUID? // Training plan ID
    public var date: Date // Scheduled date (mutable for move)
    public var isCompleted: Bool
    public var completionDate: Date?
    public var hkWorkoutId: UUID?
    public var actualDistance: Double? // Actual distance from HealthKit in meters
    public var actualDuration: TimeInterval? // Actual duration from HealthKit in seconds

    // Move/cancel/swap
    public var isCancelled: Bool
    public var originalDate: Date? // Set when moved, stores the original scheduled date
    public var isSwapped: Bool
    public var originalWorkoutType: String? // Stores original type name before swap

    // Future adaptive load infrastructure
    public var loadScore: Double? // Per-workout training load score
    public var adjustmentReason: String? // Why this workout was adjusted
    public var adjustmentType: Int16 // 0=none, 1=increased, 2=decreased, 3=skipped-by-suggestion

    public init(workout: Workout, planId: UUID, date: Date, id: UUID = UUID()) {
        self.id = id
        self.workout = workout
        self.planId = planId
        self.date = date
        self.isCompleted = false
        self.completionDate = nil
        self.hkWorkoutId = nil
        self.actualDistance = nil
        self.actualDuration = nil
        self.isCancelled = false
        self.originalDate = nil
        self.isSwapped = false
        self.originalWorkoutType = nil
        self.loadScore = nil
        self.adjustmentReason = nil
        self.adjustmentType = 0
    }
}
