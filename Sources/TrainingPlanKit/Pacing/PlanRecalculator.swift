//
//  PlanRecalculator.swift
//  TrainingPlanKit
//
//  Mid-plan recalibration: re-anchor the REMAINING weeks of a plan to a new
//  current-fitness estimate (a time trial, a race, a manual "too fast" nudge,
//  or a detected training gap). Pure and UI-free by design — the app decides
//  WHEN to call this (buttons land later); this decides WHAT the plan becomes.
//
//  Safety rails (the competitor lesson — Strava's one-bad-run "Instant
//  Workouts" class of failure): recalibration is checkpoint-driven, clamps
//  the anchor shift per call, never touches completed or past events, and
//  returns a reviewable diff instead of mutating anything.
//

import Foundation

public enum PlanRecalculator {

    // MARK: - Inputs

    public struct Input {
        public let plan: Plan
        /// Fitness NOW (from a TT/race result, an observed-VDOT estimate, or
        /// a detraining estimate after a gap).
        public let currentVDOT: VDOT
        /// Splice point: events strictly before this date (and any completed
        /// event) are preserved byte-for-byte.
        public let asOf: Date
        /// Projection parameters — pass the SAME values the config screen uses
        /// (structure-derived perWeek + per-level ceiling) so the plan and the
        /// predicted finish stay one number.
        public let perWeek: Double
        public let adaptationCeiling: Double
        public let config: PaceProgressionConfig
        /// Pace-offset door ("feels too fast"): pin the race-day target to this
        /// pace instead of re-projecting from current fitness — otherwise the
        /// projection re-earns the offset over the remaining weeks and only
        /// current-anchored (easy) paces move. Rail still applies.
        public var plannedRacePaceOverride: Int? = nil
        /// Set when `currentVDOT` was DERIVED from the stored planned (race-day)
        /// pace rather than measured (the pace-offset door). The planned pace is
        /// END-of-plan fitness, so anchoring "current" at it renders easy/speed
        /// paces at race-week fitness — an "easier" request came out FASTER.
        /// With this flag the remaining projected gain is backed out first.
        public var currentVDOTDerivedFromPlannedPace: Bool = false
        /// Regenerates the HR-side plan for this config/date window. Injected:
        /// production passes `createMarathonPlanV3` + the live catalog; tests
        /// pass a deterministic fake. Generation is deterministic, so this
        /// reproduces the stored plan's structure whenever engine + catalog
        /// are unchanged.
        public let regenerate: (_ planId: UUID, _ start: Date, _ end: Date) -> [WorkoutEvent]

        public init(plan: Plan, currentVDOT: VDOT, asOf: Date,
                    perWeek: Double, adaptationCeiling: Double,
                    config: PaceProgressionConfig,
                    regenerate: @escaping (_ planId: UUID, _ start: Date, _ end: Date) -> [WorkoutEvent]) {
            self.plan = plan
            self.currentVDOT = currentVDOT
            self.asOf = asOf
            self.perWeek = perWeek
            self.adaptationCeiling = adaptationCeiling
            self.config = config
            self.regenerate = regenerate
        }
    }

    public struct Result {
        /// The full event list: past/completed events untouched, future
        /// incomplete events re-rendered at the new anchors.
        public let events: [WorkoutEvent]
        public let replacedCount: Int
        public let newPlannedRacePace: Int          // s/km at race day
        public let oldPlannedRacePace: Int?         // derived from stored events (nil if none found)
        public let projectedVDOT: VDOT
        public let clampedToRail: Bool              // true if the ±rail bounded the shift
    }

    /// Max relative change the planned race pace may take in ONE recalibration
    /// (~±2 VDOT). Bigger jumps need a second checkpoint to confirm — one great
    /// or terrible day never rewrites the plan alone.
    public static let maxRacePaceShiftFraction = 0.06

    // MARK: - Recalculate

    public static func recalculate(_ input: Input) -> Result {
        let plan = input.plan
        // Guard: only non-Pro RACE plans recalibrate. Competitive is goal-locked
        // (the plan IS the goal pace — fitness checkpoints don't move it) and
        // maintenance/VO2 have no race anchor to shift.
        guard plan.raceDistance >= 5000, plan.difficultyLevel != .competitive else {
            return Result(events: plan.events, replacedCount: 0,
                          newPlannedRacePace: storedPlannedRacePace(plan) ?? 0,
                          oldPlannedRacePace: storedPlannedRacePace(plan),
                          projectedVDOT: input.currentVDOT, clampedToRail: false)
        }
        // Guard: nothing left to re-anchor once the race is here.
        guard input.asOf < plan.endDate else {
            return Result(events: plan.events, replacedCount: 0,
                          newPlannedRacePace: storedPlannedRacePace(plan) ?? 0,
                          oldPlannedRacePace: storedPlannedRacePace(plan),
                          projectedVDOT: input.currentVDOT, clampedToRail: false)
        }
        let cal = Calendar.current
        let remainingWeeks = max(1, cal.dateComponents(
            [.weekOfYear], from: input.asOf, to: plan.endDate).weekOfYear ?? 1)

        // Honest current fitness: when currentVDOT came from the planned pace
        // (offset door), subtract the REMAINING share of the plan's projected
        // gain — otherwise the current anchors sit at race-day fitness (see
        // Input doc). Shaped like the render's linear anchor lerp: total
        // ceiling-capped gain × remaining fraction of the plan.
        var current = input.currentVDOT
        if input.currentVDOTDerivedFromPlannedPace {
            let totalWeeks = max(remainingWeeks, cal.dateComponents(
                [.weekOfYear], from: plan.startDate, to: plan.endDate).weekOfYear ?? remainingWeeks)
            let totalGain = min(input.adaptationCeiling,
                                input.perWeek * Double(totalWeeks))
            let remainingGain = totalGain * Double(remainingWeeks) / Double(totalWeeks)
            current = VDOT(value: max(20, current.value - remainingGain))
        }

        var projected = current.projected(
            afterWeeks: remainingWeeks,
            perWeek: input.perWeek,
            adaptationCeiling: input.adaptationCeiling)

        // Rail: clamp the planned race pace shift vs the stored plan.
        let oldPlanned = storedPlannedRacePace(plan)
        var newPlanned = input.plannedRacePaceOverride
            ?? racePace(projected, distance: plan.raceDistance)
        if input.plannedRacePaceOverride != nil {
            projected = vdotFor(racePaceSecondsPerKm: newPlanned,
                                distance: plan.raceDistance, near: projected)
        }
        var clamped = false
        if let old = oldPlanned, old > 0 {
            let lo = Int(Double(old) * (1.0 - maxRacePaceShiftFraction))
            let hi = Int(Double(old) * (1.0 + maxRacePaceShiftFraction))
            if newPlanned < lo || newPlanned > hi {
                newPlanned = min(max(newPlanned, lo), hi)
                clamped = true
                // Re-derive the projected VDOT the clamped pace implies, so easy/
                // speed ends stay consistent with the pace we actually ship.
                projected = vdotFor(racePaceSecondsPerKm: newPlanned,
                                    distance: plan.raceDistance,
                                    near: projected)
            }
        }

        // Anchor trick — the render lerps start→end across the FULL plan window
        // (progression factor also drives km-floor ramps, which must keep their
        // absolute plan position). We need paces to pass through CURRENT fitness
        // at `asOf`, not at week 1: extrapolate the start anchor backwards so
        // lerp(start, end, pf(asOf)) == current.
        let total = plan.endDate.timeIntervalSince(plan.startDate)
        let pfAsOf = total > 0
            ? min(0.95, max(0.0, input.asOf.timeIntervalSince(plan.startDate) / total))
            : 0.0
        func startAnchor(current: Int, end: Int) -> Int {
            guard pfAsOf < 0.95 else { return current }
            let s = (Double(current) - Double(end) * pfAsOf) / (1.0 - pfAsOf)
            return max(1, Int(s.rounded()))
        }

        let curRace  = racePace(current, distance: plan.raceDistance)
        var curEasy  = current.easyPaceSecondsPerKm
        let curSpeed = current.fiveKPaceSecondsPerKm
        var endEasy  = projected.easyPaceSecondsPerKm
        let endSpeed = projected.fiveKPaceSecondsPerKm

        // Offset door: Z2 easy renders exactly at the conversational anchor, so
        // the plan's own events carry the rendered anchor line. Shift THAT by
        // the (railed) offset — the easy family then moves by exactly what the
        // user asked, instead of a VDOT-space approximation. The anchor must be
        // evaluated AT asOf: sampling the nearest future easy run alone skews
        // fast by however far that run sits past asOf (real catalogs space easy
        // runs weeks apart), and a ±5s offset then cancels against the skew —
        // the first stepper tap rendered a frozen preview (Q, 2026-07-29).
        if input.currentVDOTDerivedFromPlannedPace, let old = oldPlanned {
            let off = newPlanned - old
            if let a = renderedEasyAnchor(plan, asOf: input.asOf) {
                curEasy = a.atAsOf + off
                endEasy = a.atEnd + off
            }
        }

        // Regenerate HR-side, render with the new anchors over the ORIGINAL window.
        let hrEvents = input.regenerate(plan.id, plan.startDate, plan.endDate)
        let rendered = PaceZoneConverter.applyPaceProgression(
            to: hrEvents,
            racePace: startAnchor(current: curRace, end: newPlanned),
            conversationalPace: startAnchor(current: curEasy, end: endEasy),
            speedPace: startAnchor(current: curSpeed, end: endSpeed),
            config: input.config,
            startDate: plan.startDate,
            endDate: plan.endDate,
            racePaceEnd: newPlanned,
            conversationalPaceEnd: endEasy,
            speedPaceEnd: endSpeed,
            raceDistanceMeters: plan.raceDistance,
            isCompetitive: plan.difficultyLevel == .competitive,
            isBeginner: plan.difficultyLevel == .beginner,
            isAdvanced: plan.difficultyLevel == .advanced)

        // Splice: keep everything past or completed; adopt regenerated futures.
        // A user-moved date survives via (week, workout.id) matching. Week is
        // derived from the DATE, never from planWeekIndex: consumers that
        // round-trip events through a store (the app's CoreData) don't persist
        // that field, so stored events all carry 0 and identity never matched.
        let weekKey: (WorkoutEvent) -> String = { e in
            let days = cal.dateComponents([.day],
                                          from: cal.startOfDay(for: plan.startDate),
                                          to: cal.startOfDay(for: e.date)).day ?? 0
            return "\(max(0, days / 7))|\(e.workout.id)"
        }
        let keep = plan.events.filter { $0.isCompleted || $0.date < input.asOf }
        let keptKeys = Set(keep.map { weekKey($0) })
        var future = rendered.filter { $0.date >= input.asOf && !keptKeys.contains(weekKey($0)) }
        let oldFuture = plan.events.filter { !$0.isCompleted && $0.date >= input.asOf }
        for i in future.indices {
            if let old = oldFuture.first(where: { weekKey($0) == weekKey(future[i]) }) {
                // Carry the OLD event's identity + (possibly user-moved) date;
                // only the workout payload changes. WorkoutEvent.id is immutable,
                // so rebuild the event around the old shell.
                var carried = old
                carried.workout = future[i].workout
                carried.planWeekIndex = future[i].planWeekIndex
                carried.isDeloadWeek = future[i].isDeloadWeek
                carried.isTaperWeek = future[i].isTaperWeek
                future[i] = carried
            }
        }
        let events = (keep + future).sorted { $0.date < $1.date }

        return Result(events: events,
                      replacedCount: future.count,
                      newPlannedRacePace: newPlanned,
                      oldPlannedRacePace: oldPlanned,
                      projectedVDOT: projected,
                      clampedToRail: clamped)
    }

    // MARK: - Missed-training detection

    public struct MissedTrainingReport {
        public let missedCount: Int          // incomplete events with date < today
        public let gapDays: Int              // days since last COMPLETED event (or plan start)
        /// True from ~a full lost week: the plan no longer matches reality and
        /// the app should offer a rebuild (UI later).
        public let suggestsRebuild: Bool
        /// Conservative fitness estimate after the gap — pass as `currentVDOT`
        /// if no fresher signal (TT/race) exists.
        public let detrainedVDOT: VDOT
    }

    /// Detraining is generously slow (aerobic fitness holds ~2 weeks): no loss
    /// for gaps ≤ 10 days, then ~0.35 VDOT per full week, capped at 4.
    public static func missedTraining(plan: Plan, lastKnownVDOT: VDOT,
                                      today: Date) -> MissedTrainingReport {
        let missed = plan.events.filter { !$0.isCompleted && $0.date < today }.count
        let lastDone = plan.events.filter { $0.isCompleted }.map { $0.date }.max()
            ?? plan.startDate
        let gapDays = max(0, Calendar.current.dateComponents(
            [.day], from: lastDone, to: today).day ?? 0)
        let lossWeeks = max(0.0, Double(gapDays - 10) / 7.0)
        let vdot = VDOT(value: lastKnownVDOT.value - min(4.0, lossWeeks * 0.35))
        return MissedTrainingReport(
            missedCount: missed,
            gapDays: gapDays,
            suggestsRebuild: gapDays >= 7 || missed >= 4,
            detrainedVDOT: vdot)
    }

    // MARK: - Helpers

    private static func racePace(_ v: VDOT, distance: Int) -> Int {
        switch distance {
        case 42195: return v.marathonPaceSecondsPerKm
        case 21097: return v.halfMarathonPaceSecondsPerKm
        case 10000: return v.tenKPaceSecondsPerKm
        default:    return v.fiveKPaceSecondsPerKm
        }
    }

    /// The stored plan's planned race pace = the basePace of any Z3/race
    /// paceTarget in a FUTURE event (MP blocks render exactly at it). Public:
    /// the app's detector derives the plan's implied fitness from it.
    public static func storedPlannedRacePace(_ plan: Plan) -> Int? {
        for e in plan.events where !e.isCompleted {
            for iv in e.workout.intervals {
                if case .paceTarget(let base, let rel) = iv.target,
                   abs(rel - 1.0) < 0.001, base > 150 {
                    return base
                }
            }
        }
        return nil
    }

    /// Rendered easy pace at the splice (first) or race end (last): the work
    /// pace of the nearest/farthest future easy run — i.e. the conversational
    /// anchor as the plan actually rendered it (5s-quantized).
    /// The rendered conversational-anchor line, evaluated at `asOf` and at the
    /// plan end, extended linearly by date — the same shape the render's own
    /// lerp draws. Sampled from future plain-easy WORK blocks (which render
    /// exactly at the anchor); plans whose remaining window has no plain easy
    /// run (real catalogs render easy slots as strides/progression subtypes)
    /// fall back to WARMUP intervals — also rendered at the anchor, and present
    /// in nearly every workout. The two sample kinds are never mixed: a single
    /// consistent family keeps the fitted line's slope honest.
    private static func renderedEasyAnchor(_ plan: Plan, asOf: Date)
        -> (atAsOf: Int, atEnd: Int)? {
        func pace(_ e: WorkoutEvent, _ type: IntervalType) -> Int? {
            for iv in e.workout.intervals where iv.type == type {
                if case .paceTarget(let b, let rel) = iv.target { return Int(Double(b) * rel) }
            }
            return nil
        }
        let future = plan.events
            .filter { !$0.isCompleted && $0.date >= asOf }
            .sorted { $0.date < $1.date }
        var pts: [(date: Date, pace: Int)] = future
            .filter { $0.workout.subtype == .easy }
            .compactMap { e in pace(e, .work).map { (e.date, $0) } }
        if pts.isEmpty {
            pts = future.compactMap { e in pace(e, .warmup).map { (e.date, $0) } }
        }
        guard let first = pts.first else { return nil }
        guard let last = pts.last, last.date > first.date else {
            return (first.pace, first.pace)
        }
        func value(at date: Date) -> Int {
            let t = date.timeIntervalSince(first.date)
                / last.date.timeIntervalSince(first.date)
            return Int((Double(first.pace) + (Double(last.pace) - Double(first.pace)) * t).rounded())
        }
        return (value(at: asOf), value(at: plan.endDate))
    }

    /// Invert race pace → VDOT near a seed (±3), 0.05 steps — small search
    /// space, exact enough for anchor derivation.
    private static func vdotFor(racePaceSecondsPerKm target: Int, distance: Int,
                                near seed: VDOT) -> VDOT {
        var best = seed
        var bestErr = Int.max
        var v = seed.value - 3.0
        while v <= seed.value + 3.0 {
            let cand = VDOT(value: v)
            let err = abs(racePace(cand, distance: distance) - target)
            if err < bestErr { bestErr = err; best = cand }
            v += 0.05
        }
        return best
    }
}
