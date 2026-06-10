//
//  CompetitiveGate.swift
//  RunPlan
//
//  Single source of truth for "can this runner pick the Sub-3:00 Marathon /
//  Sub-1:30 Half plan?" Both the iOS plan-setup screen AND the regression
//  tests (via plan_debug) call into this same function. The earlier failure
//  mode — Python tests reimplementing UI logic and disagreeing with the
//  shipped Swift code — does not recur because there is one implementation.
//
//  Decision policy (locked with the user 2026-06-06, recalibrated 2026-06-07
//  after my first pass used a wrong reference VDOT):
//
//    requiredVDOT = VDOT.from(distance, goalTime)  (true VDOT needed)
//    gap = requiredVDOT - currentVDOT
//
//    gap ≤ 0       →  .clear              (current fitness already meets/exceeds goal)
//    0 < gap ≤ 4   →  .buildBand(weeks)   (~16 weeks of focused training closes it —
//                                          one Daniels point per ~4 weeks)
//    gap > 4       →  .blocked(time)      (more than a 4-VDOT-point gap; this plan
//                                          is not realistic in the current cycle —
//                                          point them at the standard Marathon/Half
//                                          plan with their actual goal time)
//
//  The earlier draft used a fixed `VDOT ≥ 58` threshold for sub-3. That was
//  wrong — VDOT 58 actually predicts a ~2:33 marathon. Sub-3 requires VDOT
//  ~53. The correct gate compares against the goal-derived requiredVDOT,
//  not a hardcoded number, and works for any (distance, goalTime) pair.
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
///
/// Comparison is to the *goal-derived* required VDOT, NOT to a hardcoded
/// reference value. For a Sub-3:00 Marathon (goalTime 10800s), required
/// VDOT ≈ 53; a runner at VDOT 55 has negative gap → `.clear`. For a Sub-
/// 1:30 Half (goalTime 5400s), required VDOT ≈ 54; same runner at VDOT
/// 55 → still `.clear`. This auto-extends to any future goal-time picker.
///
/// Build-band's `recommendedWeeks` defers to `vdot.recommendedPlanWeeks`,
/// the same function that powers the "use recommended date" button in the
/// race-date row. Sharing the number means the gate banner and that button
/// can never disagree — both surface the same target window.
///
/// - Parameters:
///   - vdot: The runner's VDOT, derived from a recent race result. Pass nil
///     when the user has not entered a race result yet — returns `.clear`
///     so the UI lets them through the picker and they can see the
///     methodology / inputs.
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
