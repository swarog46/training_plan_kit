import XCTest
@testable import TrainingPlanKit

final class RunEffortTests: XCTestCase {
    private let today = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func run(_ daysAgo: Int, _ kind: EffortAdvice.RatedRun.Kind, _ effort: RunEffort) -> EffortAdvice.RatedRun {
        .init(date: Calendar.current.date(byAdding: .day, value: -daysAgo, to: today)!, kind: kind, effort: effort)
    }

    func testTwoRunsThatFeltTooHardEaseThePlan() {
        XCTAssertTrue(EffortAdvice.shouldEase([run(2, .quality, .tooHard), run(9, .long, .tooHard)], today: today))
        XCTAssertTrue(EffortAdvice.shouldEase([run(1, .easy, .hard), run(3, .easy, .hard)], today: today))
    }

    func testOneBadDayOrHardSessionsFeelingHardDoNot() {
        XCTAssertFalse(EffortAdvice.shouldEase([run(2, .quality, .tooHard)], today: today))
        XCTAssertFalse(EffortAdvice.shouldEase([run(1, .quality, .hard), run(3, .long, .hard), run(5, .quality, .hard)], today: today),
                       "hard sessions are meant to feel hard")
        XCTAssertFalse(EffortAdvice.shouldEase([run(1, .easy, .right), run(3, .easy, .easy)], today: today))
    }

    func testOldRatingsAgeOut() {
        XCTAssertFalse(EffortAdvice.shouldEase([run(2, .easy, .tooHard), run(15, .easy, .tooHard)], today: today))
        XCTAssertTrue(EffortAdvice.shouldEase([run(2, .easy, .tooHard), run(14, .easy, .tooHard)], today: today))
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
