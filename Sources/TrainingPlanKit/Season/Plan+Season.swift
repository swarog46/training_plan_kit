//
//  Plan+Season.swift
//  TrainingPlanKit
//

import Foundation

public extension Plan {
    /// Race-day events by date. More than one means a multi-race season.
    var raceEvents: [WorkoutEvent] {
        events.filter { $0.workout.type == .race }.sorted { $0.date < $1.date }
    }

    /// The race the plan builds to — its last. Finishing it completes the plan.
    var goalRace: WorkoutEvent? { raceEvents.last }

    var isMultiRace: Bool { raceEvents.count > 1 }
}

public extension WorkoutEvent {
    /// The race pace rendered on this event (sec/km), e.g. a season race's own race-day target.
    var racePaceTarget: Int? {
        workout.intervals.lazy.compactMap { iv -> Int? in
            if case .paceTarget(let base, let rel) = iv.target, abs(rel - 1.0) < 0.001, base > 150 { return base }
            return nil
        }.first
    }
}
