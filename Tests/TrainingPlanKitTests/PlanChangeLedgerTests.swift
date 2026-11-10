import XCTest
@testable import TrainingPlanKit

final class PlanChangeLedgerTests: XCTestCase {
    private let cal = Calendar.current
    private let today = Calendar.current.startOfDay(for: Date(timeIntervalSinceReferenceDate: 800_000_000))
    private func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }

    func testANewPlanIsNotQuiet() {
        XCTAssertFalse(PlanChangeLedger().isQuiet(on: today))
        XCTAssertNil(PlanChangeLedger().effortCountsSince(asOf: today))
    }

    /// Any change, and any answered suggestion, buys a week of quiet. Exactly a week.
    func testEveryKindOfChangeQuietsForAWeek() {
        for kind in PlanChange.Kind.allCases {
            var ledger = PlanChangeLedger()
            ledger.record(kind, on: day(-6))
            XCTAssertTrue(ledger.isQuiet(on: today), "\(kind) six days ago")
            XCTAssertFalse(ledger.isQuiet(on: day(1)), "\(kind) seven days ago")
        }
    }

    func testTheLatestChangeSetsTheQuiet() {
        var ledger = PlanChangeLedger()
        ledger.record(.fitness, on: day(-20))
        XCTAssertFalse(ledger.isQuiet(on: today))
        ledger.record(.declined, on: day(-2))
        XCTAssertTrue(ledger.isQuiet(on: today))
        XCTAssertFalse(ledger.isQuiet(on: day(5)))
    }

    /// A time trial applied and an easing are different facts: one moves paces, the other doesn't.
    func testKindsAreNotConflated() {
        var ledger = PlanChangeLedger()
        ledger.record(.fitness, on: day(-10))
        ledger.record(.eased, on: day(-3))
        ledger.record(.declined, on: day(-1))
        let pacesMoved = Set(PlanChange.Kind.allCases.filter(\.movesPaces))
        XCTAssertEqual(ledger.last(pacesMoved, asOf: today), day(-10), "easing and a declined offer moved no pace")
        XCTAssertEqual(ledger.last([.eased], asOf: today), day(-3))
        XCTAssertEqual(ledger.effortCountsSince(asOf: today), day(-3), "ratings count from the easing on")
        XCTAssertFalse(PlanChange.Kind.eased.movesPaces)
        XCTAssertFalse(PlanChange.Kind.declined.resetsEffort, "saying no changes nothing about the plan")
    }

    func testEntriesStayInDateOrderAndBounded() {
        var ledger = PlanChangeLedger()
        ledger.record(.declined, on: day(-1))
        ledger.record(.fitness, on: day(-5))
        XCTAssertEqual(ledger.changes.map(\.kind), [.fitness, .declined])
        for offset in 0..<50 { ledger.record(.declined, on: day(-60 + offset)) }
        XCTAssertEqual(ledger.changes.count, PlanChangeLedger.kept)
        XCTAssertEqual(ledger.changes.last?.date, day(-1))
    }

    func testSurvivesCoding() throws {
        var ledger = PlanChangeLedger()
        ledger.record(.fitness, on: day(-4))
        ledger.record(.declined, on: day(-1))
        XCTAssertEqual(try JSONDecoder().decode(PlanChangeLedger.self, from: JSONEncoder().encode(ledger)), ledger)
    }
}
