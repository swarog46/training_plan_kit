import Foundation

/// After weeks away, the first weeks back climb from what the runner had been doing.
/// A plan rebuilt for the weeks left starts where a fresh plan of that length starts,
/// which can be more than the runner ran before the break; this holds those weeks to
/// the earlier level, growing by `weeklyGrowth` a week, until the plan is under it.
public enum ComebackRamp {
    /// The same limit a single run may grow by (Frandsen et al. 2025).
    public static let weeklyGrowth = 1.15
    /// A week is never cut to less than this share of what the plan set for it.
    public static let deepestCut = 0.5

    /// Average weekly running time, in seconds, over the three weeks up to the last run
    /// in `history` (fewer when the history is shorter). Nil when nothing was run.
    public static func baselineSeconds(_ history: [WorkoutEvent], calendar: Calendar = .current) -> Double? {
        let runs = history.filter { $0.isCompleted && !$0.isCancelled && $0.workout.type != .race }
        guard let last = runs.map(\.date).max(), let first = runs.map(\.date).min() else { return nil }
        let windowStart = calendar.date(byAdding: .day, value: -21, to: last) ?? last
        let seconds = runs.filter { $0.date > windowStart }.reduce(0.0) { $0 + ($1.actualDuration ?? Double($1.workout.duration)) }
        let days = calendar.dateComponents([.day], from: max(first, windowStart), to: last).day ?? 0
        let weeks = min(3.0, max(1.0, (Double(days) / 7.0).rounded(.up)))
        return seconds > 0 ? seconds / weeks : nil
    }

    /// `events` from `opening` on, with each seven-day week held to the ramp from the
    /// level of `history`. Races are never cut; runs keep their shape and move in
    /// five-minute steps. Without a history the plan is returned as it is.
    public static func capped(_ events: [WorkoutEvent], after history: [WorkoutEvent], opening: Date,
                              calendar: Calendar = .current) -> [WorkoutEvent] {
        guard let baseline = baselineSeconds(history, calendar: calendar) else { return events }
        var out = events
        let trainable = out.indices.filter { out[$0].date >= opening && !out[$0].isCancelled && out[$0].workout.type != .race }
        let byWeek = Dictionary(grouping: trainable) { index in
            (calendar.dateComponents([.day], from: calendar.startOfDay(for: opening), to: out[index].date).day ?? 0) / 7
        }
        for (week, indices) in byWeek {
            let planned = indices.reduce(0.0) { $0 + Double(out[$1].workout.duration) }
            let limit = baseline * pow(weeklyGrowth, Double(week))
            guard planned > limit, planned > 0 else { continue }
            let factor = max(deepestCut, limit / planned)
            for index in indices {
                let target = Int64((Double(out[index].workout.duration) * factor / 300).rounded(.down)) * 300   // never over the limit
                out[index].workout = rescaledV3(out[index].workout, toSeconds: max(900, target))
            }
        }
        return out
    }
}
