import XCTest
@testable import TrainingPlanKit

/// Guards the recalibrated quality-pace math in `qualitySpeedMultiplier` (the
/// speed-anchored Z4/Z5 path) and the easy progression in `progressiveMultiplier`.
/// Current model (all multipliers × 5K SPEED):
///   • Z5 VO2 — rep-length-aware via `z5Target`: short reps 0.88 (I/R-pace),
///     long reps 0.96 (I-pace). Default 0.96.
///   • Z4 threshold — eases 1.06 (true LT, wk 1) → 1.02 (10K tempo, race wk).
///   • 10K work — 1.01 (between VO2 and threshold).
///   • competitive/build-band lock at target from day 1 (no easing).
///   • easy/long ease ~6.5% FASTER over the whole plan (≈20-25s), 5s-quantized.
///   • VDOT mode (`vdotAnchored`): the easy multiplier is FLAT — progression comes
///     from the anchor interpolating current→projected VDOT upstream (the app /
///     plan_debug integration path); these unit tests exercise the legacy path.
final class PaceZoneConverterTests: XCTestCase {

    private func mult(_ zone: Int, _ p: Double, _ c: PaceProgressionConfig,
                      tenK: Bool = false, z5Target: Double? = nil) -> Double {
        PaceZoneConverter.qualitySpeedMultiplier(
            for: zone, progressionFactor: p, config: c, tenK: tenK, z5Target: z5Target)
    }

    // MARK: - competitive locks quality at the sharp target from day 1

    func testQualityZonesAlwaysAtTargetLocksAtTarget() {
        for c in [PaceProgressionConfig.competitive, .competitiveBuildBand] {
            for p in [0.0, 0.5, 1.0] {
                XCTAssertEqual(mult(5, p, c), 0.96, accuracy: 0.0001,
                               "Z5 locks at 0.96 (I-pace) from day 1 (p=\(p))")
                XCTAssertEqual(mult(4, p, c), 1.02, accuracy: 0.0001,
                               "Z4 locks at 1.02 (10K tempo) from day 1 (p=\(p))")
            }
        }
    }

    // MARK: - Non-competitive tiers PROGRESS, reaching the sharp target by race week

    func testBeginnerQualitySharpensToTargetByRaceWeek() {
        let c = PaceProgressionConfig.beginner
        // Race week (p=1): sharp targets — Z4 tempo 1.02, Z5 I-pace 0.96.
        XCTAssertEqual(mult(4, 1.0, c), 1.02, accuracy: 0.0001, "Beg Z4 sharpens to 1.02 tempo")
        XCTAssertEqual(mult(5, 1.0, c), 0.96, accuracy: 0.0001, "Beg Z5 reaches I-pace 0.96")
        // Week 1: starts at true LT (Z4 1.06), and strictly SLOWER than race week
        // for both zones — i.e. the pace progresses over the block, never flat.
        XCTAssertEqual(mult(4, 0.0, c), 1.07, accuracy: 0.0001, "Beg Z4 starts at true LT 1.07")
        XCTAssertGreaterThan(mult(4, 0.0, c), mult(4, 1.0, c), "Beg Z4 progresses (wk1 slower)")
        XCTAssertGreaterThan(mult(5, 0.0, c), mult(5, 1.0, c), "Beg Z5 progresses (wk1 slower)")
    }

    func testIntermediateAndAdvancedReachTargetByRaceWeek() {
        for c in [PaceProgressionConfig.intermediate, .advanced] {
            XCTAssertEqual(mult(4, 1.0, c), 1.02, accuracy: 0.0001, "Z4 reaches 1.02 tempo")
            XCTAssertEqual(mult(5, 1.0, c), 0.96, accuracy: 0.0001, "Z5 reaches 0.96 I-pace")
            XCTAssertGreaterThan(mult(4, 0.0, c), mult(4, 1.0, c), "Z4 progresses over block")
        }
    }

    // MARK: - VO2 is rep-length-aware (short reps faster than long reps)

    func testVO2RepLengthAwareTargets() {
        let c = PaceProgressionConfig.advanced   // reaches target at race week
        let shortRep = mult(5, 1.0, c, z5Target: 0.88)   // ≤90s → 1500/800m pace
        let longRep  = mult(5, 1.0, c, z5Target: 0.96)   // ≥3min → I-pace ≈ 5K
        XCTAssertEqual(shortRep, 0.88, accuracy: 0.0001, "short VO2 rep at I/R-pace (0.88×5K)")
        XCTAssertEqual(longRep, 0.96, accuracy: 0.0001, "long VO2 rep at I-pace (0.96×5K)")
        XCTAssertLessThan(shortRep, longRep, "shorter reps run FASTER than longer reps")
    }

    // MARK: - 10K-pace work sits between VO2 (0.96) and threshold (1.02)

    func testTenKPaceSitsBetweenVO2AndThreshold() {
        let c = PaceProgressionConfig.advanced
        let tenK = mult(4, 1.0, c, tenK: true)
        XCTAssertEqual(tenK, 1.01, accuracy: 0.0001, "10K-pace target is 1.01×5K speed")
        XCTAssertLessThan(tenK, mult(4, 1.0, c), "10K pace faster than threshold (1.02)")
        XCTAssertGreaterThan(tenK, mult(5, 1.0, c), "10K pace slower than VO2/5K (0.96)")
    }

    // MARK: - Easy progresses ~6.5% faster over the whole plan (gentle modeled gain)

    func testEasyProgressesFasterOverBlock() {
        let c = PaceProgressionConfig.advanced
        func easy(_ p: Double) -> Double {
            341.0 * PaceZoneConverter.progressiveMultiplier(
                for: 2, racePace: 341, conversationalPace: 385, progressionFactor: p, config: c)
        }
        let w1 = easy(0.0), raceWk = easy(1.0)
        XCTAssertLessThan(raceWk, w1, "easy gets faster over the block (progression, not flat)")
        XCTAssertEqual(w1 - raceWk, 385.0 * 0.065, accuracy: 3, "~6.5% (≈25s) faster by race week")
        XCTAssertGreaterThanOrEqual(raceWk, 341, "easy never faster than race")
    }

    // MARK: - VDOT mode: easy multiplier is flat (anchor carries the progression)

    func testVDOTAnchoredEasyIsFlatVsLegacyEasing() {
        let c = PaceProgressionConfig.advanced
        func mult(_ p: Double, vdot: Bool) -> Double {
            PaceZoneConverter.progressiveMultiplier(
                for: 2, racePace: 341, conversationalPace: 385,
                progressionFactor: p, config: c, vdotAnchored: vdot)
        }
        // Legacy: the multiplier itself eases ~6.5% (race week faster than wk 1).
        XCTAssertGreaterThan(mult(0.0, vdot: false), mult(1.0, vdot: false),
                             "legacy multiplier eases over the block")
        // VDOT-anchored: multiplier is FLAT across the block — progression comes from
        // the anchor (conversationalPace) interpolating current→projected VDOT
        // upstream in applyPaceProgression, not from the multiplier.
        XCTAssertEqual(mult(0.0, vdot: true), mult(1.0, vdot: true), accuracy: 0.0001,
                       "vdot-anchored easy multiplier is flat (anchor carries progression)")
    }

    // MARK: - Competitive easy anchors to the runner's real easy (build-band)

    func testCompetitiveEasyAnchorsToRunnerEasyNotFrozenBase() {
        // Build-band: race 256, runner's real easy 277 (4:37). Easy must anchor
        // to the runner's easy, NOT the generic 1.15×race = 294 (the frozen bug).
        // Measured at p=0 (plan start) where the easy progression is identity.
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

    // MARK: - Aerobic floor: low-headroom easy never eases UNDER race pace
    //
    // The legacy easy-easing floors the base gap at race (max(1.0, gapRatio)) but
    // then applies ~6.5% easing on top with no clamp — so when the easy↔race
    // headroom is below 6.5% (gapRatio−1 < 0.065), easy underflows race at high
    // progressionFactor. Race-pace-anchored aerobic must never render FASTER than
    // race (easy must be ≥ race). Drives both the at-goal competitive config
    // (Cmp clear, ~1% headroom) and a slow runner (race≈easy).

    func testLowHeadroomEasyNeverFasterThanRace() {
        // Cmp "clear" (at-goal): race 256 (4:16), runner easy 259 (4:19) →
        // gapRatio ≈ 1.012, ~1.2% headroom. Whole-plan 6.5% easing crosses race.
        // Slow runner: race 469 (7:49), easy 485 (8:05) → ~3.4% headroom.
        // Easy↔race gap (4s, 16s) is below the 6.5% easing, so easy underflows.
        let cases: [(race: Int, easy: Int, config: PaceProgressionConfig, label: String)] = [
            (256, 259, .competitive, "Cmp clear (at-goal, ~1.2% headroom)"),
            (469, 485, .intermediate, "slow runner (~3.4% headroom)"),
            // Synthetic worst case: ~1% headroom on a generic intermediate plan.
            (300, 303, .intermediate, "synthetic 1% headroom"),
        ]
        for c in cases {
            for zone in [1, 2] {
                // p=1.0 is where the 6.5% easing bites hardest (race week).
                for p in [0.0, 0.5, 0.9, 1.0] {
                    let easyPace = Double(c.race) * PaceZoneConverter.progressiveMultiplier(
                        for: zone, racePace: c.race, conversationalPace: c.easy,
                        progressionFactor: p, config: c.config)
                    XCTAssertGreaterThanOrEqual(
                        easyPace, Double(c.race),
                        "\(c.label) Z\(zone) p=\(p): easy \(Int(easyPace.rounded()))s must be ≥ race \(c.race)s (aerobic floor)")
                }
            }
        }
    }
}
