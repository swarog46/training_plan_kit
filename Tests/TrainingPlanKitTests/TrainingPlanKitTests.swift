import XCTest
import TrainingPlanKit

final class TrainingPlanKitTests: XCTestCase {

    func testSampleCatalogDecodes() {
        let catalog = loadSampleCatalog()
        XCTAssertGreaterThan(catalog.count, 50, "bundled sample catalog should decode")
    }

    func testGeneratePlanFillsEveryWeek() {
        let catalog = loadSampleCatalog()
        let plan = generatePlan(config: .intermediate42Default, totalWeeks: 18, catalog: catalog)
        XCTAssertEqual(plan.keys.count, 18)
        for (week, sessions) in plan {
            XCTAssertFalse(sessions.isEmpty, "week \(week) has no sessions")
        }
    }

    func testGeneratePlanIsDeterministic() {
        let catalog = loadSampleCatalog()
        let a = generatePlan(config: .intermediate42Default, totalWeeks: 18, catalog: catalog)
        let b = generatePlan(config: .intermediate42Default, totalWeeks: 18, catalog: catalog)
        XCTAssertEqual(a.keys.sorted(), b.keys.sorted())
        for week in a.keys {
            XCTAssertEqual(a[week]?.map { $0.workout.title },
                           b[week]?.map { $0.workout.title },
                           "week \(week) differs between two runs of the same inputs")
        }
    }

    func testPhaseDurationsSumToTotal() {
        let cases: [(PlanConfiguration, Int)] = [
            (.intermediate42Default, 18),
            (.beginner5Default, 10),
            (.competitive42Default, 24),
        ]
        for (config, weeks) in cases {
            let d = calculatePhaseDurations(config: config, totalWeeks: weeks)
            let sum = (d["base"] ?? 0) + (d["speed"] ?? 0) + (d["peak"] ?? 0) + (d["taper"] ?? 0)
            XCTAssertEqual(sum, weeks, "phase weeks must sum to plan length")
        }
    }

    func testCompetitivePeakCappedAtEightWeeks() {
        let d = calculatePhaseDurations(config: .competitive42Default, totalWeeks: 36)
        XCTAssertLessThanOrEqual(d["peak"] ?? 0, 8, "competitive PEAK is capped; extras go to BASE")
    }

    // MARK: - Accessible ("real life") tier

    /// The day-count matrix the app ships: 5K 2/3/4, 10K 2/3/4, 21K 3/4/5,
    /// 42K 4/4/5. MUST match RunningLevel.recommendedTrainingsPerWeek.
    func testAccessibleDayCounts() {
        let expected: [(PlanConfiguration, Int, String)] = [
            (.accessibleBeginner5Default, 2, "Beg 5K"),
            (.accessibleIntermediate5Default, 3, "Int 5K"),
            (.accessibleAdvanced5Default, 4, "Adv 5K"),
            (.accessibleBeginner10Default, 2, "Beg 10K"),
            (.accessibleIntermediate10Default, 3, "Int 10K"),
            (.accessibleAdvanced10Default, 4, "Adv 10K"),
            (.accessibleBeginner21Default, 3, "Beg 21K"),
            (.accessibleIntermediate21Default, 4, "Int 21K"),
            (.accessibleAdvanced21Default, 5, "Adv 21K"),
            (.accessibleBeginner42Default, 4, "Beg 42K"),
            (.accessibleIntermediate42Default, 4, "Int 42K"),
            (.accessibleAdvanced42Default, 5, "Adv 42K"),
        ]
        for (config, days, label) in expected {
            XCTAssertEqual(config.trainingDays.count, days, "\(label) should be \(days) days/wk")
        }
    }

    /// An accessible plan must never be heavier than its textbook counterpart
    /// (fewer-or-equal days and fewer-or-equal starting volume). The 3 unchanged
    /// cells (Adv 21K, Beg 42K, Adv 42K) are equal, which satisfies <=.
    func testAccessibleNeverHeavierThanTextbook() {
        let pairs: [(PlanConfiguration, PlanConfiguration, String)] = [
            (.accessibleBeginner5Default, .beginner5Default, "Beg 5K"),
            (.accessibleIntermediate5Default, .intermediate5Default, "Int 5K"),
            (.accessibleAdvanced5Default, .advanced5Default, "Adv 5K"),
            (.accessibleBeginner10Default, .beginner10Default, "Beg 10K"),
            (.accessibleIntermediate10Default, .intermediate10Default, "Int 10K"),
            (.accessibleAdvanced10Default, .advanced10Default, "Adv 10K"),
            (.accessibleBeginner21Default, .beginner21Default, "Beg 21K"),
            (.accessibleIntermediate21Default, .intermediate21Default, "Int 21K"),
            (.accessibleAdvanced21Default, .advanced21Default, "Adv 21K"),
            (.accessibleBeginner42Default, .beginner42Default, "Beg 42K"),
            (.accessibleIntermediate42Default, .intermediate42Default, "Int 42K"),
            (.accessibleAdvanced42Default, .advanced42Default, "Adv 42K"),
        ]
        for (acc, ideal, label) in pairs {
            XCTAssertLessThanOrEqual(acc.trainingDays.count, ideal.trainingDays.count,
                                     "\(label): accessible days must be <= textbook")
            XCTAssertLessThanOrEqual(acc.initialWeeklyDuration, ideal.initialWeeklyDuration,
                                     "\(label): accessible volume must be <= textbook")
        }
    }

    /// Every accessible config must still generate a complete, periodized plan.
    func testAccessiblePlansFillEveryWeek() {
        let catalog = loadSampleCatalog()
        let cases: [(PlanConfiguration, Int, String)] = [
            (.accessibleBeginner5Default, 7, "Beg 5K"),
            (.accessibleIntermediate5Default, 7, "Int 5K"),
            (.accessibleBeginner10Default, 9, "Beg 10K"),
            (.accessibleIntermediate10Default, 9, "Int 10K"),
            (.accessibleBeginner21Default, 14, "Beg 21K"),
            (.accessibleIntermediate42Default, 18, "Int 42K"),
        ]
        for (config, weeks, label) in cases {
            let plan = generatePlan(config: config, totalWeeks: weeks, catalog: catalog)
            XCTAssertEqual(plan.keys.count, weeks, "\(label) should fill \(weeks) weeks")
            for (week, sessions) in plan {
                XCTAssertFalse(sessions.isEmpty, "\(label) week \(week) has no sessions")
            }
        }
    }

    func testAccessiblePhaseDurationsSumToTotal() {
        // Lengths must be >= each config's minimum phase-week sum (beginner
        // configs floor at 8 weeks, same as textbook) or the phases can't
        // sum to a shorter requested length (the plan front-trims instead).
        let cases: [(PlanConfiguration, Int)] = [
            (.accessibleBeginner5Default, 10),
            (.accessibleBeginner10Default, 9),
            (.accessibleIntermediate42Default, 18),
        ]
        for (config, weeks) in cases {
            let d = calculatePhaseDurations(config: config, totalWeeks: weeks)
            let sum = (d["base"] ?? 0) + (d["speed"] ?? 0) + (d["peak"] ?? 0) + (d["taper"] ?? 0)
            XCTAssertEqual(sum, weeks, "accessible phase weeks must sum to plan length")
        }
    }

    // MARK: - Accessible tier: structural invariants
    // The same guarantees the app-side PlanGeneratorV3Tests enforce on the
    // textbook configs, run here against the configs the app actually ships.

    /// Every accessible config at recommended length, with the plan length.
    private static let accessibleCases: [(PlanConfiguration, Int, String)] = [
        (.accessibleBeginner5Default, 7, "Beg 5K"),
        (.accessibleIntermediate5Default, 7, "Int 5K"),
        (.accessibleAdvanced5Default, 7, "Adv 5K"),
        (.accessibleBeginner10Default, 9, "Beg 10K"),
        (.accessibleIntermediate10Default, 9, "Int 10K"),
        (.accessibleAdvanced10Default, 9, "Adv 10K"),
        (.accessibleBeginner21Default, 14, "Beg 21K"),
        (.accessibleIntermediate21Default, 14, "Int 21K"),
        (.accessibleAdvanced21Default, 14, "Adv 21K"),
        (.accessibleBeginner42Default, 18, "Beg 42K"),
        (.accessibleIntermediate42Default, 18, "Int 42K"),
        (.accessibleAdvanced42Default, 18, "Adv 42K"),
    ]

    private static let longSubtypes: Set<WorkoutSubtype> =
        [.long, .steadyLong, .progressiveLong, .raceRehearsalM, .raceRehearsalHM, .raceRehearsal10K]
    private static let hardSubtypes: Set<WorkoutSubtype> =
        [.intervals, .ladderIntervals, .threshold, .hillRepeats, .timeTrial]

    /// At most one long run per week, in every accessible plan.
    func testAccessibleMaxOneLongRunPerWeek() {
        let catalog = loadSampleCatalog()
        for (config, weeks, label) in Self.accessibleCases {
            let plan = generatePlan(config: config, totalWeeks: weeks, catalog: catalog)
            for (week, sessions) in plan {
                let longs = sessions.filter { Self.longSubtypes.contains($0.workout.subtype) }.count
                XCTAssertLessThanOrEqual(longs, 1, "\(label) week \(week): \(longs) long runs")
            }
        }
    }

    /// Any long run present is at least 60 minutes (duration is in seconds).
    func testAccessibleLongRunsAtLeastSixtyMinutes() {
        let catalog = loadSampleCatalog()
        for (config, weeks, label) in Self.accessibleCases {
            let plan = generatePlan(config: config, totalWeeks: weeks, catalog: catalog)
            for (week, sessions) in plan {
                for s in sessions where Self.longSubtypes.contains(s.workout.subtype) {
                    XCTAssertGreaterThanOrEqual(s.workout.duration, 3600,
                        "\(label) week \(week): long run \(s.workout.duration / 60)min < 60min")
                }
            }
        }
    }

    /// Load builds (peak isn't week 1) and tapers (final week below peak).
    func testAccessibleLoadBuildsThenTapers() {
        let catalog = loadSampleCatalog()
        for (config, weeks, label) in Self.accessibleCases {
            let plan = generatePlan(config: config, totalWeeks: weeks, catalog: catalog)
            let keys = plan.keys.sorted()
            let weekLoads = keys.map { k in
                (plan[k] ?? []).reduce(Int64(0)) { $0 + $1.workout.trainingLoad }
            }
            guard let peak = weekLoads.max(), let peakIdx = weekLoads.firstIndex(of: peak) else { continue }
            XCTAssertGreaterThan(peakIdx, 0, "\(label): peak load should not be week 1")
            XCTAssertLessThan(weekLoads.last ?? peak, peak, "\(label): final (taper) week should be below peak")
        }
    }

    /// The race/taper week (last week) carries no hard quality workout.
    func testAccessibleRaceWeekHasNoQuality() {
        let catalog = loadSampleCatalog()
        for (config, weeks, label) in Self.accessibleCases {
            let plan = generatePlan(config: config, totalWeeks: weeks, catalog: catalog)
            guard let lastKey = plan.keys.max() else { continue }
            let hard = (plan[lastKey] ?? []).filter { Self.hardSubtypes.contains($0.workout.subtype) }
            XCTAssertTrue(hard.isEmpty,
                "\(label) race week has quality: \(hard.map { $0.workout.subtype.rawValue })")
        }
    }

    /// Within each distance, total load climbs beginner <= intermediate <= advanced.
    func testAccessibleVolumeLadderByLevel() {
        let catalog = loadSampleCatalog()
        func total(_ c: PlanConfiguration, _ w: Int) -> Int64 {
            generatePlan(config: c, totalWeeks: w, catalog: catalog)
                .values.flatMap { $0 }.reduce(0) { $0 + $1.workout.trainingLoad }
        }
        let groups: [(PlanConfiguration, PlanConfiguration, PlanConfiguration, Int, String)] = [
            (.accessibleBeginner5Default, .accessibleIntermediate5Default, .accessibleAdvanced5Default, 7, "5K"),
            (.accessibleBeginner10Default, .accessibleIntermediate10Default, .accessibleAdvanced10Default, 9, "10K"),
            (.accessibleBeginner21Default, .accessibleIntermediate21Default, .accessibleAdvanced21Default, 14, "21K"),
            (.accessibleBeginner42Default, .accessibleIntermediate42Default, .accessibleAdvanced42Default, 18, "42K"),
        ]
        for (b, i, a, w, label) in groups {
            let lb = total(b, w), li = total(i, w), la = total(a, w)
            XCTAssertLessThanOrEqual(lb, li, "\(label): beginner load <= intermediate")
            XCTAssertLessThanOrEqual(li, la, "\(label): intermediate load <= advanced")
        }
    }
}
