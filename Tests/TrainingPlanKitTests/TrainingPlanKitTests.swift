import XCTest
@testable import TrainingPlanKit

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

    // MARK: - FIX 2: no consecutive build-phase deloads

    /// Walk a plan week-by-week through the real target model and return the
    /// (phase, isDeloading) of each week — the same path the generator uses.
    private func weeklyDeloadFlags(_ config: PlanConfiguration, _ weeks: Int)
        -> [(phase: TrainingPhase, deload: Bool)] {
        let d = calculatePhaseDurations(config: config, totalWeeks: weeks)
        let base = d["base"] ?? 0, speed = d["speed"] ?? 0
        let peak = d["peak"] ?? 0, taper = d["taper"] ?? 0
        return (0..<weeks).map { w in
            let (phase, wip) = determinePhaseV3(
                weekIndex: w, baseDur: base, speedDur: speed, peakDur: peak, taperDur: taper)
            let t = calculateWeeklyTargetsV3(
                weekInPlan: w, weekInPhase: wip, phase: phase, phaseDurations: d, config: config)
            return (phase, t.isDeloading)
        }
    }

    /// No build phase (base/speed/peak) may emit two [deload] weeks back-to-back.
    /// Was broken on phases >= 10w (phase-end deload stacked) and where a 3:1
    /// recovery landed beside the trailing deload. Taper weeks (all deloads) are
    /// excluded — a taper is a correct progressive deload. Maintenance is excluded
    /// too: it runs its OWN recovery cadence whose 2-week opening easy ramp is a
    /// LEGITIMATE consecutive-light pair (its [deload] tags mark gentle cutbacks,
    /// not wasted race-build deloads) — checked separately below.
    func testNoConsecutiveBuildPhaseDeloads() {
        // Covers every audit offender (long PEAK/BASE) plus short-phase plans
        // whose 1-week PEAK / 4-week phases must stay exactly as before.
        let cases: [(PlanConfiguration, Int, String)] = [
            (.advanced42Default, 18, "Adv 42K rec"),
            (.advanced42Default, 22, "Adv 42K long"),
            (.intermediate42Default, 18, "Int 42K rec"),
            (.beginner42Default, 18, "Beg 42K rec"),
            (.competitive42Default, 18, "Cmp 42K rec"),
            (.competitive42Default, 28, "Cmp 42K build"),
            (.competitive42Default, 36, "Cmp 42K max"),
            (.competitive21Default, 32, "Cmp 21K max"),
            (.accessibleAdvanced42Default, 18, "Acc Adv 42K rec"),
            (.accessibleBeginner5Default, 7, "Acc Beg 5K rec"),
        ]
        let buildPhases: Set<TrainingPhase> = [.base, .speed, .peak]
        for (config, weeks, name) in cases {
            let flags = weeklyDeloadFlags(config, weeks)
            for i in 1..<flags.count {
                let prev = flags[i - 1], cur = flags[i]
                let bothBuildDeload = prev.deload && cur.deload
                    && buildPhases.contains(prev.phase) && buildPhases.contains(cur.phase)
                XCTAssertFalse(
                    bothBuildDeload,
                    "\(name): consecutive build-phase deloads at W\(i)/W\(i + 1) "
                    + "(\(prev.phase)/\(cur.phase))")
            }
        }
    }

    /// Maintenance [deload] tags must mark the genuinely light cadence weeks — the
    /// 2-week opening easy ramp (W1-2) plus every 4th week (W6, W10, …) — and only
    /// those. This is the maintenance counterpart to the race-build deload guard.
    func testMaintenanceDeloadTagsMarkLightCadenceWeeks() {
        for (config, weeks, name) in [
            (PlanConfiguration.maintenanceBeginner, 12, "Maint Beg"),
            (PlanConfiguration.maintenanceIntermediate, 12, "Maint Int"),
            (PlanConfiguration.maintenanceAdvanced, 12, "Maint Adv"),
        ] {
            let flags = weeklyDeloadFlags(config, weeks)
            for (w, f) in flags.enumerated() {
                XCTAssertEqual(
                    f.deload, MaintenancePlanGenerator.isLightWeek(week: w),
                    "\(name) W\(w + 1): [deload] tag must equal the maintenance light-week cadence")
            }
        }
    }

    // MARK: - FIX 3: rehearsal segment is subtype-aware (M/HM Z3, 10K Z4)

    /// The race-pace block lives in Z3 for the marathon/half (MP/HMP) and Z4 for
    /// the 10K (10KP is threshold-zone), and each has its own ramp ladder. The
    /// generalized reader/ladder must reflect that, else HM/10K segments aren't
    /// ramped and regress (the bug). A whole-plan check lives in the python suite.
    func testRehearsalSegmentZoneAndLadderBySubtype() {
        XCTAssertEqual(PlanGeneratorV3.rehearsalSegmentZone(.raceRehearsalM), 3)
        XCTAssertEqual(PlanGeneratorV3.rehearsalSegmentZone(.raceRehearsalHM), 3)
        XCTAssertEqual(PlanGeneratorV3.rehearsalSegmentZone(.raceRehearsal10K), 4)
        // Each ladder is strictly increasing (so occurrence-stepping never regresses)
        // and scaled to its race: marathon biggest, 10K smallest.
        for (sub, ladder) in [
            (WorkoutSubtype.raceRehearsalM, PlanGeneratorV3.rehearsalMPLadder),
            (.raceRehearsalHM, PlanGeneratorV3.rehearsalHMPLadder),
            (.raceRehearsal10K, PlanGeneratorV3.rehearsal10KLadder),
        ] {
            XCTAssertEqual(PlanGeneratorV3.rehearsalSegmentLadder(sub), ladder)
            XCTAssertEqual(ladder, ladder.sorted(), "\(sub) ladder must be ascending")
            XCTAssertEqual(Set(ladder).count, ladder.count, "\(sub) ladder has no dup rungs")
        }
        XCTAssertGreaterThan(PlanGeneratorV3.rehearsalMPLadder.max()!,
                             PlanGeneratorV3.rehearsalHMPLadder.max()!)
        XCTAssertGreaterThan(PlanGeneratorV3.rehearsalHMPLadder.max()!,
                             PlanGeneratorV3.rehearsal10KLadder.max()!)
    }

    // MARK: - FIX 5: strides reps must be >=15s

    /// <15s strides reps are too short; the pool filter drops any strides whose
    /// Z5 rep is <15s (the easy Z2 warm-up never counts). 15s is Daniels' short
    /// end and is allowed. A whole-plan check lives in the python suite.
    func testHasShortStrideRepFlagsSub20sRepsOnly() {
        func strides(repSecs: Double) -> Workout {
            let ivs = [
                WorkoutInterval(id: 0, type: .work, duration: 1500, distance: 0,
                                targetType: .heartRate, target: .heartRateZone(zone: 2)),
                WorkoutInterval(id: 1, type: .work, duration: repSecs, distance: 0,
                                targetType: .heartRate, target: .heartRateZone(zone: 5)),
                WorkoutInterval(id: 2, type: .work, duration: repSecs, distance: 0,
                                targetType: .heartRate, target: .heartRateZone(zone: 5)),
            ]
            return Workout(
                id: 1, title: "Easy + Strides", type: .easyRun, subtype: .strides,
                trainingType: .timeBased, targetType: .heartRate, duration: 1530,
                distance: 0, key: "s", trainingLoad: 2000, intervals: ivs,
                workRestRatio: 1, workDuration: 1530, restDuration: 0,
                workDistance: 0, restDistance: 0)
        }
        XCTAssertTrue(PlanGeneratorV3.hasShortStrideRep(strides(repSecs: 10)),
                      "10s rep must be flagged short (<15s)")
        XCTAssertFalse(PlanGeneratorV3.hasShortStrideRep(strides(repSecs: 15)),
                       "15s rep is OK (Daniels' short end)")
        XCTAssertFalse(PlanGeneratorV3.hasShortStrideRep(strides(repSecs: 25)),
                       "25s rep is OK")
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
