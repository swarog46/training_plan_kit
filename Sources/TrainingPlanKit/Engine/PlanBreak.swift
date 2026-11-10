//
//  PlanBreak.swift
//  TrainingPlanKit
//
//  When life gets in the way: which planned runs to drop for time off or a
//  busy week. Dropping is all they do; the plan's own recalibration picks up
//  from what was actually run.
//

import Foundation

public enum PlanBreak {
    /// Time off (illness, travel): every run still to do in the days, race days aside.
    public static func timeOff(_ events: [WorkoutEvent], from first: Date, through last: Date) -> [WorkoutEvent] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: first)
        guard let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: last)) else { return [] }
        return droppable(events).filter { $0.date >= start && $0.date < end }
    }

    /// A busy week keeps its long run and its most important quality session; the other runs
    /// still to do from `today` go. A week with neither keeps its longest run.
    public static func busyWeek(_ events: [WorkoutEvent], today: Date = Date()) -> [WorkoutEvent] {
        let cal = Calendar.current
        guard let week = cal.dateInterval(of: .weekOfYear, for: today) else { return [] }
        let left = droppable(events).filter { $0.date >= cal.startOfDay(for: today) && $0.date < week.end }
        let sessions = WeekSessions(sessions: left.map { ("", $0.workout) })
        // A long run with quality in it still leaves room for the week's other key session.
        let keySession = sessions.qualityByImportance.last { $0 != sessions.longRun }
        var kept = Set([sessions.longRun, keySession].compactMap { $0 })
        if kept.isEmpty, let longest = left.indices.max(by: { left[$0].workout.duration < left[$1].workout.duration }) {
            kept.insert(longest)
        }
        return left.indices.filter { !kept.contains($0) }.map { left[$0] }
    }

    /// Runs a break can drop: not done, not already dropped, not a race.
    private static func droppable(_ events: [WorkoutEvent]) -> [WorkoutEvent] {
        events.filter { !$0.isCompleted && !$0.isCancelled && $0.workout.type != .race }
    }
}
