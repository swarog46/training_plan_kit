import XCTest
@testable import TrainingPlanKit

final class RunEffortTests: XCTestCase {
    /// A Sunday, so "days ago" maps onto calendar weeks the same way everywhere.
    private let today: Date = {
        let cal = Calendar.current
        return cal.nextDate(after: Date(timeIntervalSinceReferenceDate: 800_000_000), matching: DateComponents(weekday: 1),
                            matchingPolicy: .nextTime)!
    }()
    private func run(_ daysAgo: Int, _ kind: EffortAdvice.RatedRun.Kind, _ effort: RunEffort) -> EffortAdvice.RatedRun {
        .init(date: Calendar.current.date(byAdding: .day, value: -daysAgo, to: today)!, kind: kind, effort: effort)
    }

    func testThreeRunsThatFeltTooHardEaseThePlan() {
        XCTAssertTrue(EffortAdvice.shouldEase([run(2, .quality, .tooHard), run(6, .easy, .hard), run(9, .long, .tooHard)], today: today))
    }

    func testABadDayOrTwoOrHardSessionsFeelingHardDoNot() {
        XCTAssertFalse(EffortAdvice.shouldEase([run(2, .quality, .tooHard), run(9, .long, .tooHard)], today: today))
        XCTAssertFalse(EffortAdvice.shouldEase([run(1, .quality, .hard), run(3, .long, .hard), run(5, .quality, .hard)], today: today),
                       "hard sessions are meant to feel hard")
        XCTAssertFalse(EffortAdvice.shouldEase([run(1, .easy, .right), run(3, .easy, .easy), run(5, .easy, .right)], today: today))
    }

    func testOneRoughWeekAloneDoesNot() {
        let cal = Calendar.current
        let week = cal.dateInterval(of: .weekOfYear, for: today)!
        func inThisWeek(_ day: Int) -> EffortAdvice.RatedRun {
            .init(date: cal.date(byAdding: .day, value: day, to: week.start)!, kind: .easy, effort: .tooHard)
        }
        let end = cal.date(byAdding: .day, value: 6, to: week.start)!
        XCTAssertFalse(EffortAdvice.shouldEase([inThisWeek(0), inThisWeek(2), inThisWeek(4)], today: end))
        let lastWeek = EffortAdvice.RatedRun(date: cal.date(byAdding: .day, value: -3, to: week.start)!, kind: .easy, effort: .tooHard)
        XCTAssertTrue(EffortAdvice.shouldEase([lastWeek, inThisWeek(2), inThisWeek(4)], today: end))
    }

    func testOldRatingsAgeOut() {
        XCTAssertFalse(EffortAdvice.shouldEase([run(2, .easy, .tooHard), run(5, .easy, .tooHard), run(15, .easy, .tooHard)], today: today))
        XCTAssertTrue(EffortAdvice.shouldEase([run(2, .easy, .tooHard), run(5, .easy, .tooHard), run(14, .easy, .tooHard)], today: today))
    }

    func testEventKinds() {
        let catalog = loadSampleCatalog()
        func kind(_ subtype: WorkoutSubtype) -> EffortAdvice.RatedRun.Kind? {
            catalog.first { $0.subtype == subtype }.map {
                EffortAdvice.RatedRun(WorkoutEvent(workout: $0, planId: UUID(), date: today), effort: .right).kind
            }
        }
        XCTAssertEqual(kind(.easy), .easy)
        XCTAssertEqual(kind(.steadyLong), .long)
        XCTAssertEqual(kind(.threshold), .quality)
    }
}
