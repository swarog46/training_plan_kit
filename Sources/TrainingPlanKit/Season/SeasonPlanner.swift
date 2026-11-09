//
//  SeasonPlanner.swift
//  TrainingPlanKit
//
//  Multi-race seasons: lays several races out as one continuous plan of at
//  most 11 months. The last race is the goal. Every earlier race either gets
//  its own block (at least its single-race plan's minimum build, then
//  recovery) or is raced as a tune-up inside the next block; a race longer
//  than a half can't be a tune-up. Pure layout — the builder renders each
//  block with the existing single-race engines.
//

import Foundation

/// A race the runner has entered.
public struct SeasonRace: Codable, Hashable {
    public var date: Date
    public var distanceMeters: Int
    public var name: String?
    /// Runs per week while training for this race; nil = the same as the goal race.
    public var runsPerWeek: Int?

    public init(date: Date, distanceMeters: Int, name: String? = nil, runsPerWeek: Int? = nil) {
        self.date = Calendar.current.startOfDay(for: date)
        self.distanceMeters = distanceMeters
        self.name = name
        self.runsPerWeek = runsPerWeek
    }
}

public enum RacePriority: String, Codable {
    case goal     // A: the season builds to it
    case block    // B: its own build block, taper and recovery
    case tuneUp   // C: raced inside another block, in place of a hard session
}

public struct SeasonBlock: Hashable {
    public enum Kind: Hashable {
        case build(race: Int)      // ends with races[race] on `end`
        case recovery(race: Int)   // easy running after races[race]
        case bridge                // steady base between blocks
    }
    public let kind: Kind
    public let start: Date         // first day
    public let end: Date           // day after the last training day (a build's race day)
}

public enum SeasonIssue: Hashable {
    case unsupportedDistance(SeasonRace)                 // dropped
    case raceBeforeStart(SeasonRace)                     // dropped
    case seasonTooLong(earliestStart: Date)
    case noRoomToTrain(SeasonRace, weeks: Int)           // needs its own block of `weeks`, none fits
    case tooSoonAfter(SeasonRace, SeasonRace, days: Int) // raced before recovering from the first
    case shortGoalBlock(weeks: Int, minimum: Int)
    case longTuneUpNearGoal(SeasonRace, days: Int)       // race it easy

    /// The plan can't be built until the runner moves or removes a race.
    public var blocksPlan: Bool {
        switch self {
        case .seasonTooLong, .noRoomToTrain, .tooSoonAfter: return true
        case .unsupportedDistance, .raceBeforeStart, .shortGoalBlock, .longTuneUpNearGoal: return false
        }
    }
}

public struct SeasonLayout {
    public let races: [SeasonRace]          // by date; the last is the goal
    public let priorities: [RacePriority]
    public let blocks: [SeasonBlock]        // contiguous, in date order
    public let issues: [SeasonIssue]
}

public enum SeasonPlanner {
    /// The single-race plan for this distance at a B/I/A level.
    public static func category(forDistance meters: Int) -> PlanCategory? {
        switch meters {
        case 5000: return .fiveK
        case 10000: return .tenK
        case 15000: return .fifteenK
        case 16093: return .tenMile
        case 21097: return .halfMarathon
        case 30000: return .thirtyK
        case 42195: return .marathon
        case 50000: return .fiftyK
        default: return nil
        }
    }

    /// The plan a race trains with: the nearest plan distance within 25% (a 20K trains as a half).
    public static func planDistance(forRaceMeters meters: Int) -> Int? {
        let plans = [5000, 10000, 15000, 16093, 21097, 30000, 42195, 50000]
        guard let nearest = plans.min(by: { abs($0 - meters) < abs($1 - meters) }),
              abs(nearest - meters) * 4 <= nearest else { return nil }
        return nearest
    }

    /// Easy running after a race before the next build: about a week per
    /// 10-15 km raced (Pfitzinger: easy week after a key race, more after 15K+).
    public static func recoveryDays(afterDistance meters: Int, level: RunnerLevel) -> Int {
        let weeks: Int
        switch meters {
        case ..<16094: weeks = 1
        case ..<30001: weeks = 2
        case ..<42196: weeks = 3
        default: weeks = 4
        }
        // Beginners take an extra week after a half or longer.
        return 7 * (weeks + (level == .beginner && meters >= 21097 ? 1 : 0))
    }

    /// A multi-race plan runs at most this long, start to goal race.
    public static let maxSeasonMonths = 11

    /// A race's own block is at least the shortest single-race plan for its distance.
    public static func minBuildWeeks(_ race: SeasonRace) -> Int {
        category(forDistance: race.distanceMeters)?.minWeeks ?? 0
    }

    /// The first day the runner is ready to train again after `race`.
    static func recovered(after race: SeasonRace, level: RunnerLevel) -> Date {
        adding(recoveryDays(afterDistance: race.distanceMeters, level: level), to: race.date)
    }

    static func adding(_ days: Int, to date: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: date)!
    }

    /// Raced inside the next race's training: a half or shorter, and no longer than that race.
    static func canBeTuneUp(_ race: SeasonRace, before next: SeasonRace) -> Bool {
        race.distanceMeters <= 21097 && race.distanceMeters <= next.distanceMeters
    }

    /// The runner's weekdays cut to a block's own run count (a 10K block keeps the 10K plan's
    /// days inside a marathon season): long-run day kept, the rest as evenly spread as possible.
    public static func spreadDays(_ days: [Int], keeping longDay: Int, count: Int) -> [Int] {
        let pool = Array(Set(days)).sorted()
        guard count < pool.count, pool.contains(longDay) else { return pool }
        func minGap(_ set: [Int]) -> Int {
            zip(set, set.dropFirst() + [set[0] + 7]).map { $1 - $0 }.min() ?? 7
        }
        var best: [Int] = []
        func pick(_ from: Int, _ chosen: [Int]) {
            if chosen.count == count {
                if chosen.contains(longDay), best.isEmpty || minGap(chosen) > minGap(best) { best = chosen }
                return
            }
            for i in from..<pool.count { pick(i + 1, chosen + [pool[i]]) }
        }
        pick(0, [])
        return best
    }

    public static func layout(races input: [SeasonRace], start: Date, level: RunnerLevel) -> SeasonLayout {
        let cal = Calendar.current
        let start = cal.startOfDay(for: start)
        var issues: [SeasonIssue] = []
        let sorted = input.sorted { $0.date < $1.date }
        let races = sorted.filter { r in
            guard category(forDistance: r.distanceMeters) != nil else { issues.append(.unsupportedDistance(r)); return false }
            guard r.date > start else { issues.append(.raceBeforeStart(r)); return false }
            return true
        }
        guard let goal = races.last else { return SeasonLayout(races: [], priorities: [], blocks: [], issues: issues) }

        func days(_ a: Date, _ b: Date) -> Int { cal.dateComponents([.day], from: a, to: b).day ?? 0 }

        let priorities = assignPriorities(races, start: start, level: level)

        // Forward: bridge (if the gap outgrows the plan's maximum) → build → recovery.
        var blocks: [SeasonBlock] = []
        var cursor = start
        for (i, r) in races.enumerated() where priorities[i] != .tuneUp {
            let buildStart = max(cursor, adding(-7 * category(forDistance: r.distanceMeters)!.maxWeeks, to: r.date))
            if buildStart > cursor { blocks.append(SeasonBlock(kind: .bridge, start: cursor, end: buildStart)) }
            blocks.append(SeasonBlock(kind: .build(race: i), start: buildStart, end: r.date))
            cursor = adding(1, to: r.date)
            if priorities[i] == .block {
                let end = recovered(after: r, level: level)
                blocks.append(SeasonBlock(kind: .recovery(race: i), start: cursor, end: end))
                cursor = end
            }
        }

        // What the runner should know; blocking issues stop the plan, the layout still stands.
        if races.count > 1, let earliest = cal.date(byAdding: .month, value: -maxSeasonMonths, to: goal.date), earliest > start {
            issues.append(.seasonTooLong(earliestStart: earliest))
        }
        for (i, r) in races.enumerated().dropFirst() {
            if let prev = races[..<i].first(where: { r.date < recovered(after: $0, level: level) }) {
                issues.append(.tooSoonAfter(prev, r, days: days(prev.date, r.date)))
            }
        }
        for i in races.indices.dropLast() where priorities[i] == .tuneUp {
            let next = races[(i + 1)...].indices.first { priorities[$0] != .tuneUp }!
            if !canBeTuneUp(races[i], before: races[next]) {
                issues.append(.noRoomToTrain(races[i], weeks: minBuildWeeks(races[i])))
            } else if races[i].distanceMeters >= 21097 && days(races[i].date, goal.date) < 21 {
                issues.append(.longTuneUpNearGoal(races[i], days: days(races[i].date, goal.date)))
            }
        }
        if let goalBlock = blocks.last, case .build = goalBlock.kind {
            let w = days(goalBlock.start, goalBlock.end) / 7
            if w < minBuildWeeks(goal) { issues.append(.shortGoalBlock(weeks: w, minimum: minBuildWeeks(goal))) }
        }
        return SeasonLayout(races: races, priorities: priorities, blocks: blocks, issues: issues)
    }

    /// Which earlier races get their own block. Every way is tried (a season holds a handful of
    /// races); of those where each block gets its minimum build after the previous recovery,
    /// the one leaving the fewest races without a place wins, then the one with the most blocks.
    static func assignPriorities(_ races: [SeasonRace], start: Date, level: RunnerLevel) -> [RacePriority] {
        let goal = races.count - 1
        var best: (unplaced: Int, blocks: Int, priorities: [RacePriority])?
        // From all-blocks down, so on a tie the later races keep their blocks.
        for mask in (0..<(1 << goal)).reversed() {
            let p = races.indices.map { $0 == goal ? RacePriority.goal : mask & (1 << $0) != 0 ? .block : .tuneUp }
            let owners = races.indices.filter { p[$0] != .tuneUp }
            var free = start, fits = true
            for i in owners {
                let buildStart = adding(-7 * minBuildWeeks(races[i]), to: races[i].date)
                // A goal short of its minimum from the start is only a warning; after a recovery it doesn't fit.
                if buildStart < free && !(i == goal && free == start) { fits = false; break }
                free = recovered(after: races[i], level: level)
            }
            guard fits else { continue }
            let unplaced = races.indices.filter { i in
                p[i] == .tuneUp && !canBeTuneUp(races[i], before: races[owners.first { $0 > i }!])
            }.count
            if best.map({ (unplaced, -owners.count) < ($0.unplaced, -$0.blocks) }) ?? true {
                best = (unplaced, owners.count, p)
            }
        }
        return best!.priorities
    }
}
