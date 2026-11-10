import XCTest
@testable import TrainingPlanKit

final class SeasonEditTests: XCTestCase {
    private let cal = Calendar.current
    private let catalog = loadSampleCatalog()
    private func day(_ s: String) -> Date {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        return f.date(from: s)!
    }
    private let start = "2027-01-04"
    private var tenK: SeasonRace { SeasonRace(date: day("2027-03-14"), distanceMeters: 10000) }
    private var half: SeasonRace { SeasonRace(date: day("2027-06-06"), distanceMeters: 21097) }
    private var marathon: SeasonRace { SeasonRace(date: day("2027-10-10"), distanceMeters: 42195) }

    private func build(_ races: [SeasonRace]) -> [WorkoutEvent] {
        let layout = SeasonPlanner.layout(races: races, start: day(start), level: .intermediate)
        return SeasonPlanBuilder.build(layout, level: .intermediate, catalog: catalog, planId: UUID(), config: { block in
            var c: PlanConfiguration
            if case .build(let i) = block.kind { c = .raceConfig(level: .intermediate, distanceMeters: layout.races[i].distanceMeters) }
            else { c = .maintenanceIntermediate }
            c.trainingDays = [2, 4, 6, 0]
            c.longestWorkoutDay = 0
            return c
        })
    }
    private func shape(_ events: [WorkoutEvent]) -> [String] {
        events.map { "\($0.date.timeIntervalSinceReferenceDate) \($0.workout.id) \($0.workout.duration)" }
    }

    func testRemovalMargins() {
        let races = [tenK, half, marathon]
        XCTAssertEqual(SeasonEdit.removal(of: half, in: races, today: day("2027-05-29")), .rebuild, "8 days out")
        XCTAssertEqual(SeasonEdit.removal(of: half, in: races, today: day("2027-05-30")), .runEasy, "7 days out")
        XCTAssertEqual(SeasonEdit.removal(of: half, in: races, today: day("2027-06-06")), .runEasy, "race day")
        XCTAssertNil(SeasonEdit.removal(of: half, in: races, today: day("2027-06-07")), "already run")
        XCTAssertNil(SeasonEdit.removal(of: marathon, in: races, today: day("2027-02-01")), "the goal race stays")
    }

    func testAddMargins() {
        let races = [tenK, marathon]
        let today = day("2027-05-01")
        func refusal(_ d: String) -> SeasonEdit.AddRefusal? {
            SeasonEdit.refusal(adding: SeasonRace(date: day(d), distanceMeters: 10000), to: races, today: today)
        }
        XCTAssertEqual(refusal("2027-05-10"), .tooSoon(days: 9))
        XCTAssertNil(refusal("2027-05-11"), "10 days of notice")
        XCTAssertEqual(refusal("2027-10-10"), .notBeforeGoal)
        XCTAssertEqual(refusal("2027-11-01"), .notBeforeGoal)
        XCTAssertEqual(SeasonEdit.refusal(adding: tenK, to: races, today: day("2027-01-10")), .sameDayAsAnotherRace)
    }

    func testCutIsTheStartOfNextWeek() {
        let cut = SeasonEdit.cut(after: day("2027-04-14"))
        XCTAssertEqual(cal.component(.weekday, from: cut), cal.firstWeekday)
        XCTAssertGreaterThan(cut, day("2027-04-14"))
        XCTAssertLessThanOrEqual(cal.dateComponents([.day], from: day("2027-04-14"), to: cut).day!, 7)
    }

    /// The same races rebuild to the same plan: an edit only moves what it has to.
    func testRebuildWithTheSameRacesChangesNothing() {
        let plan = build([tenK, half, marathon])
        let merged = SeasonEdit.merged(plan, rebuilt: build([tenK, half, marathon]),
                                       cut: SeasonEdit.cut(after: day("2027-04-14")), seasonStart: day(start))
        XCTAssertEqual(shape(merged), shape(plan))
    }

    func testRemovingARaceKeepsThePastAndDropsItsRaceDay() {
        let plan = build([tenK, half, marathon])
        let cut = SeasonEdit.cut(after: day("2027-04-14"))
        let merged = SeasonEdit.merged(plan, rebuilt: build([tenK, marathon]), cut: cut, seasonStart: day(start))

        XCTAssertEqual(shape(merged.filter { $0.date < cut }), shape(plan.filter { $0.date < cut }), "history untouched")
        XCTAssertEqual(merged.filter { $0.workout.type == .race }.map(\.date), [tenK.date, marathon.date])
        XCTAssertEqual(Set(merged.map { cal.startOfDay(for: $0.date) }).count, merged.count, "one session a day")
        assertRunGrowthHolds(merged, from: cut)
    }

    func testAddingARaceBringsItsRaceDay() {
        let plan = build([tenK, marathon])
        let cut = SeasonEdit.cut(after: day("2027-04-14"))
        let merged = SeasonEdit.merged(plan, rebuilt: build([tenK, half, marathon]), cut: cut, seasonStart: day(start))
        XCTAssertEqual(merged.filter { $0.workout.type == .race }.map(\.date), [tenK.date, half.date, marathon.date])
        assertRunGrowthHolds(merged, from: cut)
    }

    /// Six weeks out there's no time for a half's own build: it joins as a tune-up,
    /// and a marathon (never a tune-up) doesn't fit at all.
    func testARaceJoiningLateIsATuneUpOrDoesNotFit() {
        let cut = SeasonEdit.cut(after: day("2027-04-25"))
        let late = SeasonEdit.joining(half, cut: cut)
        XCTAssertTrue(late.tuneUpOnly)
        XCTAssertFalse(SeasonEdit.joining(half, cut: SeasonEdit.cut(after: day("2027-01-10"))).tuneUpOnly)

        let fits = SeasonPlanner.layout(races: [late, marathon], start: day(start), level: .intermediate)
        XCTAssertEqual(fits.priorities, [.tuneUp, .goal])
        XCTAssertEqual(SeasonPlanner.layout(races: [half, marathon], start: day(start), level: .intermediate).priorities,
                       [.block, .goal], "with time for its build it gets a block")

        var lateMarathon = SeasonRace(date: day("2027-06-06"), distanceMeters: 42195)
        lateMarathon.tuneUpOnly = true
        let blocked = SeasonPlanner.layout(races: [lateMarathon, marathon], start: day(start), level: .intermediate)
        XCTAssertTrue(blocked.issues.contains { $0.blocksPlan })
    }

    func testLateRemovalTurnsRaceDayIntoAnEasyRun() {
        let plan = build([tenK, half, marathon])
        let eased = SeasonEdit.runningEasy(on: half.date, in: plan, catalog: catalog)
        XCTAssertEqual(eased.count, plan.count)
        XCTAssertEqual(eased.filter { $0.workout.type == .race }.map(\.date), [tenK.date, marathon.date])
        XCTAssertEqual(eased.first { $0.date == half.date }?.workout.subtype, .easy)
    }

    /// No run after the cut outgrows the longest of its previous 30 days, kept history included.
    private func assertRunGrowthHolds(_ events: [WorkoutEvent], from cut: Date, file: StaticString = #filePath, line: UInt = #line) {
        for e in events where e.date >= cut && e.workout.type != .race {
            let monthAgo = cal.date(byAdding: .day, value: -30, to: e.date)!
            let longest = events.filter { $0.date < e.date && $0.date >= monthAgo }.map(\.workout.duration).max() ?? 0
            guard longest > 0 else { continue }
            XCTAssertLessThanOrEqual(e.workout.duration, runGrowthCap(afterLongest: longest), "\(e.date)", file: file, line: line)
        }
    }
}
