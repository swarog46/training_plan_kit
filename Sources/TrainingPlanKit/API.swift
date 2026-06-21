//
//  API.swift
//
//  The surface the package exposes. The generator and models below it stay
//  as-is from RunPlan; this file is the small, stable entry point callers
//  build against.
//

import Foundation

public enum TrainingPlanKit {
    public static let version = "0.3.0"
}

/// One placed session: the engine's role for the slot ("Long Run",
/// "Intervals", "Recovery"…) and the catalog workout chosen to fill it.
public struct GeneratedWorkout {
    public let role: String
    public let workout: Workout
}

/// Lay out `totalWeeks` of training for `config`, drawing sessions from
/// `catalog`. Returns a 1-based, week-indexed map of the sessions placed.
///
/// `adaptive` runs the week-to-week load shaping (progression, deloads,
/// taper); pass `false` for a flat template.
public func generatePlan(config: PlanConfiguration,
                         totalWeeks: Int,
                         catalog: [Workout],
                         adaptive: Bool = true) -> [Int: [GeneratedWorkout]] {
    let weeks = generatePlanV3(config: config,
                               totalWeeks: totalWeeks,
                               allWorkouts: catalog,
                               adaptive: adaptive)
    return weeks.mapValues { week in
        week.map { GeneratedWorkout(role: $0.type, workout: $0.workout) }
    }
}

/// Decode a catalog from a JSON file (an array of `Workout`).
public func loadCatalog(atPath path: String) throws -> [Workout] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try JSONDecoder().decode([Workout].self, from: data)
}

/// The bundled sample catalog — enough variety to generate real plans across
/// every distance and level, but not RunPlan's full tuned library.
public func loadSampleCatalog() -> [Workout] {
    guard let url = Bundle.module.url(forResource: "sample_catalog", withExtension: "json"),
          let data = try? Data(contentsOf: url) else {
        return []
    }
    return (try? JSONDecoder().decode([Workout].self, from: data)) ?? []
}
