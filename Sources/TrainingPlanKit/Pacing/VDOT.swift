//
//  VDOT.swift
//  RunPlan
//
//  Daniels' VDOT — derives training paces from a recent race result (actual
//  current fitness) instead of the goal time, so paces stay sane when the goal
//  outruns fitness. Ref: Daniels' Running Formula (4th ed.), Ch. 5.
//  Currently wired into competitive plans only; other tiers use goal-derived paces.
//

import Foundation

public struct VDOT: Equatable {
    /// The VDOT value (typically 30-85 for amateur → elite range).
    public let value: Double

    /// Direct construction from a known VDOT value (e.g. numeric inversion of a
    /// pace curve — find the V whose easy pace matches an observed run).
    public init(value: Double) {
        self.value = value
    }

    // MARK: - Construction

    /// Compute VDOT from a single race result. Daniels' formula.
    ///
    /// - Parameters:
    ///   - distanceMeters: Race distance in meters (5000, 10000, 21097, 42195 — or any race distance).
    ///   - timeSeconds: Finish time in seconds.
    /// - Returns: The corresponding VDOT, or nil if inputs are invalid.
    public static func from(distanceMeters: Int, timeSeconds: Int) -> VDOT? {
        guard distanceMeters > 0, timeSeconds > 0 else { return nil }

        let timeMin = Double(timeSeconds) / 60.0
        let velocity = Double(distanceMeters) / timeMin  // m/min

        // Numerator: estimated VO2 cost of running at this velocity.
        let numerator = -4.60
                      + 0.182258 * velocity
                      + 0.000104 * velocity * velocity

        // Denominator: fraction of VO2max sustainable for this race duration.
        // Longer races → smaller fraction (you can't hold VO2max for 3 hours).
        let denominator = 0.8
                        + 0.1894393 * exp(-0.012778 * timeMin)
                        + 0.2989558 * exp(-0.1932605 * timeMin)

        let v = numerator / denominator
        guard v.isFinite, v > 0 else { return nil }
        return VDOT(value: v)
    }

    // MARK: - Race time prediction

    /// Predict the time the runner can hold for a given race distance.
    /// Solved numerically by inverting the VDOT formula (bisection).
    ///
    /// - Parameter distanceMeters: Target race distance in meters.
    /// - Returns: Predicted time in seconds, or nil if no solution converges.
    public func predictedTime(forDistanceMeters distanceMeters: Int) -> Int? {
        guard distanceMeters > 0 else { return nil }

        // Bisect over plausible times: 1 minute → 6 hours.
        var lo: Double = 60.0
        var hi: Double = 6 * 3600.0
        var bestTime = (lo + hi) / 2

        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            bestTime = mid
            guard let midVDOT = VDOT.from(distanceMeters: distanceMeters, timeSeconds: Int(mid)) else {
                return nil
            }
            if abs(midVDOT.value - self.value) < 0.01 {
                return Int(mid)
            }
            if midVDOT.value > self.value {
                // Predicted VDOT for this time is too high → we need a slower time.
                lo = mid
            } else {
                hi = mid
            }
        }
        return Int(bestTime)
    }

    // MARK: - Pace zones (sec per km)

    /// Marathon pace — the pace this VDOT predicts can be held for 42.195km.
    /// This is the anchor for sub-3h training: derive everything else relative
    /// to this rather than to a goal-time-derived guess.
    public var marathonPaceSecondsPerKm: Int {
        guard let t = predictedTime(forDistanceMeters: 42195) else { return 0 }
        return Int(Double(t) / 42.195)
    }

    /// Half-marathon pace — for sub-1:30 plans.
    public var halfMarathonPaceSecondsPerKm: Int {
        guard let t = predictedTime(forDistanceMeters: 21097) else { return 0 }
        return Int(Double(t) / 21.097)
    }

    /// 10K race pace.
    public var tenKPaceSecondsPerKm: Int {
        guard let t = predictedTime(forDistanceMeters: 10000) else { return 0 }
        return Int(Double(t) / 10.0)
    }

    /// 5K race pace.
    public var fiveKPaceSecondsPerKm: Int {
        guard let t = predictedTime(forDistanceMeters: 5000) else { return 0 }
        return Int(Double(t) / 5.0)
    }

    /// Steady-state training pace (sec/km) at a given fraction of VO2max —
    /// Daniels' method, and how his training-pace tables are generated.
    ///
    /// Inverts the VO2-cost curve  VO2 = -4.60 + 0.182258·v + 0.000104·v²
    /// to find the velocity (m/min) whose oxygen cost equals `fraction × VDOT`,
    /// then converts to sec/km. Unlike a marathon-pace offset this stays
    /// meaningful at every fitness level: a beginner's "marathon pace" is a
    /// fictional extrapolation, but their VO2max fraction is real, so easy and
    /// threshold come out sane instead of near-walking.
    public func paceAtVO2Fraction(_ fraction: Double) -> Int {
        let target = fraction * value                 // VO2 cost to sustain
        let a = 0.000104, b = 0.182258, c = -(4.60 + target)
        let disc = b * b - 4 * a * c
        guard disc > 0 else { return 0 }
        let v = (-b + disc.squareRoot()) / (2 * a)    // velocity, m/min
        guard v > 0 else { return 0 }
        return Int(60000.0 / v)                        // sec/km
    }

    /// Daniels' Easy (E) pace — derived directly from VDOT at ~72% VO2max
    /// (the runnable middle of his 59-74% E range). Was `MP + 75`, which
    /// anchored easy to a beginner's fictional marathon prediction and landed
    /// 25-40s/km too slow at every fitness level.
    public var easyPaceSecondsPerKm: Int {
        let natural = paceAtVO2Fraction(0.72)
        // Below VDOT 30 (Daniels' table floor) the 72% pace balloons into a
        // walk — a 1:20 10K runner would get a 9:12 "easy". Cap the gap to
        // threshold, tightening as VDOT drops, so easy stays a real run.
        guard value < 30 else { return natural }
        let maxGap = Int(max(33.0, min(65.0, 65.0 - (30.0 - value) * 3.5)))
        return min(natural, thresholdPaceSecondsPerKm + maxGap)
    }

    /// Daniels' Threshold (T) pace — ~88% VO2max, ~hour-race effort. Derived
    /// directly from VDOT (was `MP - 15`, which inherited the same fictional
    /// marathon anchor and ran beginners ~15s/km too slow).
    public var thresholdPaceSecondsPerKm: Int {
        paceAtVO2Fraction(0.88)
    }

    /// Daniels' Interval (I) pace — 95-100% VO2max, 3-5 min race pace.
    /// Used for VO2max work like 5×1000m. Approximated as 5K pace minus a few sec.
    public var intervalPaceSecondsPerKm: Int {
        let fiveK = fiveKPaceSecondsPerKm
        guard fiveK > 0 else { return 0 }
        return fiveK - 3
    }

    /// Daniels' Repetition (R) pace — neuromuscular work, faster than V̇O2max.
    /// Used for short reps (200-400m). Approximated as Interval - 10 sec/km.
    public var repetitionPaceSecondsPerKm: Int {
        let i = intervalPaceSecondsPerKm
        guard i > 0 else { return 0 }
        return i - 10
    }
}

// MARK: - Plan-length recommendation

extension VDOT {
    /// Recommended plan length (weeks) to reach the goal from this VDOT, mapping
    /// VDOT gap → weeks (~1 point per 4 weeks). Adds the build-up to a baseline
    /// race window (14w marathon / 12w half), clamped (28w / 24w max).
    ///
    /// - Parameters:
    ///   - distanceMeters: Goal race distance.
    ///   - goalTimeSeconds: The target finish time the user wants.
    /// - Returns: Recommended plan length in weeks. Returns a sensible
    ///   default if either the goal can't be parsed or it's well below
    ///   current fitness (no extra build needed).
    public func recommendedPlanWeeks(forDistance distanceMeters: Int, goalTimeSeconds: Int) -> Int {
        guard let requiredVDOT = VDOT.from(distanceMeters: distanceMeters, timeSeconds: goalTimeSeconds) else {
            return distanceMeters == 42195 ? 18 : 14
        }
        // Negative gap = already overfit for the goal; no extra build needed.
        let gap = max(0.0, requiredVDOT.value - self.value)
        // ~4 weeks per VDOT point. Generous to absorb noise.
        let buildWeeks = Int(ceil(gap * 4.0))
        let baseRaceWeeks = distanceMeters >= 30000 ? 14 : 12
        let totalWeeks = baseRaceWeeks + buildWeeks
        if distanceMeters >= 30000 {
            return min(28, max(14, totalWeeks))
        } else {
            return min(24, max(12, totalWeeks))
        }
    }

    /// Project realistic finish time after `planWeeks` of training.
    ///
    /// VDOT gain follows an asymptotic curve toward the per-block ceiling (not a
    /// hard `min(weeks × perWeek, cap)`), so it stays monotonic in weeks and
    /// matches the diminishing returns of real adaptation:
    ///     gain = ceiling × (1 − exp(−stimulus / ceiling)),  stimulus = weeks × perWeek
    /// Only projects the current block (a runner climbs successive asymptotes).
    /// - Returns: Predicted finish time in seconds at the projected VDOT.
    public func realisticOutcome(forDistance distanceMeters: Int,
                          planWeeks: Int,
                          perWeek: Double = 0.25,
                          adaptationCeiling: Double = 6.0) -> Int? {
        projected(afterWeeks: planWeeks, perWeek: perWeek, adaptationCeiling: adaptationCeiling)
            .predictedTime(forDistanceMeters: distanceMeters)
    }

    /// The VDOT this runner is projected to reach after `weeks` of training —
    /// the same asymptotic gain realisticOutcome uses. Callers use it to derive
    /// race-week pace anchors (racePaceEnd / easy / 5K) for the render.
    public func projected(afterWeeks weeks: Int,
                          perWeek: Double = 0.25,
                          adaptationCeiling: Double = 6.0) -> VDOT {
        let stimulus = Double(weeks) * perWeek
        let gain = adaptationCeiling * (1.0 - exp(-stimulus / adaptationCeiling))
        return VDOT(value: self.value + gain)
    }

    /// Scale a level-based adaptation ceiling by proximity to genetic ceiling.
    /// Decay is super-linear (^1.5 of the linear gap, floored at 0.10) — faster
    /// than linear (which over-projects elite gains) but not so fast mid-pack
    /// runners stall climbing toward sub-3 / sub-1:30. Pure-numeric API so
    /// plan_debug can exercise the math without RunnerLevel (iOS-only).
    public static func adaptationCeiling(baseCap: Double, current: VDOT) -> Double {
        let linearFactor = max(0.0, min(1.0, (65.0 - current.value) / 35.0))
        let ceilingFactor = max(0.10, pow(linearFactor, 1.5))
        return baseCap * ceilingFactor
    }

    /// Mild newness multiplier on per-week VDOT growth at the bottom of the
    /// range — untrained runners adapt faster at the same stimulus. Kept small
    /// (under-promise): linear ramp 1.20× at VDOT 30 → 1.00× at VDOT ≥ 38.
    public static func newnessBoost(current: VDOT) -> Double {
        return 1.0 + max(0.0, min(0.2, (38.0 - current.value) / 40.0))
    }
}


// MARK: - Race-pace inversion

extension VDOT {
    /// The VDOT whose predicted race pace at `distanceMeters` equals
    /// `racePaceSecondsPerKm` (bisection over the amateur-elite range).
    /// Used by recalibration to recover a plan's implied fitness from its
    /// stored planned pace when no fresher signal exists.
    public static func fromRacePace(secondsPerKm pace: Int, distanceMeters: Int) -> VDOT? {
        guard pace > 120, distanceMeters >= 1000 else { return nil }
        func paceFor(_ v: Double) -> Int {
            let cand = VDOT(value: v)
            switch distanceMeters {
            case 42195: return cand.marathonPaceSecondsPerKm
            case 21097: return cand.halfMarathonPaceSecondsPerKm
            case 10000: return cand.tenKPaceSecondsPerKm
            default:    return cand.fiveKPaceSecondsPerKm
            }
        }
        var lo = 15.0, hi = 85.0
        guard paceFor(lo) >= pace, paceFor(hi) <= pace else { return nil }
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if paceFor(mid) > pace { lo = mid } else { hi = mid }
        }
        return VDOT(value: (lo + hi) / 2)
    }
}
