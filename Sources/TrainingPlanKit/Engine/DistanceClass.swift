//
//  DistanceClass.swift
//  TrainingPlanKit
//
//  The distance-class seams the engine branches on, as named predicates
//  instead of scattered literals (the R23 refactor). Boundaries sit in the
//  UNPOPULATED gaps between catalog distances, so existing plans are
//  byte-identical while new distances (15K, 10mi, 30K, 50K) fall on the
//  training-correct side of each seam:
//
//    5K ─┐            ┌─ 15K/10mi ─┐        ┌─ 30K ─┐         ┌─ 50K
//    5000 10000 │ 12500 …… 21097 │ 25000 …… 42195 │ 44000 ……
//               └ longRaceClass ≥ 12500     └ marathonClass ≥ 25000
//
//  Identity checks (== 42195 etc.) stay identity where the rule really is
//  race-specific (Beg marathon exposure backstops, HM mile-repeat flavor).
//

import Foundation

extension PlanConfiguration {
    /// HM-and-up training shape — rehearsal-week cadence, peak TT weeks,
    /// endurance-first long-run policy. 15K/10-mile join deliberately:
    /// Daniels programs 15K-to-half as one band.
    public var isLongRaceClass: Bool { distance >= 12500 }

    /// Marathon-style specificity — MP-segment work, fast-finish longs,
    /// marathon volume caps. 30K/50K join: both are raced at ~MP effort.
    public var isMarathonClass: Bool { distance >= 25000 }

    /// Ultra (beyond-marathon) — time-on-feet emphasis; caps out MP heat.
    public var isUltraClass: Bool { distance >= 44000 }
}
