import XCTest
@testable import TrainingPlanKit

final class SeasonPlanBuilderTests: XCTestCase {
    private let cal = Calendar.current
    private let catalog = loadSampleCatalog()
    private func day(_ s: String) -> Date {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        return f.date(from: s)!
    }
    private func config(_ meters: Int) -> PlanConfiguration {
        var c = meters == 0 ? PlanConfiguration.maintenanceIntermediate
                            : PlanConfiguration.raceConfig(level: .intermediate, distanceMeters: meters)
        c.trainingDays = [2, 4, 6, 0]
        c.longestWorkoutDay = 0
        return c
    }
    private func build(_ races: [SeasonRace], start: String, fitness: @escaping (Date) -> VDOT? = { _ in nil })
        -> (SeasonLayout, [WorkoutEvent]) {
        let layout = SeasonPlanner.layout(races: races, start: day(start), level: .intermediate)
        let events = SeasonPlanBuilder.build(layout, level: .intermediate, catalog: catalog, planId: UUID(),
                                             config: { block in
                                                 guard case .build(let i) = block.kind else { return self.config(0) }
                                                 return self.config(layout.races[i].distanceMeters)
                                             }, fitness: fitness)
        return (layout, events)
    }

    func testTwoTenKsThenMarathon() {
        let races = [SeasonRace(date: day("2027-03-14"), distanceMeters: 10000),
                     SeasonRace(date: day("2027-06-06"), distanceMeters: 10000),
                     SeasonRace(date: day("2027-10-10"), distanceMeters: 42195)]
        let (layout, events) = build(races, start: "2027-01-04")

        let raceDays = events.filter { $0.workout.type == .race }
        XCTAssertEqual(raceDays.map(\.date), races.map(\.date))
        XCTAssertEqual(raceDays.map(\.workout.distance), [10000, 10000, 42195])
        XCTAssertEqual(Set(events.map { cal.startOfDay(for: $0.date) }).count, events.count, "one session a day")

        // Each build block is the standalone single-race plan for its window, except runs
        // shortened to the 30-day growth cap across block joins. The second 10K block may
        // swap quality sessions the first one ran for their twins, and nothing else.
        var firstTenK: Set<String> = []
        for block in layout.blocks {
            guard case .build(let i) = block.kind else { continue }
            let alone = createMarathonPlanV3(startDate: block.start, raceDate: block.end, from: catalog,
                                             planId: UUID(), config: config(races[i].distanceMeters))
            let inSeason = events.filter { $0.date >= block.start && $0.date <= block.end }
            XCTAssertEqual(inSeason.map(\.date), alone.map(\.date), "block \(i) keeps the single-race plan's days")
            for (s, a) in zip(inSeason, alone) where s.workout.id != a.workout.id {
                XCTAssertEqual(i, 1, "only a repeated block varies")
                assertTwins(s.workout, a.workout, notIn: firstTenK)
            }
            for (s, a) in zip(inSeason, alone) where s.workout.id == a.workout.id {
                XCTAssertLessThanOrEqual(s.workout.duration, a.workout.duration, "block \(i): only ever shortened")
            }
            if i == 0 { firstTenK = Set(inSeason.map(\.workout.key)) }
        }
        let opened = cal.date(byAdding: .day, value: 14, to: day("2027-01-04"))!
        for e in events where e.date >= opened && e.workout.type != .race {
            let longest = events.filter { $0.date < e.date && $0.date >= cal.date(byAdding: .day, value: -30, to: e.date)! }
                .map(\.workout.duration).max() ?? 0
            XCTAssertLessThanOrEqual(e.workout.duration, runGrowthCap(afterLongest: longest), "\(e.date): over the 30-day growth cap")
        }
        // Recovery weeks: easy only, nothing the day after the race.
        for block in layout.blocks {
            guard case .recovery = block.kind else { continue }
            let inBlock = events.filter { $0.date >= block.start && $0.date < block.end }
            XCTAssertFalse(inBlock.isEmpty)
            XCTAssertTrue(inBlock.allSatisfy { determineWorkoutCategory(workout: $0.workout) == .easy })
            XCTAssertFalse(inBlock.contains { cal.isDate($0.date, inSameDayAs: block.start) })
        }
        let weeks = events.map(\.planWeekIndex).filter { $0 >= 0 }
        XCTAssertEqual(weeks, weeks.sorted(), "week index runs through the season")
    }

    /// The recovery block ends on the day the next block starts; a tune-up there is raced once.
    func testTuneUpOnBlockBoundaryIsAddedOnce() {
        let first = SeasonRace(date: day("2027-03-14"), distanceMeters: 10000)
        let boundary = SeasonPlanner.recovered(after: first, level: .intermediate)
        let races = [first, SeasonRace(date: boundary, distanceMeters: 5000),
                     SeasonRace(date: day("2027-10-10"), distanceMeters: 42195)]
        let (layout, events) = build(races, start: "2027-01-04")
        XCTAssertEqual(layout.priorities, [.block, .tuneUp, .goal])
        XCTAssertEqual(events.filter { $0.workout.type == .race }.map(\.date), races.map(\.date))
    }

    /// Tune-up and block races before the goal are paced by the effort chosen; a half inside
    /// the goal's last three weeks is run controlled whatever was asked.
    func testRaceDayPaceFollowsEffort() {
        func paces(_ tenK: RaceEffort, _ half: RaceEffort) -> [Int] {
            var block = SeasonRace(date: day("2027-03-14"), distanceMeters: 10000)
            var late = SeasonRace(date: day("2027-09-26"), distanceMeters: 21097)
            block.effort = tenK
            late.effort = half
            let (_, events) = build([block, late, SeasonRace(date: day("2027-10-10"), distanceMeters: 42195)],
                                    start: "2027-01-04", fitness: { _ in VDOT(value: 45) })
            return events.filter { $0.workout.type == .race }.sorted { $0.date < $1.date }.prefix(2).compactMap(\.racePaceTarget)
        }
        func pace(_ meters: Int, _ effort: RaceEffort) -> Int {
            SeasonPlanBuilder.racePace(distanceMeters: meters, vdot: VDOT(value: 45), effort: effort)!
        }
        XCTAssertEqual(paces(.push, .push), [pace(10000, .push), pace(21097, .controlled)])
        XCTAssertEqual(paces(.controlled, .predicted), [pace(10000, .controlled), pace(21097, .controlled)])
        XCTAssertLessThan(pace(10000, .push), pace(10000, .predicted))
        XCTAssertGreaterThan(pace(10000, .controlled), pace(10000, .predicted))
        XCTAssertEqual(SeasonPlanner.efforts(for: SeasonRace(date: day("2027-09-26"), distanceMeters: 21097),
                                             goal: SeasonRace(date: day("2027-10-10"), distanceMeters: 42195)), [.controlled])
    }

    func testNextRaceIsTheFirstNotYetPast() {
        let races = [SeasonRace(date: day("2027-03-14"), distanceMeters: 10000),
                     SeasonRace(date: day("2027-10-10"), distanceMeters: 42195)]
        let (_, events) = build(races, start: "2027-01-04")
        let plan = Plan(name: "S", startDate: day("2027-01-04"), endDate: races[1].date, events: events, raceDistance: 42195)
        XCTAssertEqual(plan.nextRace(from: day("2027-02-01"))?.date, races[0].date)
        XCTAssertEqual(plan.nextRace(from: races[0].date)?.date, races[0].date, "race day itself")
        XCTAssertEqual(plan.nextRace(from: day("2027-03-15"))?.date, races[1].date)
        XCTAssertEqual(plan.nextRace(from: day("2027-12-01"))?.date, races[1].date, "past the plan: the goal race")
    }

    /// A twin: the same kind of quality session, as long and as hard, that the first block didn't run.
    private func assertTwins(_ twin: Workout, _ original: Workout, notIn done: Set<String>,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(twin.subtype, original.subtype, file: file, line: line)
        XCTAssertEqual(twin.peakZone, original.peakZone, file: file, line: line)
        XCTAssertLessThanOrEqual(abs(twin.minutes - original.minutes), 5, file: file, line: line)
        XCTAssertEqual(Double(twin.trainingLoad), Double(original.trainingLoad), accuracy: Double(max(twin.trainingLoad, original.trainingLoad)) * 0.10, file: file, line: line)
        XCTAssertEqual(twin.hardSeconds, original.hardSeconds, accuracy: max(twin.hardSeconds, original.hardSeconds) * 0.10, file: file, line: line)
        XCTAssertTrue(done.contains(original.key), "only sessions done before are swapped", file: file, line: line)
        XCTAssertFalse(done.contains(twin.key), file: file, line: line)
        XCTAssertNotNil(original.subtype.qualityRank, file: file, line: line)
        XCTAssertFalse(original.subtype.isLongRun, file: file, line: line)
    }

    /// A plan on its own never varies: there is nothing done before.
    func testAStandalonePlanIsUntouchedByVariety() {
        let config = config(10000)
        XCTAssertTrue(config.sessionsDoneBefore.isEmpty)
        func keys(_ c: PlanConfiguration) -> [String] {
            createMarathonPlanV3(startDate: day("2027-01-04"), raceDate: day("2027-03-14"), from: catalog, planId: UUID(), config: c)
                .map { "\($0.workout.key) \($0.workout.duration)" }
        }
        var seeded = config
        seeded.sessionsDoneBefore = ["no-such-session"]
        XCTAssertEqual(keys(seeded), keys(config), "keys that never come up change nothing")
    }

    func testTuneUpHalfInsideMarathonBlock() {
        let half = SeasonRace(date: day("2027-09-05"), distanceMeters: 21097)
        let (_, events) = build([half, SeasonRace(date: day("2027-10-10"), distanceMeters: 42195)],
                                start: "2027-05-23", fitness: { _ in VDOT(value: 45) })
        let tune = events.first { $0.workout.type == .race && $0.date == half.date }
        XCTAssertEqual(tune?.workout.distance, 21097)
        let pace = Int((Double(VDOT(value: 45).predictedTime(forDistanceMeters: 21097)!) * 1000 / 21097).rounded())
        XCTAssertEqual(tune?.workout.intervals.first?.target, .paceTarget(basePace: pace, relative: 1.0),
                       "a tune-up is paced for its own distance")
        let around = events.filter {
            let d = cal.dateComponents([.day], from: half.date, to: $0.date).day ?? 99
            return (-4...5).contains(d) && $0.date != half.date
        }
        XCTAssertTrue(around.allSatisfy { determineWorkoutCategory(workout: $0.workout) == .easy },
                      "no hard session or long run 4 days before / 5 after a half tune-up")
    }
}
