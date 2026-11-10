//
//  SeasonPlanBuilder.swift
//  TrainingPlanKit
//
//  Renders a SeasonLayout into one event list. Each build block IS the
//  single-race plan for its race (same engine, same config), so every block
//  keeps the certified structure; recovery blocks are easy running, bridges
//  are maintenance running, and tune-up races replace that day's session.
//  The 30-day run growth cap (capRunGrowthV3) holds across blocks too.
//

import Foundation

public enum SeasonPlanBuilder {
    /// - config: the block's plan configuration (its race's plan; maintenance for a bridge),
    ///   with the runner's training days already applied.
    /// - render: per-block post-processing, e.g. pace progression with that block's anchors.
    /// - fitness: the runner's expected VDOT on a date, to pace tune-up races at their own distance.
    public static func build(_ layout: SeasonLayout,
                             level: RunnerLevel,
                             catalog: [Workout],
                             planId: UUID,
                             config: (SeasonBlock) -> PlanConfiguration,
                             render: (SeasonBlock, [WorkoutEvent]) -> [WorkoutEvent] = { $1 },
                             fitness: (Date) -> VDOT? = { _ in nil }) -> [WorkoutEvent] {
        guard let seasonStart = layout.blocks.first?.start else { return [] }
        var season: [WorkoutEvent] = []
        for block in layout.blocks {
            var events = training(for: block, level: level, catalog: catalog, planId: planId, config: config)
            // Blocks share their boundary day: a tune-up on it goes to the later block only.
            let tuneUps = layout.races.indices.filter { i in
                layout.priorities[i] == .tuneUp && layout.blocks.last { $0.contains(layout.races[i].date) } == block
            }
            for i in tuneUps {
                events = addTuneUp(layout.races[i], to: events, level: level, catalog: catalog, planId: planId)
            }
            events = render(block, events).map { pacingRaceDay($0, layout: layout, fitness: fitness) }
            // Across blocks too, after render (a pace render resizes long runs to its km window).
            events = capRunGrowthV3(events.sorted { $0.date < $1.date }, after: season,
                                    opening: Calendar.current.date(byAdding: .day, value: 14, to: seasonStart)!)
            // Weeks count from the season's start, so blocks don't overlap in week-keyed views.
            let offset = (Calendar.current.dateComponents([.day], from: seasonStart, to: block.start).day ?? 0) / 7
            season += events.map { var e = $0; if e.planWeekIndex >= 0 { e.planWeekIndex += offset }; return e }
        }
        return season
    }

    static func training(for block: SeasonBlock, level: RunnerLevel,
                         catalog: [Workout], planId: UUID, config: (SeasonBlock) -> PlanConfiguration) -> [WorkoutEvent] {
        switch block.kind {
        case .build, .bridge:
            return createMarathonPlanV3(startDate: block.start, raceDate: block.end, from: catalog,
                                        planId: planId, config: config(block))
        case .recovery:
            return recovery(block, config: config(block), level: level, catalog: catalog, planId: planId)
        }
    }

    /// Easy running only, no run the day after the race, building from 60% of a
    /// normal easy run back to full; from week 2 the long-run day runs a little longer.
    static func recovery(_ block: SeasonBlock, config: PlanConfiguration, level: RunnerLevel,
                         catalog: [Workout], planId: UUID) -> [WorkoutEvent] {
        let cal = Calendar.current
        let easyMinutes: Double = level == .beginner ? 30 : level == .intermediate ? 40 : 45
        let ramp = [0.6, 0.8, 0.9, 1.0]
        var events: [WorkoutEvent] = []
        var day = cal.date(byAdding: .day, value: 1, to: block.start)!
        while day < block.end {
            let weekday = cal.component(.weekday, from: day) - 1            // kit days: 0 = Sunday
            let week = (cal.dateComponents([.day], from: block.start, to: day).day ?? 0) / 7
            if config.trainingDays.contains(weekday) {
                let long = week >= 1 && weekday == config.longestWorkoutDay ? 1.4 : 1.0
                if let w = easyRun(minutes: easyMinutes * ramp[min(week, ramp.count - 1)] * long, catalog: catalog) {
                    var e = WorkoutEvent(workout: w, planId: planId, date: day)
                    e.planWeekIndex = week
                    events.append(e)
                }
            }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        return events
    }

    /// The race replaces that day's session, inside Pfitzinger's tune-up mini-taper: no intervals
    /// in the 5 days before, no other hard run or long run in the 4 before, and easy running
    /// after (5 days after a 15K or longer, 2 after a shorter race).
    static func addTuneUp(_ race: SeasonRace, to events: [WorkoutEvent], level: RunnerLevel,
                          catalog: [Workout], planId: UUID) -> [WorkoutEvent] {
        let cal = Calendar.current
        guard let raceWorkout = createRaceWorkout(level: level, distance: Int64(race.distanceMeters)) else { return events }
        let easyDaysAfter = race.distanceMeters >= 15000 ? 5 : 2
        var out = events.filter { !cal.isDate($0.date, inSameDayAs: race.date) }
        for i in out.indices {
            let offset = cal.dateComponents([.day], from: race.date, to: out[i].date).day ?? 0
            let category = determineWorkoutCategory(workout: out[i].workout)
            let clear = (-5 ... -1).contains(offset) && category == .interval
                || (-4 ... -1).contains(offset) || (1...easyDaysAfter).contains(offset)
            guard clear, category != .easy, let easy = easyRun(minutes: 35, catalog: catalog) else { continue }
            out[i].workout = easy
        }
        var e = WorkoutEvent(workout: raceWorkout, planId: planId, date: race.date)
        e.planWeekIndex = out.min { abs($0.date.timeIntervalSince(race.date)) < abs($1.date.timeIntervalSince(race.date)) }?
            .planWeekIndex ?? -1
        return (out + [e]).sorted { $0.date < $1.date }
    }

    /// Race days before the goal carry their own target: a tune-up's predicted pace at its own
    /// distance, and any race's pace moved by the effort the runner chose. A block's race at
    /// predicted effort keeps the pace its block rendered.
    static func pacingRaceDay(_ event: WorkoutEvent, layout: SeasonLayout, fitness: (Date) -> VDOT?) -> WorkoutEvent {
        guard event.workout.type == .race, let goal = layout.races.last,
              let index = layout.races.dropLast().firstIndex(where: { $0.date == event.date }),
              let vdot = fitness(event.date) else { return event }
        let race = layout.races[index]
        let effort = SeasonPlanner.efforts(for: race, goal: goal).contains(race.effort) ? race.effort : .controlled
        guard layout.priorities[index] == .tuneUp || effort != .predicted else { return event }
        return pacedRace(event, distanceMeters: race.distanceMeters, vdot: vdot, effort: effort)
    }

    /// Seconds per km for a race run at `effort` by a runner of this fitness.
    public static func racePace(distanceMeters: Int, vdot: VDOT, effort: RaceEffort = .predicted) -> Int? {
        vdot.predictedTime(forDistanceMeters: distanceMeters).map {
            Int((Double($0) * 1000 / Double(distanceMeters) * effort.paceFactor).rounded())
        }
    }

    /// Race-day target at the race's own pace, not the block's race pace.
    static func pacedRace(_ event: WorkoutEvent, distanceMeters: Int, vdot: VDOT, effort: RaceEffort = .predicted) -> WorkoutEvent {
        guard let pace = racePace(distanceMeters: distanceMeters, vdot: vdot, effort: effort) else { return event }
        let w = event.workout
        var e = event
        e.workout = Workout(id: w.id, title: w.title, type: w.type, subtype: w.subtype,
                            trainingType: w.trainingType, targetType: w.targetType, duration: w.duration,
                            distance: w.distance, key: w.key, trainingLoad: w.trainingLoad,
                            intervals: w.intervals.map {
                                WorkoutInterval(id: $0.id, type: $0.type, duration: $0.duration, distance: $0.distance,
                                                targetType: $0.targetType, target: .paceTarget(basePace: pace, relative: 1.0))
                            },
                            workRestRatio: w.workRestRatio, workDuration: w.workDuration, restDuration: w.restDuration,
                            workDistance: w.workDistance, restDistance: w.restDistance)
        return e
    }

    static func easyRun(minutes: Double, catalog: [Workout]) -> Workout? {
        catalog.filter { $0.subtype == .easy }.min { abs(Double($0.duration) / 60 - minutes) < abs(Double($1.duration) / 60 - minutes) }
    }
}

extension SeasonBlock {
    /// Training days of the block, race day included.
    func contains(_ date: Date) -> Bool { date >= start && date <= end }
}
