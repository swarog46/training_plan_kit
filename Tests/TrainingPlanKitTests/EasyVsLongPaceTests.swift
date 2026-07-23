import XCTest
@testable import TrainingPlanKit

/// Easy runs are the SLOWEST non-recovery run (Pfitz: GA 15-25% off MP,
/// long/ML 10-20%): in every generated week, easy work pace must be strictly
/// slower than long-family work pace, and recovery never faster than easy.
final class EasyVsLongPaceTests: XCTestCase {

    private let cal = Calendar.current

    private func workPace(_ w: Workout) -> Int? {
        for iv in w.intervals where iv.type == .work {
            if case .paceTarget(let b, let rel) = iv.target { return Int(Double(b) * rel) }
        }
        return nil
    }

    func testEasySlowerThanLongAcrossCatalog() {
        let catalog = loadSampleCatalog()
        XCTAssertFalse(catalog.isEmpty)
        let start = cal.startOfDay(for: Date())
        let vdot = VDOT(value: 40)
        var totalCompared = 0

        for distance in [5000, 10000, 21097, 42195] {
            for (level, config) in [(RunnerLevel.beginner, PaceProgressionConfig.beginner),
                                    (.intermediate, .intermediate),
                                    (.advanced, .advanced)] {
                let weeks = distance >= 21097 ? 16 : 10
                let race = cal.date(byAdding: .weekOfYear, value: weeks, to: start)!
                let planConfig = PlanConfiguration.raceConfig(level: level, distanceMeters: distance)
                let hr = createMarathonPlanV3(startDate: start, raceDate: race,
                                              from: catalog, planId: UUID(), config: planConfig)
                let projected = vdot.projected(afterWeeks: weeks, perWeek: 0.3,
                                               adaptationCeiling: 6)
                func racePace(_ v: VDOT) -> Int {
                    switch distance {
                    case 42195: return v.marathonPaceSecondsPerKm
                    case 21097: return v.halfMarathonPaceSecondsPerKm
                    case 10000: return v.tenKPaceSecondsPerKm
                    default:    return v.fiveKPaceSecondsPerKm
                    }
                }
                let events = PaceZoneConverter.applyPaceProgression(
                    to: hr,
                    racePace: racePace(vdot),
                    conversationalPace: vdot.easyPaceSecondsPerKm,
                    speedPace: vdot.fiveKPaceSecondsPerKm,
                    config: config,
                    startDate: start, endDate: race,
                    racePaceEnd: racePace(projected),
                    conversationalPaceEnd: projected.easyPaceSecondsPerKm,
                    speedPaceEnd: projected.fiveKPaceSecondsPerKm,
                    raceDistanceMeters: distance,
                    isBeginner: level == .beginner,
                    isAdvanced: level == .advanced)

                // Pair each long run with the NEAREST-dated easy run (≤10 days):
                // small plans (2-day beginner weeks) rarely hold both in one week.
                let easies = events.filter { $0.workout.subtype == .easy }
                var compared = 0
                for e in events {
                    guard let p = workPace(e.workout) else { continue }
                    switch e.workout.subtype {
                    case .long, .mediumLong, .steadyLong:
                        guard let nearest = easies.min(by: {
                            abs($0.date.timeIntervalSince(e.date)) < abs($1.date.timeIntervalSince(e.date))
                        }), abs(nearest.date.timeIntervalSince(e.date)) <= 10 * 86_400,
                        let ep = workPace(nearest.workout) else { continue }
                        compared += 1
                        XCTAssertGreaterThan(ep, p,
                            "\(distance)m \(level) \(e.workout.subtype): easy \(ep)s/km must be slower than long \(p)s/km")
                    case .recovery:
                        guard let nearest = easies.min(by: {
                            abs($0.date.timeIntervalSince(e.date)) < abs($1.date.timeIntervalSince(e.date))
                        }), abs(nearest.date.timeIntervalSince(e.date)) <= 10 * 86_400,
                        let ep = workPace(nearest.workout) else { continue }
                        XCTAssertGreaterThanOrEqual(p, ep,
                            "\(distance)m \(level): recovery \(p) must not be faster than easy \(ep)")
                    default: break
                    }
                }
                // Short-distance beginner/intermediate plans structurally have no
                // long run (locked day-count matrix) — only demand pairs where the
                // structure guarantees them; totalCompared guards the rest.
                if distance >= 21097 {
                    XCTAssertGreaterThan(compared, 0,
                        "\(distance)m \(level): no comparable easy/long pair — test is vacuous")
                }
                totalCompared += compared
            }
        }
        XCTAssertGreaterThan(totalCompared, 20, "suite compared too few easy/long pairs")
    }

    /// Competitive (goal-locked) plans: easy is truly conversational (~goal+18%,
    /// Pfitz GA band), flat all plan (no erosion), and long-family sits between
    /// easy and goal pace (~goal+14.5%).
    func testCompetitiveEasyIsConversationalAndFlat() {
        let catalog = loadSampleCatalog()
        let start = cal.startOfDay(for: Date())
        let vdot = VDOT(value: 52)

        for (distance, weeks) in [(42195, 18), (21097, 12)] {
            let race = cal.date(byAdding: .weekOfYear, value: weeks, to: start)!
            let goal = distance == 42195 ? vdot.marathonPaceSecondsPerKm
                                         : vdot.halfMarathonPaceSecondsPerKm
            let planConfig = PlanConfiguration.raceConfig(level: .competitive, distanceMeters: distance)
            let hr = createMarathonPlanV3(startDate: start, raceDate: race,
                                          from: catalog, planId: UUID(), config: planConfig)
            let events = PaceZoneConverter.applyPaceProgression(
                to: hr, racePace: goal,
                conversationalPace: vdot.easyPaceSecondsPerKm,
                speedPace: vdot.fiveKPaceSecondsPerKm,
                config: .competitive, startDate: start, endDate: race,
                raceDistanceMeters: distance, isCompetitive: true)

            var easyPaces: Set<Int> = []
            var longPaces: [Int] = []
            for e in events {
                guard let p = workPace(e.workout), p > 0 else { continue }
                if e.workout.subtype == .easy { easyPaces.insert(p) }
                if [.long, .mediumLong, .steadyLong].contains(e.workout.subtype) { longPaces.append(p) }
            }
            let floor = Int(Double(goal) * 1.18)
            for p in easyPaces {
                XCTAssertTrue(abs(p - floor) <= 5,
                    "\(distance)m cmp easy \(p) should be ≈ goal+18% (\(floor))")
            }
            XCTAssertEqual(easyPaces.count, 1, "\(distance)m cmp easy must be FLAT (no erosion), got \(easyPaces)")
            for p in longPaces {
                XCTAssertGreaterThan(easyPaces.first ?? 0, p, "\(distance)m cmp: easy slower than long")
                XCTAssertGreaterThan(p, goal + 20, "\(distance)m cmp long \(p) too close to goal \(goal)")
            }
        }
    }
}
