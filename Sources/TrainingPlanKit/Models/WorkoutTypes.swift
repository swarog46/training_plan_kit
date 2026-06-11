//
//  WorkoutTypes.swift
//  RunPlan
//
//  Created by Dan Sh on 16/01/2025.
//

import Foundation

public struct WorkoutInterval: Identifiable, Codable, Equatable {
    public let id: Int64
    public let type: IntervalType
    public let duration: Double
    public let distance: Int64
    public let targetType: TargetType
    public let target: TargetRange

    public init(id: Int64, type: IntervalType, duration: Double, distance: Int64, targetType: TargetType, target: TargetRange) {
        self.id = id
        self.type = type
        self.duration = duration
        self.distance = distance
        self.targetType = targetType
        self.target = target
    }
    
    public static func == (lhs: WorkoutInterval, rhs: WorkoutInterval) -> Bool {
        return lhs.id == rhs.id &&
               lhs.type == rhs.type &&
               lhs.duration == rhs.duration &&
               lhs.distance == rhs.distance &&
               lhs.targetType == rhs.targetType &&
               lhs.target == rhs.target
    }
}

public struct WorkoutType: Identifiable, Codable, Equatable, Hashable {
    public var name: String

    public var id: String { self.name }

    enum CodingKeys: String, CodingKey {
        case name
    }

    // Default cases
    public static let easyRun = WorkoutType(name: "Easy Run")
    public static let longRun = WorkoutType(name: "Long Run")
    public static let progressionRun = WorkoutType(name: "Progression Run")
    public static let intervalRun = WorkoutType(name: "Intervals")
    public static let speedRun = WorkoutType(name: "Speed Run")
    public static let thresholdRun = WorkoutType(name: "Threshold")
    public static let fartlekRun = WorkoutType(name: "Fartlek Run")
    public static let recoveryRun = WorkoutType(name: "Recovery Run")
    public static let freeRun = WorkoutType(name: "Free Run")
    public static let race = WorkoutType(name: "Race")
    public static let cycling = WorkoutType(name: "Cycling")
    public static let yoga = WorkoutType(name: "Yoga")

    // Static array for default types
    public static var allCases: [WorkoutType] {
        [
            easyRun, longRun, progressionRun, intervalRun, speedRun, thresholdRun, fartlekRun, recoveryRun, freeRun, race, cycling, yoga
        ]
    }
    
    public init(name: String) {
        self.name = name
    }
    
    // Serializes as its name; decodes a bare string ("Long Run") or a { name } object.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let name = try? container.decode(String.self) {
            self.name = name
        } else {
            let keyed = try decoder.container(keyedBy: CodingKeys.self)
            self.name = try keyed.decode(String.self, forKey: .name)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(name)
    }
}

public enum WorkoutSubtype: String, CaseIterable, Identifiable, Codable {
    case intervals
    case pyramidIntervals
    case ladderIntervals
    case long
    case easy
    case progression
    case steadyLong
    case progressiveLong
    case recovery
    case tempo
    case speed
    case fartlek
    case threshold
    // Newer additions to align with Higdon / Daniels / Pfitzinger catalogs.
    case hillRepeats     // 8-12 × short hills, strength/power
    case strides         // easy run + 4-6 × 100m fast finishers (neuromuscular)
    case marathonPace    // continuous run at marathon goal pace
    case raceRehearsalM  // long run with marathon-pace segments (42K)
    case raceRehearsalHM // long run with half-marathon-pace segments (21K)
    case raceRehearsal10K // long run with 10K-pace fast tail (10K)
    case mileRepeats     // 4-6 × 1mile @ T pace (Daniels classic)
    case yasso800        // 10 × 800m, the iconic marathon predictor
    case timeTrial       // race-effort fitness check (3K-10K)
    case fivekPace       // short repeats at 5K race pace (5K-specific)
    case tenkPace        // sustained intervals at 10K race pace (10K-specific)
    case fastFinish      // long-ish easy run with race-pace tail (universal)
    case mediumLong      // Pfitz/Daniels signature 80-110min easy run (Wed ML slot)

    public var id: String { self.rawValue }

    /// The parent WorkoutType — used for color/icon when a subtype chip
    /// stands on its own (e.g. the plan-detail "Types of runs" section).
    /// Maps each fine-grained subtype back to one of the canonical types
    /// so the visual color stays consistent across the app.
    public var parentType: WorkoutType {
        switch self {
        case .easy, .recovery, .strides:
            return .easyRun
        case .long, .steadyLong, .progressiveLong, .mediumLong:
            return .longRun
        case .progression:
            return .progressionRun
        case .intervals, .pyramidIntervals, .ladderIntervals,
             .hillRepeats, .mileRepeats, .yasso800,
             .fivekPace, .tenkPace, .timeTrial, .raceRehearsal10K:
            return .intervalRun
        case .threshold, .tempo, .marathonPace, .fastFinish,
             .raceRehearsalM, .raceRehearsalHM:
            return .thresholdRun
        case .speed:
            return .speedRun
        case .fartlek:
            return .fartlekRun
        }
    }

    /// Subtypes that the Adaptive Pack (€7.99) unlocks. Free plans must
    /// not schedule these so the paid value prop ("race-anchor workouts")
    /// stays meaningful. See MONETIZATION.md "What's Free vs. Paid".
    public var isAdaptiveOnly: Bool {
        switch self {
        case .raceRehearsalM, .raceRehearsalHM, .raceRehearsal10K,
             .timeTrial, .mileRepeats, .yasso800, .marathonPace,
             .fivekPace, .tenkPace, .fastFinish:
            return true
        default:
            return false
        }
    }

    /// Race distances (in meters) for which this adaptive subtype is
    /// appropriate. Yasso 800s in a 5K plan are nonsensical regardless
    /// of entitlement; this filter prevents that. Standard (non-adaptive)
    /// subtypes return all distances. See PLAN_AUDIT_2026.md Finding 11.
    public var eligibleDistances: Set<Int64> {
        switch self {
        case .timeTrial:
            // Race-effort fitness check — useful at every distance.
            return [5000, 10000, 21097, 42195]
        case .mileRepeats:
            // 1mi @ T-pace — signature mid-distance workout, irrelevant for 5K.
            return [10000, 21097, 42195]
        case .raceRehearsalM:
            // Marathon-pace race rehearsal — marathon plans only.
            return [42195]
        case .raceRehearsalHM:
            // Half-marathon-pace race rehearsal — 21K plans only.
            return [21097]
        case .raceRehearsal10K:
            // 10K-pace fast-finish rehearsal — 10K plans only.
            return [10000]
        case .fivekPace:
            // Short repeats at 5K race pace — 5K plans only.
            return [5000]
        case .tenkPace:
            // Sustained intervals at 10K race pace — 10K plans (could
            // optionally extend to 5000 for 10K-pace tempo work).
            return [10000]
        case .fastFinish:
            // Long-ish easy run with brief race-pace tail. Conceptually a
            // long run with a fast tail — 5K plans don't have long runs
            // so fastFinish doesn't fit. 10K+ only.
            return [10000, 21097, 42195]
        case .yasso800:
            // Marathon-prediction folklore — marathon only.
            return [42195]
        case .marathonPace:
            // Goal MP work — marathon only (could extend to 21K if needed).
            return [42195]
        default:
            // Standard (free) subtypes — all distances + maintenance (0).
            return [0, 5000, 10000, 21097, 42195]
        }
    }
}

// TrainingType
public enum TrainingType: String, CaseIterable, Identifiable, Codable {
    case distanceBased = "Distance-based"
    case timeBased = "Time-based"
    case paceBased = "Pace-based"

    public var id: String { self.rawValue }
}

// TargetType
public enum TargetType: String, CaseIterable, Identifiable, Codable {
    case heartRate = "HRZone"
    case speed = "Speed"
    case noTarget = "NoTarget"

    public var id: String { self.rawValue }
}

// IntervalType
public enum IntervalType: String, CaseIterable, Identifiable, Codable {
    case warmup = "Warmup"
    case work = "Work"
    case recovery = "Recovery"
    case rest = "Rest"
    case cooldown = "Cooldown"
    case free = "Free"
    
    public var id: String { self.rawValue }
}

// TargetRange
public enum TargetRange: Codable, Equatable {
    case secondsRange(min: TimeInterval, max: TimeInterval)
    case heartRateZone(zone: Int)
    case paceTarget(basePace: Int, relative: Double)  // basePace in seconds/km, relative is multiplier
    case noRange(noValue: Bool)

    private enum CodingKeys: String, CodingKey {
        case type
        case min
        case max
        case zone
        case basePace
        case relative
        case noValue
    }

    private enum TargetType: String {
        case secondsRange
        case heartRateZone
        case paceTarget
        case noRange
    }
    
    public static func == (lhs: TargetRange, rhs: TargetRange) -> Bool {
        switch (lhs, rhs) {
        case let (.secondsRange(lMin, lMax), .secondsRange(rMin, rMax)):
            return lMin == rMin && lMax == rMax
        case let (.heartRateZone(lZone), .heartRateZone(rZone)):
            return lZone == rZone
        case let (.paceTarget(lPace, lRel), .paceTarget(rPace, rRel)):
            return lPace == rPace && lRel == rRel
        case (.noRange(_), .noRange(_)):
            return true
        default:
            return false
        }
    }

    // Encoding and Decoding
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .secondsRange(let min, let max):
            try container.encode(TargetType.secondsRange.rawValue, forKey: .type)
            try container.encode(min, forKey: .min)
            try container.encode(max, forKey: .max)
        case .heartRateZone(let zone):
            try container.encode(TargetType.heartRateZone.rawValue, forKey: .type)
            try container.encode(zone, forKey: .zone)
        case .paceTarget(let basePace, let relative):
            try container.encode(TargetType.paceTarget.rawValue, forKey: .type)
            try container.encode(basePace, forKey: .basePace)
            try container.encode(relative, forKey: .relative)
        case .noRange(let noRange):
            try container.encode(TargetType.noRange.rawValue, forKey: .type)
            try container.encode(noRange, forKey: .noValue)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case TargetType.secondsRange.rawValue:
            let min = try container.decode(TimeInterval.self, forKey: .min)
            let max = try container.decode(TimeInterval.self, forKey: .max)
            self = .secondsRange(min: min, max: max)
        case TargetType.heartRateZone.rawValue:
            let zone = try container.decode(Int.self, forKey: .zone)
            self = .heartRateZone(zone: zone)
        case TargetType.paceTarget.rawValue:
            let basePace = try container.decode(Int.self, forKey: .basePace)
            let relative = try container.decode(Double.self, forKey: .relative)
            self = .paceTarget(basePace: basePace, relative: relative)
        case TargetType.noRange.rawValue:
            let noValue = try container.decode(Bool.self, forKey: .noValue)
            self = .noRange(noValue: noValue)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Invalid target range type")
        }
    }
    
    /// The target rendered as a pace string ("4'55\"") when the target IS
    /// pace-based, else nil. Used for the completed-splits "target" column,
    /// which only makes sense for pace targets — HR-zone and no-range have no
    /// target pace, so the column is simply omitted for those. Self-contained
    /// (no LanguageManager) since the pace cases format numbers only.
    public var paceTargetStringIfAvailable: String? {
        switch self {
        case .paceTarget(let basePace, let relative):
            let secondsPerKm = Int(Double(basePace) * relative)
            return PaceConversion.formatPaceInUserUnits(secondsPerKm)
        case .secondsRange(let min, let max):
            let avg = (min + max) / 2
            return "\(Int(avg) / 60)'\(String(format: "%02d", Int(avg) % 60))\""
        case .heartRateZone, .noRange:
            return nil
        }
    }
}

/// MARK: - Workout Mode (Indoor/Outdoor)

/// Defines whether a workout is performed indoors (treadmill) or outdoors
public enum WorkoutMode: String, CaseIterable, Identifiable, Codable {
    case outdoor = "Outdoor"
    case indoor = "Indoor"

    public var id: String { rawValue }

    // MARK: - Display Properties

    /// User-friendly display name
    public var displayName: String { rawValue }

    /// SF Symbol icon name
    public var iconName: String {
        switch self {
        case .outdoor: return "figure.outdoor.cycle"  // Running outdoors
        case .indoor: return "figure.run.treadmill"   // Treadmill
        }
    }

    /// Short description for UI
    public var description: String {
        switch self {
        case .outdoor: return "Run outside with GPS tracking"
        case .indoor: return "Treadmill or indoor track"
        }
    }

    // MARK: - Feature Flags

    /// Whether this mode requires GPS location tracking
    public var requiresGPS: Bool {
        self == .outdoor
    }

    /// Whether this mode should track route/location data
    public var tracksRoute: Bool {
        self == .outdoor
    }

    /// Whether pace should be calculated from GPS (outdoor) or estimated (indoor)
    public var usesGPSPace: Bool {
        self == .outdoor
    }

    /// HealthKit location type for this mode
    public var healthKitLocationType: String {
        switch self {
        case .outdoor: return "outdoor"
        case .indoor: return "indoor"
        }
    }

    // MARK: - Factory Methods

    /// Toggle between modes
    public var toggled: WorkoutMode {
        self == .outdoor ? .indoor : .outdoor
    }
}

// MARK: - Pace Unit System

/// Represents the measurement unit for pace display
public enum PaceUnit: String {
    case kilometersPerMinute = "km"
    case milesPerMinute = "mi"

    /// Unit label for display (e.g., "/km" or "/mi")
    public var label: String {
        switch self {
        case .kilometersPerMinute: return "/km"
        case .milesPerMinute: return "/mi"
        }
    }

    /// Short label for compact displays
    public var shortLabel: String {
        switch self {
        case .kilometersPerMinute: return "km"
        case .milesPerMinute: return "mi"
        }
    }

    /// Get the appropriate unit based on user's locale
    public static var current: PaceUnit {
        let measurementSystem = Locale.current.measurementSystem
        return (measurementSystem == .metric) ? .kilometersPerMinute : .milesPerMinute
    }

    /// Whether this is the metric system
    public var isMetric: Bool {
        return self == .kilometersPerMinute
    }
}

// MARK: - Pace Conversion Utilities

/// Utility functions for pace unit conversions
public struct PaceConversion {

    /// Conversion factor: 1 mile = 1.609344 kilometers
    public static let kmPerMile: Double = 1.609344

    /// Convert pace from seconds/km to seconds/mile
    public static func kmToMile(_ secondsPerKm: Int) -> Int {
        return Int(Double(secondsPerKm) * kmPerMile)
    }

    /// Convert pace from seconds/km to seconds/mile (Double version)
    public static func kmToMile(_ secondsPerKm: Double) -> Double {
        return secondsPerKm * kmPerMile
    }

    /// Convert pace from seconds/mile to seconds/km
    public static func mileToKm(_ secondsPerMile: Int) -> Int {
        return Int(Double(secondsPerMile) / kmPerMile)
    }

    /// Convert pace to user's preferred unit system
    public static func convert(_ secondsPerKm: Int, to unit: PaceUnit) -> Int {
        switch unit {
        case .kilometersPerMinute:
            return secondsPerKm
        case .milesPerMinute:
            return kmToMile(secondsPerKm)
        }
    }

    /// Convert pace to user's preferred unit system (Double version)
    public static func convert(_ secondsPerKm: Double, to unit: PaceUnit) -> Double {
        switch unit {
        case .kilometersPerMinute:
            return secondsPerKm
        case .milesPerMinute:
            return kmToMile(secondsPerKm)
        }
    }

    /// Format pace as time string (e.g., "4:30")
    public static func formatTime(_ paceSeconds: Int) -> String {
        let minutes = paceSeconds / 60
        let seconds = paceSeconds % 60
        return "\(minutes):\(String(format: "%02d", seconds))"
    }

    /// Format pace as time string (Double version)
    public static func formatTime(_ paceSeconds: Double) -> String {
        return formatTime(Int(paceSeconds))
    }

    /// Format pace with unit label (e.g., "4:30/km")
    public static func formatPace(_ paceSeconds: Int, unit: PaceUnit) -> String {
        return "\(formatTime(paceSeconds))\(unit.label)"
    }

    /// Convert and format pace from km to user's unit with label
    public static func formatPaceInUserUnits(_ secondsPerKm: Int, unit: PaceUnit = .current) -> String {
        let convertedPace = convert(secondsPerKm, to: unit)
        return formatPace(convertedPace, unit: unit)
    }
}
