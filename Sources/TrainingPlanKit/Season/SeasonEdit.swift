//
//  SeasonEdit.swift
//  TrainingPlanKit
//
//  Changing a season's races once it is under way. The season is laid out and
//  built again from its original start with the new races, and only the part
//  from next week on replaces the plan: blocks the change doesn't reach come
//  out the same, so the runner carries on where they were.
//

import Foundation

public enum SeasonEdit {
    /// A race this close is run easy in place; the plan can't usefully rebuild around it.
    public static let lateRemovalDays = 7
    /// A new race needs this much notice: its easing-in days plus a few of training.
    public static let addNoticeDays = 10

    public enum Removal: Equatable {
        case rebuild    // the plan re-forms without the race
        case runEasy    // too close: race day becomes an easy run
    }

    public enum AddRefusal: Equatable {
        case tooSoon(days: Int)
        case notBeforeGoal
        case sameDayAsAnotherRace
    }

    /// How a race leaves the plan today; nil when it can't (the goal race, or one already past).
    public static func removal(of race: SeasonRace, in races: [SeasonRace], today: Date) -> Removal? {
        guard let goal = races.map(\.date).max(), race.date < goal else { return nil }
        let days = daysUntil(race.date, from: today)
        guard days >= 0 else { return nil }
        return days > lateRemovalDays ? .rebuild : .runEasy
    }

    /// Why a race can't join the plan today; nil when it can (the new layout's issues still apply).
    public static func refusal(adding race: SeasonRace, to races: [SeasonRace], today: Date) -> AddRefusal? {
        let days = daysUntil(race.date, from: today)
        if days < addNoticeDays { return .tooSoon(days: days) }
        guard let goal = races.map(\.date).max(), race.date < goal else { return .notBeforeGoal }
        return races.contains { $0.date == race.date } ? .sameDayAsAnotherRace : nil
    }

    /// The race as it joins a plan under way: short of its plan's minimum build from `cut`,
    /// it can only be a tune-up.
    public static func joining(_ race: SeasonRace, cut: Date) -> SeasonRace {
        var joined = race
        joined.tuneUpOnly = SeasonPlanner.adding(-7 * SeasonPlanner.minBuildWeeks(race), to: race.date) < cut
        return joined
    }

    /// The first day a rebuild may change: the start of next calendar week.
    public static func cut(after today: Date) -> Date {
        Calendar.current.dateInterval(of: .weekOfYear, for: today)!.end
    }

    /// The plan after a rebuild: its events before `cut` as they were, then the rebuilt
    /// season's, with run growth capped against what was kept.
    public static func merged(_ existing: [WorkoutEvent], rebuilt: [WorkoutEvent], cut: Date, seasonStart: Date) -> [WorkoutEvent] {
        let kept = existing.filter { $0.date < cut }.sorted { $0.date < $1.date }
        let ahead = rebuilt.filter { $0.date >= cut }.sorted { $0.date < $1.date }
        let opening = Calendar.current.date(byAdding: .day, value: 14, to: seasonStart)!
        return kept + capRunGrowthV3(ahead, after: kept, opening: opening)
    }

    /// A race too close to rebuild around: its day becomes an easy run.
    public static func runningEasy(on raceDay: Date, in events: [WorkoutEvent], catalog: [Workout]) -> [WorkoutEvent] {
        guard let easy = SeasonPlanBuilder.easyRun(minutes: 35, catalog: catalog) else { return events }
        return events.map { event in
            guard event.workout.type == .race, Calendar.current.isDate(event.date, inSameDayAs: raceDay) else { return event }
            var swapped = event
            swapped.workout = easy
            return swapped
        }
    }

    public static func daysUntil(_ date: Date, from today: Date) -> Int {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: today), to: cal.startOfDay(for: date)).day ?? 0
    }
}
