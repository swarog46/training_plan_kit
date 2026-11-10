//
//  RunEffort.swift
//  TrainingPlanKit
//
//  How runs felt, and when that says the plan is asking too much.
//

import Foundation

/// How a run felt, as the runner rated it afterwards.
public enum RunEffort: Int, Codable, CaseIterable {
    case easy = 1
    case right
    case hard
    case tooHard
}

public enum EffortAdvice {
    /// A completed run and how it felt.
    public struct RatedRun: Equatable {
        public enum Kind { case easy, long, quality }
        public let date: Date
        public let kind: Kind
        public let effort: RunEffort

        public init(date: Date, kind: Kind, effort: RunEffort) {
            self.date = date
            self.kind = kind
            self.effort = effort
        }

        public init(_ event: WorkoutEvent, effort: RunEffort) {
            let subtype = event.workout.subtype
            let kind: Kind = subtype.qualityRank != nil ? .quality : subtype.isLongRun || subtype == .mediumLong ? .long : .easy
            self.init(date: event.completionDate ?? event.date, kind: kind, effort: effort)
        }

        /// Harder than the session is meant to feel: an easy run that felt hard, anything that felt too hard.
        var isWarning: Bool {
            effort == .tooHard || (kind == .easy && effort == .hard)
        }
    }

    /// Ratings older than this say nothing about the plan today.
    public static let windowDays = 14
    /// One bad day is a bad day; this many is the plan.
    public static let warningsToEase = 2

    /// The last two weeks hold enough runs that felt harder than they should.
    public static func shouldEase(_ runs: [RatedRun], today: Date = Date()) -> Bool {
        let cal = Calendar.current
        guard let from = cal.date(byAdding: .day, value: -windowDays, to: cal.startOfDay(for: today)) else { return false }
        return runs.filter { $0.date >= from && $0.date <= today && $0.isWarning }.count >= warningsToEase
    }
}
