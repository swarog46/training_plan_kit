import XCTest
@testable import TrainingPlanKit

final class SeasonPlannerTests: XCTestCase {
    private let cal = Calendar.current
    private func day(_ s: String) -> Date {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        return f.date(from: s)!
    }
    private func race(_ d: String, _ m: Int) -> SeasonRace { SeasonRace(date: day(d), distanceMeters: m) }
    private func weeks(_ b: SeasonBlock) -> Int { (cal.dateComponents([.day], from: b.start, to: b.end).day ?? 0) / 7 }

    /// Q's example: 10K (week 10) + 10K (week 22) + marathon (week 40).
    func testTwoTenKsThenMarathon() {
        let s = SeasonPlanner.layout(races: [race("2027-10-10", 42195), race("2027-03-14", 10000), race("2027-06-06", 10000)],
                                     start: day("2027-01-04"), level: .intermediate)
        XCTAssertEqual(s.races.map(\.distanceMeters), [10000, 10000, 42195], "sorted by date")
        XCTAssertEqual(s.priorities, [.block, .block, .goal])
        XCTAssertEqual(s.blocks.map(\.kind), [.build(race: 0), .recovery(race: 0), .bridge,
                                              .build(race: 1), .recovery(race: 1), .build(race: 2)])
        XCTAssertEqual(weeks(s.blocks[3]), 10, "second 10K gets the full 10-week 10K plan")
        XCTAssertEqual(weeks(s.blocks[5]), 17, "marathon block = everything after the second recovery")
        XCTAssertTrue(s.issues.isEmpty, "\(s.issues)")
        // Contiguous: each block starts where the previous ends; a build ends on
        // race day and the next block starts the day after.
        for (a, b) in zip(s.blocks, s.blocks.dropFirst()) {
            let gap = cal.dateComponents([.day], from: a.end, to: b.start).day
            if case .build = a.kind { XCTAssertEqual(gap, 1) } else { XCTAssertEqual(gap, 0) }
        }
    }

    /// A race that would eat into the goal's minimum block is a tune-up in it.
    func testHalfFiveWeeksOutIsATuneUp() {
        let s = SeasonPlanner.layout(races: [race("2027-09-05", 21097), race("2027-10-10", 42195)],
                                     start: day("2027-05-23"), level: .intermediate)
        XCTAssertEqual(s.priorities, [.tuneUp, .goal])
        XCTAssertEqual(s.blocks.map(\.kind), [.build(race: 1)], "exactly the 20-week maximum: no bridge")
        XCTAssertTrue(s.issues.isEmpty)
    }

    func testLongTuneUpTooCloseToGoalWarns() {
        let s = SeasonPlanner.layout(races: [race("2027-09-26", 21097), race("2027-10-10", 42195)],
                                     start: day("2027-05-03"), level: .intermediate)
        XCTAssertEqual(s.issues, [.longTuneUpNearGoal(race("2027-09-26", 21097), days: 14)])
    }

    func testShortGoalBlockWarns() {
        let s = SeasonPlanner.layout(races: [race("2027-10-10", 42195)], start: day("2027-08-15"), level: .advanced)
        XCTAssertEqual(s.issues, [.shortGoalBlock(weeks: 8, minimum: 14)])
    }

    func testTenKsSixDaysApartBlock() {
        let s = SeasonPlanner.layout(races: [race("2027-04-04", 10000), race("2027-04-10", 10000)],
                                     start: day("2027-01-04"), level: .intermediate)
        XCTAssertEqual(s.priorities, [.tuneUp, .goal])
        XCTAssertEqual(s.issues, [.tooSoonAfter(race("2027-04-04", 10000), race("2027-04-10", 10000), days: 6)])
        XCTAssertTrue(s.issues.contains(where: \.blocksPlan))
    }

    /// Each marathon needs its 14-week build plus recovery: four in ten months don't fit.
    func testFourMarathonsDontFit() {
        let marathons = ["2027-03-07", "2027-05-30", "2027-08-01", "2027-10-31"].map { race($0, 42195) }
        let s = SeasonPlanner.layout(races: marathons, start: day("2027-01-04"), level: .advanced)
        XCTAssertEqual(s.priorities, [.tuneUp, .block, .tuneUp, .goal])
        XCTAssertEqual(s.issues, [.noRoomToTrain(marathons[0], weeks: 14), .noRoomToTrain(marathons[2], weeks: 14)])
    }

    func testTwoMarathonsFit() {
        let s = SeasonPlanner.layout(races: [race("2027-04-25", 42195), race("2027-10-10", 42195)],
                                     start: day("2027-01-04"), level: .intermediate)
        XCTAssertEqual(s.priorities, [.block, .goal])
        XCTAssertTrue(s.issues.isEmpty, "\(s.issues)")
    }

    /// A half can't be a tune-up for a 10K, nor a 30K for anything: no room for their own block blocks the plan.
    func testLongRaceIsNeverATuneUp() {
        let s = SeasonPlanner.layout(races: [race("2027-03-07", 30000), race("2027-05-16", 21097), race("2027-06-06", 10000)],
                                     start: day("2027-01-04"), level: .intermediate)
        XCTAssertEqual(s.priorities, [.tuneUp, .tuneUp, .goal])
        XCTAssertEqual(s.issues, [.noRoomToTrain(race("2027-03-07", 30000), weeks: 16),
                                  .noRoomToTrain(race("2027-05-16", 21097), weeks: 12)])
    }

    func testSeasonUpToElevenMonths() {
        let s = SeasonPlanner.layout(races: [race("2027-03-14", 10000), race("2027-12-12", 42195)],
                                     start: day("2027-01-04"), level: .intermediate)
        XCTAssertEqual(s.issues, [.seasonTooLong(earliestStart: day("2027-01-12"))])
        let single = SeasonPlanner.layout(races: [race("2027-12-12", 42195)], start: day("2027-01-04"), level: .intermediate)
        XCTAssertTrue(single.issues.isEmpty, "one race isn't a season")
    }

    func testDropsUnsupportedAndPastRaces() {
        let s = SeasonPlanner.layout(races: [race("2027-02-01", 10000), race("2027-05-02", 12000), race("2027-06-06", 21097)],
                                     start: day("2027-03-01"), level: .beginner)
        XCTAssertEqual(s.races.map(\.distanceMeters), [21097])
        XCTAssertEqual(Set(s.issues), [.raceBeforeStart(race("2027-02-01", 10000)), .unsupportedDistance(race("2027-05-02", 12000))])
    }

    func testPlanDistanceForOddRaces() {
        XCTAssertEqual(SeasonPlanner.planDistance(forRaceMeters: 20000), 21097)
        XCTAssertEqual(SeasonPlanner.planDistance(forRaceMeters: 12000), 10000)
        XCTAssertEqual(SeasonPlanner.planDistance(forRaceMeters: 42195), 42195)
        XCTAssertNil(SeasonPlanner.planDistance(forRaceMeters: 100000))
        XCTAssertNil(SeasonPlanner.planDistance(forRaceMeters: 3000))
    }

    func testSpreadDaysKeepsLongRunAndSpacing() {
        // Tue Thu Sat Sun, long run Sunday -> 3 runs: Tue Thu Sun (Sat would sit next to Sunday).
        XCTAssertEqual(SeasonPlanner.spreadDays([2, 4, 6, 0], keeping: 0, count: 3), [0, 2, 4])
        XCTAssertEqual(SeasonPlanner.spreadDays([1, 3, 5, 6], keeping: 6, count: 2), [3, 6])
        XCTAssertEqual(SeasonPlanner.spreadDays([1, 3, 5], keeping: 5, count: 4), [1, 3, 5], "never adds days")
    }

    /// Beginners get an extra recovery week after a half or longer.
    func testRecoveryDays() {
        XCTAssertEqual(SeasonPlanner.recoveryDays(afterDistance: 10000, level: .beginner), 7)
        XCTAssertEqual(SeasonPlanner.recoveryDays(afterDistance: 21097, level: .intermediate), 14)
        XCTAssertEqual(SeasonPlanner.recoveryDays(afterDistance: 21097, level: .beginner), 21)
        XCTAssertEqual(SeasonPlanner.recoveryDays(afterDistance: 42195, level: .advanced), 21)
    }
}
