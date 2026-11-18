import XCTest
@testable import TrainingPlanKit

final class ComebackRampTests: XCTestCase {
    private var cal: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()
    private let opening = Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: 86_400))
    private func day(_ offset: Int) -> Date { opening.addingTimeInterval(Double(offset) * 86_400 + 3_600) }

    private func run(_ offset: Int, minutes: Int64, type: WorkoutType = .easyRun, done: Bool = false, actualMinutes: Double? = nil) -> WorkoutEvent {
        let workout = Workout(id: 1, title: "Run", type: type, subtype: .easy, trainingType: .timeBased, targetType: .heartRate,
                              duration: minutes * 60, distance: 0, key: "k", trainingLoad: minutes,
                              intervals: [WorkoutInterval(id: 0, type: .work, duration: Double(minutes * 60), distance: 0,
                                                          targetType: .heartRate, target: .heartRateZone(zone: 2))],
                              workRestRatio: 0, workDuration: minutes * 60, restDuration: 0, workDistance: 0, restDistance: 0)
        var event = WorkoutEvent(workout: workout, planId: UUID(), date: day(offset))
        event.isCompleted = done
        event.actualDuration = actualMinutes.map { $0 * 60 }
        return event
    }

    /// Three runs a week of `minutes` each, in the week that starts `week` weeks from the opening.
    private func week(_ week: Int, minutes: Int64, done: Bool = false) -> [WorkoutEvent] {
        [0, 2, 5].map { run(week * 7 + $0, minutes: minutes, done: done) }
    }

    private func weekMinutes(_ events: [WorkoutEvent], _ week: Int) -> Int64 {
        events.filter { $0.date >= day(week * 7).addingTimeInterval(-3_600) && $0.date < day(week * 7 + 7).addingTimeInterval(-3_600) && $0.workout.type != .race }
            .reduce(0) { $0 + $1.workout.duration } / 60
    }

    // MARK: The level before the break

    func testTheBaselineIsTheWeeklyAverageOfTheLastThreeWeeksRun() throws {
        // Weeks -8...-6 were run (120, 150, 180 minutes), then nothing for five weeks.
        let history = week(-8, minutes: 40, done: true) + week(-7, minutes: 50, done: true) + week(-6, minutes: 60, done: true)
            + week(-5, minutes: 70)
        XCTAssertEqual(try XCTUnwrap(ComebackRamp.baselineSeconds(history, calendar: cal)) / 60, 150, accuracy: 0.01)
    }

    func testWhatWasActuallyRunCountsOverWhatWasPlanned() throws {
        let history = [run(-10, minutes: 60, done: true, actualMinutes: 45), run(-8, minutes: 60, done: true)]
        XCTAssertEqual(try XCTUnwrap(ComebackRamp.baselineSeconds(history, calendar: cal)) / 60, 105, accuracy: 0.01,
                       "two runs in one week: 45 recorded and 60 marked done")
    }

    func testAShortHistoryIsAveragedOverItsOwnLength() throws {
        XCTAssertEqual(try XCTUnwrap(ComebackRamp.baselineSeconds(week(-9, minutes: 40, done: true), calendar: cal)) / 60, 120, accuracy: 0.01)
        let two = week(-9, minutes: 40, done: true) + week(-8, minutes: 60, done: true)
        XCTAssertEqual(try XCTUnwrap(ComebackRamp.baselineSeconds(two, calendar: cal)) / 60, 150, accuracy: 0.01)
    }

    func testNothingRunIsNoBaseline() {
        XCTAssertNil(ComebackRamp.baselineSeconds([], calendar: cal))
        XCTAssertNil(ComebackRamp.baselineSeconds(week(-3, minutes: 40), calendar: cal))
        XCTAssertNil(ComebackRamp.baselineSeconds([run(-3, minutes: 60, type: .race, done: true)], calendar: cal), "a race is not a training week")
    }

    // MARK: The weeks back

    private var history: [WorkoutEvent] { (-9...(-7)).flatMap { week($0, minutes: 50, done: true) } }   // 150 min a week

    func testTheFirstWeekBackIsHeldToTheLevelBeforeTheBreak() {
        let rebuilt = (0..<6).flatMap { week($0, minutes: 80) }                                          // 240 min a week
        let capped = ComebackRamp.capped(rebuilt, after: history, opening: opening, calendar: cal)
        XCTAssertEqual(weekMinutes(capped, 0), 150)
        XCTAssertEqual(capped.count, rebuilt.count)
        XCTAssertEqual(capped.map(\.id), rebuilt.map(\.id), "the same sessions on the same days")
        XCTAssertEqual(capped.map(\.date), rebuilt.map(\.date))
    }

    func testEachWeekMayGrowByFifteenPercentUntilThePlanIsReached() {
        let rebuilt = (0..<6).flatMap { week($0, minutes: 80) }
        let capped = ComebackRamp.capped(rebuilt, after: history, opening: opening, calendar: cal)
        let weeks = (0..<6).map { weekMinutes(capped, $0) }
        // 150, 172.5, 198, 228, then the plan's own 240. Runs move in five-minute steps.
        XCTAssertEqual(weeks, [150, 165, 195, 225, 240, 240])
        for (earlier, later) in zip(weeks, weeks.dropFirst()) { XCTAssertLessThanOrEqual(Double(later), Double(earlier) * 1.2) }
    }

    func testAPlanAlreadyUnderTheRampIsLeftAlone() {
        let gentle = (0..<4).flatMap { week($0, minutes: 45) }
        XCTAssertEqual(ComebackRamp.capped(gentle, after: history, opening: opening, calendar: cal), gentle)
    }

    func testWithoutAHistoryThePlanIsLeftAlone() {
        let rebuilt = week(0, minutes: 80)
        XCTAssertEqual(ComebackRamp.capped(rebuilt, after: [], opening: opening, calendar: cal), rebuilt)
    }

    func testARunKeepsItsShapeWhenCut() throws {
        let capped = ComebackRamp.capped(week(0, minutes: 80), after: history, opening: opening, calendar: cal)
        let run = try XCTUnwrap(capped.first).workout
        XCTAssertEqual(run.duration, 50 * 60)
        XCTAssertEqual(run.intervals.map(\.duration), [Double(50 * 60)])
        XCTAssertEqual(run.intervals.first?.target, .heartRateZone(zone: 2))
    }

    func testARaceIsNeverCutAndDoesNotCountAsTraining() {
        let raceWeek = week(0, minutes: 80) + [run(6, minutes: 120, type: .race)]
        let capped = ComebackRamp.capped(raceWeek, after: history, opening: opening, calendar: cal)
        XCTAssertEqual(capped.last?.workout.duration, 120 * 60)
        XCTAssertEqual(weekMinutes(capped, 0), 150)
    }

    func testAWeekIsNeverCutBelowHalfOfWhatThePlanSet() {
        let low = week(-9, minutes: 10, done: true)                    // 30 min a week before the break
        let capped = ComebackRamp.capped(week(0, minutes: 80), after: low, opening: opening, calendar: cal)
        XCTAssertEqual(weekMinutes(capped, 0), 120, "half of 240, not 30")
    }

    func testSessionsBeforeTheOpeningAreNotTouched() {
        let mixed = week(-1, minutes: 80) + week(0, minutes: 80)
        let capped = ComebackRamp.capped(mixed, after: history, opening: opening, calendar: cal)
        XCTAssertEqual(Array(capped.prefix(3)), Array(mixed.prefix(3)))
        XCTAssertEqual(weekMinutes(capped, 0), 150)
    }
}
