//
//  C25KPlanGenerator.swift
//  TrainingPlanKit
//
//  Couch-to-5K: the classic 9-week run/walk protocol as fixed weekly
//  templates (c25k_* catalog keys), not load-driven selection. W1-4 and
//  W7-9 repeat one session across the week's 3 days; W5-6 vary by day
//  (d1/d2/d3), ending in the first continuous runs. Race day (the
//  graduation 5K) is appended by the shared engine like any race plan.
//

import Foundation

final class C25KPlanGenerator: PlanGeneratorV3 {
    static let protocolWeeks = 9

    override func buildWeek(week: Int) {
        // Shorter plans front-trim (start deeper into the protocol, like the
        // VO2 block); longer plans repeat the graduation-week run past W9.
        let offset = max(0, Self.protocolWeeks - actualWeeksToGenerate)
        let proto = min(week + offset, Self.protocolWeeks - 1) + 1  // 1-based W1...W9

        var weekWorkouts: [(type: String, workout: Workout)] = []
        for day in 0..<config.trainingDays.count {
            let key: String
            switch proto {
            case 5, 6: key = "c25k_w\(proto)d\(min(day + 1, 3))"
            default:   key = "c25k_w\(proto)"
            }
            // Direct key fetch from the raw catalog — the progression-filtered
            // pool may drop these beginner templates.
            if let workout = allWorkouts.first(where: { $0.key == key }) {
                weekWorkouts.append(("c25k", workout))
            }
        }
        workoutsByWeek[week] = weekWorkouts
    }
}
