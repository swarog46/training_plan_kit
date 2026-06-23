//
//  CompetitiveGate.swift
//  RunPlan
//
//  Single source of truth for "can this runner pick the Sub-3:00 Marathon /
//  Sub-1:30 Half plan?" — shared by the iOS plan-setup screen and the
//  regression tests (via plan_debug), so they can't disagree.
//
//  Decision policy (locked with the user 2026-06-06). Compare to the
//  goal-DERIVED required VDOT, never a hardcoded number, so it works for any
//  (distance, goalTime) pair:
//    gap = VDOT.from(distance, goalTime) - currentVDOT
//    gap ≤ 0     →  .clear              (fitness already meets/exceeds goal)
//    0 < gap ≤ 4 →  .buildBand(weeks)   (~4 weeks per Daniels point closes it)
//    gap > 4     →  .blocked(time)      (not realistic this cycle; use standard plan)
//

import Foundation

public enum CompetitiveGateState: Equatable {
    /// Runner already at goal fitness — no gating UI shown.
    case clear
    /// Runner can reach goal fitness with `recommendedWeeks` of training.
    /// UI shows a banner suggesting the user move their race date to give
    /// themselves at least that many weeks, but does NOT block plan creation.
    case buildBand(recommendedWeeks: Int)
    /// Runner is too far from goal fitness for this plan. UI shows a banner
    /// with the runner's VDOT-predicted finish time, disables the Create
    /// button, and points them at the standard Marathon / Half plan instead.
    case blocked(predictedTimeSeconds: Int)
}

/// How wide a VDOT gap we treat as "buildable" before blocking the plan.
/// Daniels' rule of thumb: ~1 VDOT point per 4 weeks of focused training.
/// 4 points → ~16 weeks of build on top of the baseline race-prep window
/// (14 marathon / 12 half), which fits inside the 36w / 32w plan-length cap.
private let buildBandMaxGap: Double = 4.0

/// Compute the gate state for a competitive plan given the runner's VDOT.
/// Build-band's `recommendedWeeks` defers to `vdot.recommendedPlanWeeks` (the
/// same source as the "use recommended date" button) so they can't disagree.
///
/// - Parameters:
///   - vdot: The runner's VDOT from a recent race result. Pass nil before the
///     user enters a result — returns `.clear` to let them through the picker.
///   - distanceMeters: The competitive plan's race distance (42195 or 21097).
/// - Returns: The gate state to surface in the UI.
public func competitiveGateState(vdot: VDOT?, distanceMeters: Int) -> CompetitiveGateState {
    guard let vdot = vdot else { return .clear }
    let goalTime: Int = (distanceMeters == 42195) ? 10800 : 5400
    guard let requiredVDOT = VDOT.from(distanceMeters: distanceMeters, timeSeconds: goalTime) else {
        return .clear  // Pathological — degrade open.
    }
    let gap = requiredVDOT.value - vdot.value

    if gap <= 0 {
        return .clear
    }

    if gap > buildBandMaxGap {
        let predicted = vdot.predictedTime(forDistanceMeters: distanceMeters) ?? 0
        return .blocked(predictedTimeSeconds: predicted)
    }

    // Build band: 0 < gap ≤ buildBandMaxGap. Defer to recommendedPlanWeeks
    // so the gate banner and the "use recommended date" button always agree.
    let recommended = vdot.recommendedPlanWeeks(
        forDistance: distanceMeters, goalTimeSeconds: goalTime)
    return .buildBand(recommendedWeeks: recommended)
}
