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

    /// Transient render hint: this week is a BUILD-phase deload, so the pace-progression
    /// pass clamps its long run to ~0.80x the prior non-deload delivered long run.
    /// Not persisted — excluded from Codable so existing data decodes unchanged.
    public var isDeloadWeek: Bool = false

    /// Transient: 0-based plan week index, so the deload clamp can group events by week
    /// (one long run per week) instead of mis-tracking a short mid-week run. Not persisted.
    public var planWeekIndex: Int = -1

    /// Transient: this week is in the TAPER/race phase → the render suppresses the km-floor
    /// so the long run declines instead of inflating to floor distance. Not persisted.
    public var isTaperWeek: Bool = false

    private enum CodingKeys: String, CodingKey {
        case workout, id, planId, date, isCompleted, completionDate, hkWorkoutId
        case actualDistance, actualDuration, isCancelled, originalDate, isSwapped
        case originalWorkoutType, loadScore, adjustmentReason, adjustmentType
    }

    public init(workout: Workout, id: UUID, planId: UUID?, date: Date, isCompleted: Bool, completionDate: Date?, hkWorkoutId: UUID?, actualDistance: Double?, actualDuration: TimeInterval?, isCancelled: Bool, originalDate: Date?, isSwapped: Bool, originalWorkoutType: String?, loadScore: Double?, adjustmentReason: String?, adjustmentType: Int16) {
        self.workout = workout
        self.id = id
        self.planId = planId
        self.date = date
        self.isCompleted = isCompleted
        self.completionDate = completionDate
        self.hkWorkoutId = hkWorkoutId
        self.actualDistance = actualDistance
        self.actualDuration = actualDuration
        self.isCancelled = isCancelled
        self.originalDate = originalDate
        self.isSwapped = isSwapped
        self.originalWorkoutType = originalWorkoutType
        self.loadScore = loadScore
        self.adjustmentReason = adjustmentReason
        self.adjustmentType = adjustmentType
    }

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
