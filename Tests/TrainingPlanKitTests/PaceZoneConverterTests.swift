import XCTest
@testable import TrainingPlanKit

/// Guards the quality-pace easing math in `qualitySpeedMultiplier` — the
/// speed-anchored path that converts Z4 threshold / Z5 interval HR zones to
/// pace. Two regressions live here historically:
///   1. `qualityZonesAlwaysAtTarget` was honored on the race-anchored path but
///      NOT here, so competitive build-band quality eased in instead of
///      locking at goal pace from day 1.
///   2. Beginner `finalAdjustment` was 0.5, so beginner quality never reached
///      its true zone — threshold ended up slower than race pace at half/
///      marathon. Dropped to 0.0 to match intermediate/advanced.
final class PaceZoneConverterTests: XCTestCase {

    private func mult(_ zone: Int, _ p: Double, _ c: PaceProgressionConfig, tenK: Bool = false) -> Double {
        PaceZoneConverter.qualitySpeedMultiplier(for: zone, progressionFactor: p, config: c, tenK: tenK)
    }

    // MARK: - qualityZonesAlwaysAtTarget locks quality at every point in the plan

    func testQualityZonesAlwaysAtTargetLocksAtTarget() {
        for c in [PaceProgressionConfig.competitive, .competitiveBuildBand] {
            for p in [0.0, 0.5, 1.0] {
                XCTAssertEqual(mult(5, p, c), 1.00, accuracy: 0.0001,
                               "Z5 must lock at 1.00 from day 1 (p=\(p))")
                XCTAssertEqual(mult(4, p, c), 1.06, accuracy: 0.0001,
                               "Z4 must lock at 1.06 from day 1 (p=\(p))")
            }
        }
    }

    // MARK: - Non-competitive tiers ease in, but REACH target by race week

    func testBeginnerQualityReachesTargetByRaceWeek() {
        let c = PaceProgressionConfig.beginner
        // Race week (p=1): true zones — Z4 threshold 1.06, Z5 interval 1.00.
        XCTAssertEqual(mult(4, 1.0, c), 1.06, accuracy: 0.0001, "Beg Z4 reaches threshold at race week")
        XCTAssertEqual(mult(5, 1.0, c), 1.00, accuracy: 0.0001, "Beg Z5 reaches 5K pace at race week")
        // Plan start (p=0): still conservative (slower than target).
        XCTAssertGreaterThan(mult(4, 0.0, c), 1.10, "Beg Z4 starts conservative")
        XCTAssertGreaterThan(mult(5, 0.0, c), 1.05, "Beg Z5 starts conservative")
    }

    func testIntermediateAndAdvancedReachTargetByRaceWeek() {
        for c in [PaceProgressionConfig.intermediate, .advanced] {
            XCTAssertEqual(mult(4, 1.0, c), 1.06, accuracy: 0.0001, "Z4 reaches target")
            XCTAssertEqual(mult(5, 1.0, c), 1.00, accuracy: 0.0001, "Z5 reaches target")
        }
    }

    // MARK: - 10K-pace work sits between 5K pace and threshold (F3)

    func testTenKPaceSitsBetweenFiveKAndThreshold() {
        // A "10K Pace" workout is Z4-tagged but must run at true 10K pace
        // (~1.04x 5K speed) — faster than threshold (1.06), slower than 5K (1.00).
        // Before the converter learned the tenkPace subtype it was identical to
        // threshold at 1.06.
        let c = PaceProgressionConfig.advanced   // reaches target at race week
        let tenK = mult(4, 1.0, c, tenK: true)
        XCTAssertEqual(tenK, 1.04, accuracy: 0.0001, "10K-pace target is 1.04x 5K speed")
        XCTAssertLessThan(tenK, mult(4, 1.0, c), "10K pace must be faster than threshold")
        XCTAssertGreaterThan(tenK, mult(5, 1.0, c), "10K pace must be slower than 5K pace")
    }

    // MARK: - Competitive easy anchors to the runner's real easy (build-band)

    func testCompetitiveEasyAnchorsToRunnerEasyNotFrozenBase() {
        // Build-band: race 256, runner's real easy 277 (4:37). Easy must anchor
        // to the runner's easy, NOT the generic 1.15×race = 294 (the frozen bug).
        let bb = PaceProgressionConfig.competitiveBuildBand
        func easyPace(_ zone: Int, _ conv: Int) -> Double {
            256.0 * PaceZoneConverter.progressiveMultiplier(
                for: zone, racePace: 256, conversationalPace: conv,
                progressionFactor: 0.0, config: bb)
        }
        let easy = easyPace(2, 277)
        XCTAssertEqual(easy, 277, accuracy: 4, "build-band easy ≈ runner's real easy (277), not 294")
        XCTAssertLessThan(easy, 294, "must not be the frozen 1.15×race")
        XCTAssertGreaterThanOrEqual(easy, 256, "easy never faster than race")
        XCTAssertGreaterThan(easyPace(1, 277), easy, "recovery (Z1) slower than easy (Z2)")
        // Over-qualified runner (easy faster than race) is floored at race.
        XCTAssertGreaterThanOrEqual(easyPace(2, 250), 256, "easy floored at race when runner's easy is faster")
    }

    // MARK: - Easing is monotonic (never sharper early than late)

    func testEasingIsMonotonicTowardTarget() {
        for c in [PaceProgressionConfig.beginner, .intermediate, .advanced] {
            XCTAssertGreaterThanOrEqual(mult(4, 0.0, c), mult(4, 1.0, c),
                                        "Z4 must not be faster at plan start than race week")
            XCTAssertGreaterThanOrEqual(mult(5, 0.0, c), mult(5, 1.0, c),
                                        "Z5 must not be faster at plan start than race week")
        }
    }
}
