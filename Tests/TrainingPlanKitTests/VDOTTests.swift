import XCTest
@testable import TrainingPlanKit

/// Coverage for the VDOT pace-DERIVATION math.
///
/// The Python regression suite drives the engine with paces injected via env
/// vars (RACE_PACE / EASY_PACE / SPEED_PACE), so it never exercises the VDOT →
/// pace functions. That left the derivation — the heart of the fitness-anchored
/// pace fix — with zero coverage: a regression that corrupted easy/threshold/5K
/// derivation passed the whole suite. These unit tests close that gap. The zone-
/// ORDERING test is the key guard: it fails the moment any zone derivation drifts
/// out of physiological order (e.g. threshold computed slower than easy).
final class VDOTTests: XCTestCase {

    // 20:00 5K is Daniels VDOT ~50 — the canonical reference row.
    private var ref: VDOT { VDOT.from(distanceMeters: 5000, timeSeconds: 1200)! }

    // MARK: - from() / predictedTime() round-trip

    func testRaceTimeToVDOTIsInDanielsRange() {
        // 20:00 5K → VDOT ≈ 50 (Daniels: 19:57 = 50).
        XCTAssertEqual(VDOT.from(distanceMeters: 5000, timeSeconds: 1200)!.value, 50, accuracy: 1.5)
        // 17:00 5K → VDOT ≈ 60 (Daniels: 16:59 = 60).
        XCTAssertEqual(VDOT.from(distanceMeters: 5000, timeSeconds: 1020)!.value, 60, accuracy: 1.5)
        // 25:00 5K → VDOT ≈ 38 (Daniels: 24:08 = 40, 25:12 = 38).
        XCTAssertEqual(VDOT.from(distanceMeters: 5000, timeSeconds: 1500)!.value, 38, accuracy: 2.0)
    }

    func testFromThenPredictRoundTrips() {
        // Inverting the formula must return the time we put in (±1%).
        for (dist, secs) in [(5000, 1200), (10000, 2480), (21097, 5400), (42195, 11400)] {
            let v = VDOT.from(distanceMeters: dist, timeSeconds: secs)!
            let back = v.predictedTime(forDistanceMeters: dist)!
            XCTAssertEqual(Double(back), Double(secs), accuracy: Double(secs) * 0.01,
                           "round-trip drift at \(dist)m")
        }
    }

    func testInvalidInputsReturnNil() {
        XCTAssertNil(VDOT.from(distanceMeters: 0, timeSeconds: 1200))
        XCTAssertNil(VDOT.from(distanceMeters: 5000, timeSeconds: 0))
    }

    // MARK: - Race-pace predictions increase with distance

    func testRacePacesSlowWithDistance() {
        let v = ref
        let p5 = v.fiveKPaceSecondsPerKm
        let p10 = v.tenKPaceSecondsPerKm
        let pHM = v.halfMarathonPaceSecondsPerKm
        let pM = v.marathonPaceSecondsPerKm
        XCTAssertTrue(p5 < p10 && p10 < pHM && pHM < pM,
                      "race pace must slow with distance: 5K=\(p5) 10K=\(p10) HM=\(pHM) M=\(pM)")
    }

    // MARK: - The key guard: training zones in physiological order

    func testTrainingZonesAreInOrderSlowToFast() {
        let v = ref
        let e = v.easyPaceSecondsPerKm        // ~72% VO2max — slowest
        let m = v.marathonPaceSecondsPerKm    // ~84%
        let t = v.thresholdPaceSecondsPerKm   // ~88%
        let i = v.intervalPaceSecondsPerKm    // ~98-100%
        let r = v.repetitionPaceSecondsPerKm  // > 100% — fastest
        XCTAssertTrue(e > m, "easy(\(e)) must be slower than marathon(\(m))")
        XCTAssertTrue(m > t, "marathon(\(m)) must be slower than threshold(\(t))")
        XCTAssertTrue(t > i, "threshold(\(t)) must be slower than interval(\(i))")
        XCTAssertTrue(i > r, "interval(\(i)) must be slower than rep(\(r))")
        XCTAssertGreaterThan(r, 0)
    }

    // MARK: - paceAtVO2Fraction monotonic (higher % VO2max → faster)

    func testPaceAtVO2FractionIsMonotonic() {
        let v = ref
        let fractions = [0.60, 0.72, 0.84, 0.88, 0.95, 1.00]
        let paces = fractions.map { v.paceAtVO2Fraction($0) }
        for k in 1..<paces.count {
            XCTAssertLessThan(paces[k], paces[k-1],
                              "fraction \(fractions[k]) should be faster than \(fractions[k-1])")
        }
    }

    // MARK: - Absolute bands vs Daniels' VDOT-50 row (gross-error catch)

    func testZonePacesMatchDanielsVDOT50() {
        let v = ref  // VDOT ~50
        // Daniels VDOT 50: 5K 4:00, M 4:31, T 4:15, E ~5:00 per km.
        XCTAssertEqual(v.fiveKPaceSecondsPerKm,   240, accuracy: 12, "5K pace")     // 4:00
        XCTAssertEqual(v.marathonPaceSecondsPerKm, 271, accuracy: 15, "marathon")    // 4:31
        XCTAssertEqual(v.thresholdPaceSecondsPerKm, 255, accuracy: 15, "threshold")  // 4:15
        XCTAssertEqual(v.easyPaceSecondsPerKm,     300, accuracy: 25, "easy")        // 5:00
    }

    // MARK: - Sub-VDOT-30 easy-pace floor (no near-walking easy runs)

    func testEasyPaceDoesNotBalloonBelowVDOT30() {
        // 1:20 10K (VDOT ~23): the raw 72%-VO2max pace is ~9:12/km — slower
        // than this runner can jog. The floor must pull it in: stay within
        // ~50s of threshold, still slower than race pace, and faster than the
        // un-floored 72% pace.
        let slow = VDOT.from(distanceMeters: 10000, timeSeconds: 4800)!
        XCTAssertLessThan(slow.value, 30, "premise: this is a sub-30 runner")
        let easy = slow.easyPaceSecondsPerKm
        let thr = slow.thresholdPaceSecondsPerKm
        let race = slow.tenKPaceSecondsPerKm
        XCTAssertLessThanOrEqual(easy - thr, 50, "easy(\(easy)) balloons below threshold(\(thr))")
        XCTAssertGreaterThan(easy, race, "easy(\(easy)) must still be slower than race(\(race))")
        XCTAssertLessThan(easy, slow.paceAtVO2Fraction(0.72),
                          "floor should speed easy up from the raw 72% pace")
    }

    func testEasyPaceUntouchedAtVDOT30Plus() {
        // At/above VDOT 30 (Daniels' table floor) the cap must NOT fire — easy
        // stays the unmodified 72%-VO2max pace.
        for secs in [3000, 2400, 1800] {  // 50 / 40 / 30-min 10K
            let v = VDOT.from(distanceMeters: 10000, timeSeconds: secs)!
            XCTAssertGreaterThanOrEqual(v.value, 30)
            XCTAssertEqual(v.easyPaceSecondsPerKm, v.paceAtVO2Fraction(0.72),
                           "VDOT \(Int(v.value)) easy should be the unmodified 72% pace")
        }
    }
}
