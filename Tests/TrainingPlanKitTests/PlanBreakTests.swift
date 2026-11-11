import XCTest
@testable import TrainingPlanKit

final class PlanBreakTests: XCTestCase {
    private let cal = Calendar.current
    private let catalog = loadSampleCatalog()
    private func day(_ s: String) -> Date {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        return f.date(from: s)!
    }
    /// An Advanced half plan: five runs a week, with long runs and quality sessions.
    private lazy var plan: [WorkoutEvent] = {
        var config = PlanConfiguration.raceConfig(level: .advanced, distanceMeters: 21097)
        config.trainingDays = [1, 2, 4, 6, 0]
        config.longestWorkoutDay = 0
        return createMarathonPlanV3(startDate: day("2027-01-04"), raceDate: day("2027-04-11"), from: catalog, planId: UUID(), config: config)
    }()

    func testTimeOffDropsEveryRunInTheDaysButNotTheRace() {
        let off = PlanBreak.timeOff(plan, from: day("2027-02-08"), through: day("2027-02-14"))
        XCTAssertEqual(off.count, plan.filter { $0.date >= day("2027-02-08") && $0.date < day("2027-02-15") }.count)
        XCTAssertFalse(off.isEmpty)
        XCTAssertTrue(PlanBreak.timeOff(plan, from: day("2027-04-11"), through: day("2027-04-11")).isEmpty, "race day stays")
    }

    func testTimeOffLeavesWhatIsDoneOrAlreadyDropped() {
        var events = plan
        let inWindow = events.indices.filter { events[$0].date >= day("2027-02-08") && events[$0].date < day("2027-02-15") }
        events[inWindow[0]].isCompleted = true
        events[inWindow[1]].isCancelled = true
        XCTAssertEqual(PlanBreak.timeOff(events, from: day("2027-02-08"), through: day("2027-02-14")).count, inWindow.count - 2)
    }

    /// A rebuild (new ids, fresh runs) must not bring back a week the runner took off.
    func testRebuiltWeeksKeepTheDaysOff() {
        var existing = plan
        let off = Set(PlanBreak.timeOff(plan, from: day("2027-02-08"), through: day("2027-02-14")).map(\.id))
        for i in existing.indices where off.contains(existing[i].id) { existing[i].isCancelled = true }
        var rebuilt = plan
        for i in rebuilt.indices { rebuilt[i].isCancelled = false }
        let merged = SeasonEdit.merged(existing, rebuilt: rebuilt, cut: day("2027-02-01"), seasonStart: day("2027-01-04"))
        let droppedDays = merged.filter(\.isCancelled).map { cal.startOfDay(for: $0.date) }
        XCTAssertEqual(droppedDays.count, off.count)
        XCTAssertTrue(droppedDays.allSatisfy { $0 >= day("2027-02-08") && $0 < day("2027-02-15") })
        XCTAssertFalse(merged.contains { $0.workout.type == .race && $0.isCancelled })
    }

    func testBusyWeekKeepsTheLongRunAndOneQualitySession() {
        let monday = cal.dateInterval(of: .weekOfYear, for: day("2027-03-03"))!.start
        let week = plan.filter { $0.date >= monday && $0.date < cal.date(byAdding: .day, value: 7, to: monday)! }
        let dropped = PlanBreak.busyWeek(plan, today: monday)
        let kept = week.filter { event in !dropped.contains { $0.id == event.id } }
        XCTAssertEqual(kept.count, 2, "\(week.map(\.workout.title))")
        XCTAssertTrue(kept.contains { $0.workout.subtype.isLongRun })
        XCTAssertTrue(kept.contains { $0.workout.subtype.qualityRank != nil && !$0.workout.subtype.isLongRun })
        XCTAssertEqual(dropped.count, week.count - kept.count)
    }

    func testBusyWeekOnlyTouchesWhatIsLeftOfTheWeek() {
        let monday = cal.dateInterval(of: .weekOfYear, for: day("2027-03-03"))!.start
        let friday = cal.date(byAdding: .day, value: 4, to: monday)!
        let dropped = PlanBreak.busyWeek(plan, today: friday)
        XCTAssertTrue(dropped.allSatisfy { $0.date >= friday })
        XCTAssertTrue(PlanBreak.busyWeek(plan, today: day("2027-06-01")).isEmpty, "after the plan: nothing")
    }
}
