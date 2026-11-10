//
//  PlanChangeLedger.swift
//  TrainingPlanKit
//
//  One record of everything that changes how hard a plan is after it starts,
//  whoever asked for it: a measured result, a suggestion the runner accepted
//  or declined, paces they moved themselves. Every suggestion consults it, so
//  the plan is never nudged twice in a row and one kind of change is never
//  mistaken for another. Schedule edits (time off, races) are not in it: they
//  change when the runner runs, not how hard.
//

import Foundation

public struct PlanChange: Codable, Equatable {
    public enum Kind: String, Codable, CaseIterable {
        case fitness          // paces follow a measured result (time trial, race)
        case missedTraining   // paces eased after a gap
        case rebuilt          // remaining weeks rebuilt after a long gap
        case paceOffset       // the runner moved the paces by hand
        case eased            // intensity dropped to gentler; paces untouched
        case declined         // a suggestion answered "not now"

        /// The plan's paces are different afterwards.
        public var movesPaces: Bool {
            switch self {
            case .fitness, .missedTraining, .rebuilt, .paceOffset: return true
            case .eased, .declined: return false
            }
        }

        /// How runs feel afterwards says nothing about how they felt before: paces or
        /// intensity changed.
        public var resetsEffort: Bool { movesPaces || self == .eased }
    }

    public let kind: Kind
    public let date: Date

    public init(_ kind: Kind, on date: Date) {
        self.kind = kind
        self.date = date
    }
}

public struct PlanChangeLedger: Codable, Equatable {
    /// After any change or answered suggestion, no new suggestion for this long.
    public static let quietDays = 7
    /// Enough history for every rule here; older entries are dropped.
    static let kept = 30

    public private(set) var changes: [PlanChange] = []

    public init() {}

    public mutating func record(_ kind: PlanChange.Kind, on date: Date = Date()) {
        changes = Array((changes + [PlanChange(kind, on: date)]).sorted { $0.date < $1.date }.suffix(Self.kept))
    }

    /// The latest change of these kinds, up to `today`.
    public func last(_ kinds: Set<PlanChange.Kind>, asOf today: Date = Date()) -> Date? {
        changes.last { kinds.contains($0.kind) && $0.date <= today }?.date
    }

    /// The plan changed, or the runner answered a suggestion, within the last week:
    /// nothing new is suggested until they have lived with it.
    public func isQuiet(on today: Date = Date()) -> Bool {
        guard let latest = last(Set(PlanChange.Kind.allCases), asOf: today) else { return false }
        return Self.days(from: latest, to: today) < Self.quietDays
    }

    /// Since when ratings of how runs felt describe the plan as it is now.
    public func effortCountsSince(asOf today: Date = Date()) -> Date? {
        last(Set(PlanChange.Kind.allCases.filter(\.resetsEffort)), asOf: today)
    }

    private static func days(from start: Date, to end: Date) -> Int {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: start), to: cal.startOfDay(for: end)).day ?? 0
    }
}
