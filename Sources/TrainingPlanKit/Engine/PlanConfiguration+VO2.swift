//
//  PlanConfiguration+VO2.swift
//  RunPlan
//
//  VO2-max fitness-block configs. An 8-week block routed internally as a 5K plan
//  (the 5K workout mix — VO2 intervals + tempo + threshold + easy + short long
//  runs — already matches the VO2-max focus). The only differences from a 5K
//  race plan: no race-day workout at the end (isVO2Max) and a fixed 8-week length.
//  Each delegates to the level's 5K config with isVO2Max = true.
//

import Foundation

extension PlanConfiguration {
    public static var vo2maxBeginner: PlanConfiguration {
        var c = PlanConfiguration.beginner5Default
        c.isVO2Max = true
        return c
    }

    public static var vo2maxIntermediate: PlanConfiguration {
        var c = PlanConfiguration.intermediate5Default
        c.isVO2Max = true
        return c
    }

    public static var vo2maxAdvanced: PlanConfiguration {
        var c = PlanConfiguration.advanced5Default
        c.isVO2Max = true
        return c
    }
}
