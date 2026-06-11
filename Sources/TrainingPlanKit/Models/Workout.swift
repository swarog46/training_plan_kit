//
//  Workout.swift
//  RunPlan
//
//  Created by Dan Sh on 16/01/2025.
//

import Foundation

public struct Workout: Identifiable, Codable, Hashable {
    public let id: Int64
    public let title: String
    public let type: WorkoutType
    public let subtype: WorkoutSubtype
    public let trainingType: TrainingType
    public let targetType: TargetType
    public let duration: Int64
    public let distance: Int64
    public let key: String
    public let trainingLoad: Int64
    public let intervals: [WorkoutInterval]
    
    // Additional properties from JSON
    public let workRestRatio: Double
    public let workDuration: Int64
    public let restDuration: Int64
    public let workDistance: Int64
    public let restDistance: Int64
    
    public init(id: Int64, title: String, type: WorkoutType, subtype: WorkoutSubtype, trainingType: TrainingType, targetType: TargetType, duration: Int64, distance: Int64, key: String, trainingLoad: Int64, intervals: [WorkoutInterval], workRestRatio: Double, workDuration: Int64, restDuration: Int64, workDistance: Int64, restDistance: Int64) {
        self.id = id
        self.title = title
        self.type = type
        self.subtype = subtype
        self.trainingType = trainingType
        self.targetType = targetType
        self.duration = duration
        self.distance = distance
        self.key = key
        self.trainingLoad = trainingLoad
        self.intervals = intervals
        self.workRestRatio = workRestRatio
        self.workDuration = workDuration
        self.restDuration = restDuration
        self.workDistance = workDistance
        self.restDistance = restDistance
    }

    // Custom coding keys to handle snake_case in JSON
    private enum CodingKeys: String, CodingKey {
        case id, title, type, subtype, trainingType, targetType, intervals, duration, distance, key
        case trainingLoad = "training_load"
        case workRestRatio = "work_rest_ratio"
        case workDuration = "work_duration"
        case restDuration = "rest_duration"
        case workDistance = "work_distance"
        case restDistance = "rest_distance"
    }
    
    // Add Equatable and Hashable conformances
    public static func == (lhs: Workout, rhs: Workout) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.type == rhs.type
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(key)
    }
}
