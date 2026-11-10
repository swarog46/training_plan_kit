import XCTest
@testable import TrainingPlanKit

final class FixedProtocolTests: XCTestCase {
    private let cal = Calendar.current
    private let catalog = loadSampleCatalog()
    private func day(_ s: String) -> Date {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        return f.date(from: s)!
    }
    private func events(_ config: PlanConfiguration, weeks: Int) -> [WorkoutEvent] {
        let start = day("2027-03-01")
        return createMarathonPlanV3(startDate: start, raceDate: cal.date(byAdding: .day, value: weeks * 7 - 1, to: start)!,
                                    from: catalog, planId: UUID(), config: config)
    }
    private func minutesByWeek(_ plan: FixedProtocol) -> [Int] {
        plan.weeks.indices.map { plan.workouts(week: $0).reduce(0) { $0 + $1.minutes } }
    }

    /// The same session the catalog's Couch to 5K holds, built in code: same length, same load.
    func testASessionMatchesTheCatalogsForm() throws {
        let graduation = try XCTUnwrap(catalog.first { $0.key == "c25k_w9" })
        let built = ProtocolSession.run(minutes: 30).workout(id: 1, key: "k")
        XCTAssertEqual(built.duration, graduation.duration)
        XCTAssertEqual(built.trainingLoad, graduation.trainingLoad)
        XCTAssertEqual(built.intervals.map(\.type), graduation.intervals.map(\.type))
        XCTAssertEqual(built.subtype, .easy)

        let repeats = ProtocolSession.runWalk(reps: 8, run: 60, walk: 90).workout(id: 2, key: "k")
        XCTAssertEqual(repeats.title, "Run/Walk (8 x 1min)")
        XCTAssertEqual(repeats.intervals.filter { $0.type == .work }.count, 8)
        XCTAssertEqual(repeats.intervals.filter { $0.type == .rest }.count, 7, "no walk after the last run: the cooldown is one")
        XCTAssertEqual(repeats.minutes, 5 + 8 + 10 + 5 + 0, "5 min walk, 8 x 1 min, 7 x 90 s rounded down, 5 min walk")
        XCTAssertEqual(ProtocolSession.runWalk(reps: 6, run: 30, walk: 150).title, "Run/Walk (6 x 30s)")
    }

    /// Walk to Run ends where Couch to 5K begins: 8 x 1 minute with 90-second walks.
    func testWalkToRunHandsOverToCouchTo5K() throws {
        let first = try XCTUnwrap(catalog.first { $0.key == "c25k_w1" })
        let last = try XCTUnwrap(FixedProtocol.walkToRun.workouts(week: 5).last)
        func runs(_ w: Workout) -> [Double] { w.intervals.filter { $0.type == .work }.map(\.duration) }
        func walks(_ w: Workout) -> [Double] { w.intervals.filter { $0.type == .rest }.map(\.duration) }
        XCTAssertEqual(runs(last), runs(first))
        XCTAssertEqual(walks(last).first, walks(first).first)

        let running = FixedProtocol.walkToRun.weeks.map { $0[0].runSeconds }
        XCTAssertEqual(running, running.sorted(), "more running every week")
        XCTAssertEqual(events(.walkToRun, weeks: 6).count, 18)
        XCTAssertTrue(events(.walkToRun, weeks: 6).allSatisfy { $0.workout.type != .race }, "no race at the end")
    }

    func testFiveToTenKBuildsTheLongRunGentlyAndEndsOnA10K() {
        let plan = events(.fiveToTenK, weeks: 8)
        XCTAssertEqual(plan.last?.workout.type, .race)
        XCTAssertEqual(plan.last?.workout.distance, 10000)
        XCTAssertEqual(plan.count, 7 * 3 + 2 + 1, "three runs a week, two and the 10K in the last")

        var longest = 30
        for week in FixedProtocol.fiveToTenK.weeks.dropLast() {
            let long = week.map { $0.runSeconds / 60 }.max()!
            XCTAssertLessThanOrEqual(long, Double(longest) * 1.15 + 1, "long run grows at most 15% over the longest so far")
            longest = max(longest, Int(long))
        }
        XCTAssertEqual(longest, 60)
        for (before, after) in zip(minutesByWeek(.fiveToTenK), minutesByWeek(.fiveToTenK).dropFirst().dropLast()) {
            XCTAssertLessThanOrEqual(Double(after), Double(before) * 1.2, "no week more than 20% over the last")
        }
    }

    func testReturnToRunningStartsWithRunWalkAndHasNoRace() {
        let plan = events(.returnToRunning, weeks: 4)
        XCTAssertEqual(plan.count, 12)
        XCTAssertTrue(plan.prefix(3).allSatisfy { $0.workout.subtype == .intervals })
        XCTAssertTrue(plan.suffix(6).allSatisfy { $0.workout.subtype == .easy })
        XCTAssertEqual(plan.last?.workout.title, "Run 30 min")
        let running = FixedProtocol.returnToRunning.weeks.map { $0.reduce(0) { $0 + $1.runSeconds } / 60 }
        XCTAssertEqual(running, [43, 55, 68, 80])
    }

    /// A shorter plan starts deeper in; a longer one repeats the last week. Days follow the runner's.
    func testLengthAndDays() {
        XCTAssertEqual(events(.walkToRun, weeks: 4).first?.workout.key, "walk_to_run_w3d1")
        XCTAssertEqual(events(.walkToRun, weeks: 8).suffix(3).map(\.workout.key),
                       ["walk_to_run_w6d1", "walk_to_run_w6d2", "walk_to_run_w6d3"])
        var twoDays = PlanConfiguration.returnToRunning
        twoDays.trainingDays = [2, 6]
        XCTAssertEqual(events(twoDays, weeks: 4).count, 8)
    }

    /// Sessions fall on the runner's days in the order written, the longest on the long-run day.
    func testSessionsKeepTheirOrderAndTheLongRunItsDay() {
        var config = PlanConfiguration.fiveToTenK
        config.trainingDays = [0, 2, 4]      // Sunday, Tuesday, Thursday
        config.longestWorkoutDay = 0
        let firstWeek = events(config, weeks: 8).prefix(3)
        XCTAssertEqual(firstWeek.map { cal.component(.weekday, from: $0.date) - 1 }, [2, 4, 0])
        XCTAssertEqual(firstWeek.map(\.workout.title), ["Run 30 min", "Run 30 min", "Run 35 min"])

        config.longestWorkoutDay = 2         // long run on Tuesday instead
        let moved = events(config, weeks: 8).prefix(3)
        XCTAssertEqual(moved.first { cal.component(.weekday, from: $0.date) - 1 == 2 }?.workout.title, "Run 35 min")

        let returning = events(.returnToRunning, weeks: 4).prefix(3).map(\.workout.title)
        XCTAssertEqual(returning, ["Run/Walk (5 x 2min)", "Run/Walk (5 x 3min)", "Run/Walk (6 x 3min)"])
    }

    func testProtocolWorkoutsHaveTheirOwnIdsAndKeys() {
        let all = [FixedProtocol.walkToRun, .fiveToTenK, .returnToRunning].flatMap { plan in
            plan.weeks.indices.flatMap { plan.workouts(week: $0) }
        }
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        XCTAssertEqual(Set(all.map(\.key)).count, all.count)
        XCTAssertTrue(Set(all.map(\.id)).isDisjoint(with: catalog.map(\.id)))
    }
}
