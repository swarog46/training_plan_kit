//
//  main.swift
//  Plan debugger CLI
//
//  Generates a plan for every (distance × level × duration) combination
//  and prints week-by-week summaries. Pure Swift / Foundation —
//  no Xcode, no simulator, no XCTest.
//
//  Run via: ./scripts/plan_debug/build.sh && ./scripts/plan_debug/plan_debug
//

import Foundation

// MARK: - Pretty-printer

// Render an interval workout's structure as one compact line, e.g.
//   WU 10min · 8 × 2:00 @ Z5 (90s jog) · CD 8min
// Returns nil for pure-aerobic workouts (single continuous easy/steady block,
// no warmup/cooldown, no recovery, no hard work) — their main line says enough.
func intervalDetail(_ workout: Workout) -> String? {
    let ivs = workout.intervals
    let works = ivs.filter { $0.type == .work }
    guard !works.isEmpty else { return nil }

    func isAerobicTarget(_ t: TargetRange) -> Bool {
        switch t {
        case .heartRateZone(let z): return z <= 2
        case .paceTarget(_, let rel): return rel >= 1.10
        default: return false
        }
    }
    let hasWarmCool = ivs.contains { $0.type == .warmup || $0.type == .cooldown }
    let hasRecovery = ivs.contains { $0.type == .rest || $0.type == .recovery }
    let hardWork = works.contains { !isAerobicTarget($0.target) }
    // Structure worth showing = brackets (WU/CD), recovery gaps, repeated efforts,
    // or any non-aerobic (Z3+) effort. A lone continuous Z2 block is just an easy run.
    guard hasWarmCool || hasRecovery || works.count > 1 || hardWork else { return nil }

    // dur as M:SS (work efforts), e.g. 90 -> "1:30", 600 -> "10:00".
    func ms(_ secs: Double) -> String {
        let s = Int(secs.rounded())
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }
    // WU/CD: whole minutes when clean, else M:SS.
    func mins(_ secs: Double) -> String {
        let s = Int(secs.rounded())
        return s % 60 == 0 ? "\(s / 60)min" : ms(secs)
    }
    // Recovery: short gaps as "90s", longer as "M:SS".
    func rec(_ secs: Double) -> String {
        let s = Int(secs.rounded())
        return s < 100 ? "\(s)s" : ms(secs)
    }
    // Target label. HR -> "Z4"; pace -> "@race" (rel≈1) / "@MP"/"@HMP" from the
    // title when obvious / "@pace×1.05"; noRange -> nil (omit).
    func tgt(_ t: TargetRange) -> String? {
        switch t {
        case .heartRateZone(let z): return "Z\(z)"
        case .paceTarget(_, let rel):
            if abs(rel - 1.0) < 0.02 {
                let title = workout.title.lowercased()
                if title.contains("marathon pace") || title.contains("@ mp") { return "@MP" }
                if title.contains("hmp") || title.contains("@ hm") || title.contains("half") { return "@HMP" }
                return "@race"
            }
            return String(format: "@pace×%.2f", rel)
        default: return nil
        }
    }
    func effort(_ iv: WorkoutInterval) -> String {
        if let t = tgt(iv.target) { return "\(ms(iv.duration)) @ \(t)" }
        return ms(iv.duration)
    }

    // Run-length-encode consecutive identical (duration + target) work efforts.
    struct Run { let dur: Double; let target: TargetRange; var count: Int }
    var runs: [Run] = []
    for w in works {
        if var last = runs.last, last.dur == w.duration, last.target == w.target {
            last.count += 1; runs[runs.count - 1] = last
        } else {
            runs.append(Run(dur: w.duration, target: w.target, count: 1))
        }
    }

    // Body string.
    let body: String
    let sameTarget = Set(works.map { "\($0.target)" }).count == 1
    if runs.count == 1 {
        let r = runs[0]
        let t = tgt(r.target).map { " @ \($0)" } ?? ""
        body = r.count > 1 ? "\(r.count) × \(ms(r.dur))\(t)" : "\(ms(r.dur))\(t)"
    } else if sameTarget && runs.allSatisfy({ $0.count == 1 }) {
        // Ladder / pyramid: list the varying work durations, target once.
        let t = tgt(works[0].target).map { " @ \($0)" } ?? ""
        body = works.map { ms($0.duration) }.joined(separator: "/") + t
    } else {
        // Mixed (e.g. rehearsal Z2/Z3/Z2, or grouped reps of differing efforts).
        body = runs.map { r in
            let t = tgt(r.target).map { " @ \($0)" } ?? ""
            return r.count > 1 ? "\(r.count) × \(ms(r.dur))\(t)" : "\(ms(r.dur))\(t)"
        }.joined(separator: " · ")
    }

    // Recovery shown once (dominant gap duration).
    var recStr = ""
    let gaps = ivs.filter { $0.type == .rest || $0.type == .recovery }.map { $0.duration }
    if let g = gaps.first { recStr = " (\(rec(g)) jog)" }

    var parts: [String] = []
    let wuTotal = ivs.filter { $0.type == .warmup }.reduce(0.0) { $0 + $1.duration }
    if wuTotal > 0 { parts.append("WU \(mins(wuTotal))") }
    parts.append(body + recStr)
    let cdTotal = ivs.filter { $0.type == .cooldown }.reduce(0.0) { $0 + $1.duration }
    if cdTotal > 0 { parts.append("CD \(mins(cdTotal))") }

    return parts.joined(separator: " · ")
}

func dumpPlan(_ config: PlanConfiguration, weeks: Int, label: String, workouts: [Workout]) {
    let plan = generatePlanV3(config: config, totalWeeks: weeks, allWorkouts: workouts, adaptive: adaptive)
    // Mirror the engine's front-trim: short plans are generated at
    // recommended length and trimmed from the start, so phase labels must
    // be computed against the generated length and offset by the trim.
    let minRequired = config.minBasePhaseWeeks + config.minSpeedPhaseWeeks
        + config.minPeakPhaseWeeks + config.minTaperPhaseWeeks
    let genWeeks = max(weeks, minRequired)
    let weeksTrimmed = genWeeks - weeks
    let phaseDurations = calculatePhaseDurations(config: config, totalWeeks: genWeeks)
    let baseDur = phaseDurations["base"] ?? 0
    let speedDur = phaseDurations["speed"] ?? 0
    let peakDur = phaseDurations["peak"] ?? 0
    let taperDur = phaseDurations["taper"] ?? 0

    print("\n=================================================================")
    print("=== \(label)  (\(weeks)w, \(config.trainingDays.count)d/wk)")
    print("=================================================================")
    print("Phases: BASE=\(baseDur) SPEED=\(speedDur) PEAK=\(peakDur) TAPER=\(taperDur)")
    print("Days: \(config.trainingDays.map(weekdayName).joined(separator: ",")) | LR=\(weekdayName(config.longestWorkoutDay))")
    print("-----------------------------------------------------------------")

    for week in 0..<weeks {
        let (phase, weekInPhase) = determinePhaseV3(weekIndex: week + weeksTrimmed, baseDur: baseDur, speedDur: speedDur, peakDur: peakDur, taperDur: taperDur)
        let ws = plan[week] ?? []
        let totalLoad = ws.reduce(0) { $0 + Int($1.workout.trainingLoad) }
        let totalMin  = ws.reduce(0) { $0 + Int($1.workout.duration) } / 60
        let phaseLen = phaseLength(phase, base: baseDur, speed: speedDur, peak: peakDur, taper: taperDur)
        let phaseLabel = phase.displayName(isMaintenance: config.distance == 0)
        // Deload flag, computed on the SAME trimmed indices the generator uses (so it
        // aligns with the delivered loads above — `phases` mode is un-trimmed).
        let targets = calculateWeeklyTargetsV3(weekInPlan: week + weeksTrimmed, weekInPhase: weekInPhase,
                                               phase: phase, phaseDurations: phaseDurations, config: config)
        let deloadTag = targets.isDeloading ? " [deload]" : ""
        print(String(format: "W%2d [%@ %d/%d] %dwkts load=%5d %3dmin%@",
                     week + 1, phaseLabel, weekInPhase + 1, phaseLen,
                     ws.count, totalLoad, totalMin, deloadTag))
        for w in ws {
            let dur = Int(w.workout.duration) / 60
            let load = Int(w.workout.trainingLoad)
            let title = w.workout.title.padding(toLength: 28, withPad: " ", startingAt: 0)
            let subtype = w.workout.subtype.rawValue
            // Z5 work minutes from the actual picked template — ground truth
            // for the Z5-policy tests (title-based joins are ambiguous).
            let z5work = w.workout.intervals.filter { iv -> Bool in
                guard iv.type == .work else { return false }
                if case .heartRateZone(let zone) = iv.target { return zone == 5 }
                return false
            }
            let z5sec: Double = z5work.reduce(0.0) { $0 + $1.duration }
            let z5min = Int(z5sec / 60)
            let z5tag = z5min > 0 ? " z5=\(z5min)" : ""
            print("    \(title) \(String(format: "%3dmin l=%4d  [%@/%@]%@", dur, load, subtype, w.type, z5tag))")
            // Indented structure line for quality workouts. The 6-space + "↳"
            // prefix keeps test_plans.py's per-workout regexes (l=.../[sub/role])
            // from matching it, so the parser skips it cleanly.
            if let detail = intervalDetail(w.workout) {
                print("      ↳ \(detail)")
            }
        }
    }
    print("=================================================================\n")
}

func summary(_ config: PlanConfiguration, weeks: Int, label: String, workouts: [Workout]) {
    let plan = generatePlanV3(config: config, totalWeeks: weeks, allWorkouts: workouts, adaptive: adaptive)
    let all = plan.values.flatMap { $0 }
    let easy = all.filter { $0.workout.subtype == .easy }.count
    let long = all.filter {
        $0.workout.subtype == .steadyLong ||
        $0.workout.subtype == .progressiveLong ||
        $0.workout.subtype == .long
    }.count
    let hard = all.filter {
        ["intervals","threshold","tempo","speed","ladderIntervals","pyramidIntervals",
         "hillRepeats","mileRepeats","yasso800","timeTrial","marathonPace"].contains($0.workout.subtype.rawValue)
    }.count
    let progression = all.filter { $0.workout.subtype == .progression }.count
    let fartlek = all.filter { $0.workout.subtype == .fartlek }.count
    let totalLoad = all.reduce(0) { $0 + Int($1.workout.trainingLoad) }
    let totalMin = all.reduce(0) { $0 + Int($1.workout.duration) } / 60
    let avgLoadWk = totalLoad / max(weeks, 1)
    let avgMinWk = totalMin / max(weeks, 1)
    let labelPadded = label.padding(toLength: 22, withPad: " ", startingAt: 0)
    print("\(labelPadded) " +
          String(format: "%3dw %3dwkts E:%2d L:%2d H:%2d P:%2d F:%2d  load=%6d (%4d/wk)  %5dmin (%3d/wk)",
                 weeks, all.count, easy, long, hard, progression, fartlek,
                 totalLoad, avgLoadWk, totalMin, avgMinWk))
}

func phaseLength(_ phase: TrainingPhase, base: Int, speed: Int, peak: Int, taper: Int) -> Int {
    switch phase {
    case .base: return base
    case .speed: return speed
    case .peak: return peak
    case .taper: return taper
    case .race: return 1
    }
}

func weekdayName(_ idx: Int) -> String {
    ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"][max(0, min(6, idx))]
}

// MARK: - Main

// Catalog source: $WORKOUTS_PATH if set (point it at your own catalog),
// otherwise the sample catalog shipped in the repo.
let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repoRoot = scriptDir.deletingLastPathComponent().deletingLastPathComponent()
let sampleCatalog = repoRoot
    .appendingPathComponent("Sources/TrainingPlanKit/Catalog/sample_catalog.json").path
let catalogPath = ProcessInfo.processInfo.environment["WORKOUTS_PATH"] ?? sampleCatalog
let workouts: [Workout]
do {
    let data = try Data(contentsOf: URL(fileURLWithPath: catalogPath))
    workouts = try JSONDecoder().decode([Workout].self, from: data)
    print("# Loaded \(workouts.count) workouts from \(catalogPath)")
} catch {
    print("FAILED to load workouts: \(error)")
    exit(1)
}
if workouts.isEmpty {
    print("Catalog is empty.")
    exit(1)
}

// CLI args: [mode] [filter]
//   mode: "summary" (default) | "dump" | "pace" | "pacedump"
//   filter: substring to match plan label, e.g. "21K", "Marathon", "Beginner"
//   pacedump: per-workout dump in pace-converted form (see HR vs pace targets)
//
// Env: ADAPTIVE=0 simulates the free-tier plan (excludes paid subtypes:
// raceRehearsal, timeTrial, mileRepeats, yasso800, marathonPace).
// Default is adaptive=true (back-compat with current behavior).
let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "summary"
let filter = args.count > 2 ? args[2] : ""
let adaptive = (ProcessInfo.processInfo.environment["ADAPTIVE"] ?? "1") != "0"
if !adaptive { print("# ADAPTIVE=0 — free-tier mode (no paid subtypes)") }

// (label, config, weeks-variant, weeks)
let cases: [(label: String, config: PlanConfiguration, weeks: Int)] = [
    // 5K — recommended 6-8w. Test short / rec / long.
    ("Beg 5K (short, 5w)",   .beginner5Default,      5),
    ("Beg 5K (rec, 7w)",     .beginner5Default,      7),
    ("Beg 5K (long, 10w)",   .beginner5Default,     10),
    ("Int 5K (short, 5w)",   .intermediate5Default,  5),
    ("Int 5K (rec, 7w)",     .intermediate5Default,  7),
    ("Int 5K (long, 10w)",   .intermediate5Default, 10),
    ("Adv 5K (rec, 7w)",     .advanced5Default,      7),
    ("Adv 5K (long, 10w)",   .advanced5Default,     10),

    // 10K — recommended 8-10w
    ("Beg 10K (short, 7w)",  .beginner10Default,     7),
    ("Beg 10K (rec, 9w)",    .beginner10Default,     9),
    ("Beg 10K (long, 12w)",  .beginner10Default,    12),
    ("Int 10K (rec, 9w)",    .intermediate10Default, 9),
    ("Int 10K (long, 12w)",  .intermediate10Default, 12),
    ("Adv 10K (rec, 9w)",    .advanced10Default,     9),
    ("Adv 10K (long, 12w)",  .advanced10Default,    12),

    // 21K — recommended 12-16w (after fix)
    ("Beg 21K (short, 10w)", .beginner21Default,    10),
    ("Beg 21K (rec, 14w)",   .beginner21Default,    14),
    ("Beg 21K (long, 18w)",  .beginner21Default,    18),
    ("Int 21K (rec, 14w)",   .intermediate21Default, 14),
    ("Int 21K (long, 18w)",  .intermediate21Default, 18),
    ("Adv 21K (rec, 14w)",   .advanced21Default,     14),
    ("Adv 21K (long, 18w)",  .advanced21Default,    18),

    // 21K Competitive — sub-1:30 target
    // Min (12w) and max (32w) cover the gate's build-band recommended
    // weeks at VDOT 54 (30w) which now fits under the bumped max cap.
    ("Cmp 21K (short, 12w)", .competitive21Default,  12),
    ("Cmp 21K (rec, 14w)",   .competitive21Default,  14),
    ("Cmp 21K (long, 18w)",  .competitive21Default,  18),
    ("Cmp 21K (max, 32w)",   .competitive21Default,  32),

    // Marathon — recommended 14-20w (after fix)
    ("Beg 42K (short, 14w)", .beginner42Default,    14),
    ("Beg 42K (rec, 18w)",   .beginner42Default,    18),
    ("Beg 42K (long, 22w)",  .beginner42Default,    22),
    ("Int 42K (rec, 18w)",   .intermediate42Default, 18),
    ("Int 42K (long, 22w)",  .intermediate42Default, 22),
    ("Adv 42K (rec, 18w)",   .advanced42Default,    18),
    ("Adv 42K (long, 22w)",  .advanced42Default,    22),

    // Marathon Competitive — sub-3:00 target. Min weeks now 12 for runners
    // already at goal fitness (was 18; phase mins still keep PEAK > TAPER).
    ("Cmp 42K (short, 12w)", .competitive42Default,  12),
    ("Cmp 42K (rec, 18w)",   .competitive42Default,  18),
    ("Cmp 42K (long, 22w)",  .competitive42Default,  22),
    ("Cmp 42K (build, 28w)", .competitive42Default,  28),  // VDOT-gap build path
    ("Cmp 42K (max, 36w)",   .competitive42Default,  36),

    // Maintenance — open-ended
    ("Maint Beg (12w)",      .maintenanceBeginner,   12),
    ("Maint Int (12w)",      .maintenanceIntermediate, 12),
    ("Maint Adv (12w)",      .maintenanceAdvanced,   12),

    // VO2 max — 8-week fixed block
    ("VO2 Beg (8w)",         .vo2maxBeginner,         8),
    ("VO2 Int (8w)",         .vo2maxIntermediate,     8),
    ("VO2 Adv (8w)",         .vo2maxAdvanced,         8),

    // Accessible ("real life") tier — lighter variants, same structure
    ("Acc Beg 5K (rec, 7w)",  .accessibleBeginner5Default,      7),
    ("Acc Int 5K (rec, 7w)",  .accessibleIntermediate5Default,  7),
    ("Acc Adv 5K (rec, 7w)",  .accessibleAdvanced5Default,      7),
    ("Acc Beg 10K (rec, 9w)", .accessibleBeginner10Default,     9),
    ("Acc Int 10K (rec, 9w)", .accessibleIntermediate10Default, 9),
    ("Acc Adv 10K (rec, 9w)", .accessibleAdvanced10Default,     9),
    ("Acc Beg 21K (rec, 14w)",.accessibleBeginner21Default,    14),
    ("Acc Int 21K (rec, 14w)",.accessibleIntermediate21Default,14),
    ("Acc Adv 21K (rec, 14w)",.accessibleAdvanced21Default,    14),
    ("Acc Beg 42K (rec, 18w)",.accessibleBeginner42Default,    18),
    ("Acc Int 42K (rec, 18w)",.accessibleIntermediate42Default,18),
    ("Acc Adv 42K (rec, 18w)",.accessibleAdvanced42Default,    18),
]

// WEEKS env overrides the duration for matched cases, so a plan can be
// generated at the iOS app's real recommended weeks (5K 6-8, 10K 8-10,
// 21K 12-16, 42K 14-20) instead of this sample list's debug durations.
let weeksOverride = ProcessInfo.processInfo.environment["WEEKS"].flatMap { Int($0) }
let filtered: [(label: String, config: PlanConfiguration, weeks: Int)] = {
    let base = cases.filter { filter.isEmpty || $0.label.lowercased().contains(filter.lowercased()) }
    guard let w = weeksOverride else { return base }
    return base.map { c in
        var label = c.label
        if let r = label.range(of: " (", options: .backwards) { label = String(label[..<r.lowerBound]) }
        return (label: "\(label) (\(w)w)", config: c.config, weeks: w)
    }
}()

print("\n========== PLAN GENERATION SUMMARY ==========")
print("(E=easy, L=long, H=hard, P=progression, F=fartlek)")
print("---------------------------------------------------")
for c in filtered {
    summary(c.config, weeks: c.weeks, label: c.label, workouts: workouts)
}

if mode == "dump" {
    for c in filtered {
        dumpPlan(c.config, weeks: c.weeks, label: c.label, workouts: workouts)
    }
}

// Pace mode: dump the same plans but with HR targets converted to pace
// targets (the same conversion the iOS app applies for pace plans).
//
// Race pace defaults: 5:00/km (300 sec/km), conversational 6:30/km (390).
// Override via env: RACE_PACE=320 EASY_PACE=420 ./plan_debug pace
if mode == "pace" {
    let racePace = Int(ProcessInfo.processInfo.environment["RACE_PACE"] ?? "300") ?? 300
    let easyPace = Int(ProcessInfo.processInfo.environment["EASY_PACE"] ?? "390") ?? 390

    print("\n========== PACE PLAN MODE ==========")
    print("Race pace: \(racePace/60):\(String(format: "%02d", racePace%60))/km")
    print("Easy pace: \(easyPace/60):\(String(format: "%02d", easyPace%60))/km")
    print("(Override with RACE_PACE / EASY_PACE env vars in seconds/km)")
    print("=====================================")

    for c in filtered {
        let plan = generatePlanV3(config: c.config, totalWeeks: c.weeks, allWorkouts: workouts, adaptive: adaptive)
        let hrEvents = plan.flatMap { _, ws in ws.map { $0.workout } }

        // Build a fake events array so PaceZoneConverter has dates to use
        let startDate = Date()
        let endDate = Calendar.current.date(byAdding: .weekOfYear, value: c.weeks, to: startDate)!

        var events: [WorkoutEvent] = []
        for (weekIdx, weekWorkouts) in plan.sorted(by: { $0.key < $1.key }) {
            let dayDate = Calendar.current.date(byAdding: .day, value: weekIdx * 7, to: startDate)!
            for (_, w) in weekWorkouts {
                events.append(WorkoutEvent(workout: w, planId: UUID(), date: dayDate))
            }
        }

        let progression: PaceProgressionConfig = {
            switch c.config.runnerLevel {
            case .beginner: return .beginner
            case .intermediate: return .intermediate
            case .advanced: return .advanced
            case .competitive:
                // Env: BUILD_BAND=1 forces the build-band variant. Used by
                // tests to verify the routing path that PlanConfigurationView
                // selects for VDOT 54-57 runners.
                let buildBand = ProcessInfo.processInfo.environment["BUILD_BAND"] == "1"
                return buildBand ? .competitiveBuildBand : .competitive
            }
        }()

        let paceEvents = PaceZoneConverter.applyPaceProgression(
            to: events,
            racePace: racePace,
            conversationalPace: easyPace,
            config: progression,
            startDate: startDate,
            endDate: endDate
        )

        // Tally pace targets by zone
        var paceCounts: [Int: Int] = [:]  // pace bucket (sec/km, rounded to 10) → count
        for event in paceEvents {
            for interval in event.workout.intervals {
                if case .paceTarget(let basePace, let relative) = interval.target {
                    let pace = Int(Double(basePace) * relative)
                    let bucket = (pace / 10) * 10
                    paceCounts[bucket, default: 0] += 1
                }
            }
        }
        let sorted = paceCounts.sorted { $0.key < $1.key }
        let total = sorted.reduce(0) { $0 + $1.value }
        let labelPadded = c.label.padding(toLength: 22, withPad: " ", startingAt: 0)
        print("\n\(labelPadded)  intervals=\(total)")
        for (bucket, count) in sorted {
            let pct = 100 * count / max(total, 1)
            let bar = String(repeating: "█", count: max(1, pct / 2))
            print(String(format: "  %d:%02d/km  %4d (%2d%%)  %@",
                         bucket/60, bucket%60, count, pct, bar))
        }
    }
    print()
}

// pacedump: per-week per-workout view with the pace targets actually
// applied. Lets you eyeball whether hill repeats hit Z5 pace, mile repeats
// hit threshold, marathon-pace hits race pace, etc.
if mode == "pacedump" {
    let racePace = Int(ProcessInfo.processInfo.environment["RACE_PACE"] ?? "300") ?? 300
    let easyPace = Int(ProcessInfo.processInfo.environment["EASY_PACE"] ?? "390") ?? 390
    // 5K speed anchor for quality zones (Z4/Z5). nil → legacy race-pace anchoring.
    let speedPace = ProcessInfo.processInfo.environment["SPEED_PACE"].flatMap { Int($0) }
    // Projected (race-week) anchors → VDOT progression. When set, paces interpolate
    // current→projected across the plan. Unset → legacy fixed-anchor easing.
    let racePaceEnd = ProcessInfo.processInfo.environment["RACE_PACE_END"].flatMap { Int($0) }
    let easyPaceEnd = ProcessInfo.processInfo.environment["EASY_PACE_END"].flatMap { Int($0) }
    let speedPaceEnd = ProcessInfo.processInfo.environment["SPEED_PACE_END"].flatMap { Int($0) }

    func fmtPace(_ secPerKm: Int) -> String {
        return String(format: "%d:%02d/km", secPerKm / 60, secPerKm % 60)
    }

    print("\n========== PACE DUMP ==========")
    print("Race pace: \(fmtPace(racePace)) | Easy pace: \(fmtPace(easyPace))")
    print("================================\n")

    for c in filtered {
        let plan = generatePlanV3(config: c.config, totalWeeks: c.weeks, allWorkouts: workouts, adaptive: adaptive)
        let startDate = Date()
        let endDate = Calendar.current.date(byAdding: .weekOfYear, value: c.weeks, to: startDate)!

        var events: [WorkoutEvent] = []
        var dayOfWorkout: [UUID: Date] = [:]
        for (weekIdx, weekWorkouts) in plan.sorted(by: { $0.key < $1.key }) {
            let dayDate = Calendar.current.date(byAdding: .day, value: weekIdx * 7, to: startDate)!
            for (_, w) in weekWorkouts {
                let event = WorkoutEvent(workout: w, planId: UUID(), date: dayDate)
                dayOfWorkout[event.id] = dayDate
                events.append(event)
            }
        }

        let progression: PaceProgressionConfig = {
            switch c.config.runnerLevel {
            case .beginner: return .beginner
            case .intermediate: return .intermediate
            case .advanced: return .advanced
            case .competitive:
                // Env: BUILD_BAND=1 forces the build-band variant. Used by
                // tests to verify the routing path that PlanConfigurationView
                // selects for VDOT 54-57 runners.
                let buildBand = ProcessInfo.processInfo.environment["BUILD_BAND"] == "1"
                return buildBand ? .competitiveBuildBand : .competitive
            }
        }()

        let paceEvents = PaceZoneConverter.applyPaceProgression(
            to: events, racePace: racePace, conversationalPace: easyPace,
            speedPace: speedPace,
            config: progression, startDate: startDate, endDate: endDate,
            racePaceEnd: racePaceEnd, conversationalPaceEnd: easyPaceEnd, speedPaceEnd: speedPaceEnd,
            raceDistanceMeters: Int(c.config.distance),
            isCompetitive: c.config.runnerLevel == .competitive,
            isBeginner: c.config.runnerLevel == .beginner,
            isAdvanced: c.config.runnerLevel == .advanced
        )

        // Group by week
        var byWeek: [Int: [WorkoutEvent]] = [:]
        for ev in paceEvents {
            let day = dayOfWorkout[ev.id] ?? startDate
            let weekIdx = Calendar.current.dateComponents([.day], from: startDate, to: day).day! / 7
            byWeek[weekIdx, default: []].append(ev)
        }

        print("============================================================")
        print("=== \(c.label)  (\(c.weeks)w)")
        print("============================================================")
        for (week, evs) in byWeek.sorted(by: { $0.key < $1.key }) {
            print("W\(String(format: "%2d", week + 1)):")
            for ev in evs {
                let title = ev.workout.title.padding(toLength: 30, withPad: " ", startingAt: 0)
                let dur = Int(ev.workout.duration) / 60
                let subtype = ev.workout.subtype.rawValue
                // Find the dominant work-interval pace (longest Work segment)
                var bestPace: Int? = nil
                var bestDur: Double = 0
                for iv in ev.workout.intervals where iv.type == .work {
                    if case .paceTarget(let base, let rel) = iv.target {
                        if iv.duration > bestDur {
                            bestDur = iv.duration
                            bestPace = Int(Double(base) * rel)
                        }
                    }
                }
                // Collect distinct work-interval paces in EXECUTION order (first
                // seen → last), not sorted: a progression is stored slow→fast, so
                // sorting by sec/km renders it fast-first (reads like a reverse
                // progression). Preserve order so it reads as actually run.
                var orderedPaces: [Int] = []
                for iv in ev.workout.intervals where iv.type == .work {
                    if case .paceTarget(let base, let rel) = iv.target {
                        let p = Int(Double(base) * rel)
                        if !orderedPaces.contains(p) { orderedPaces.append(p) }
                    }
                }
                let paceStr: String
                if orderedPaces.count > 1 {
                    let ordered = orderedPaces.map { fmtPace($0) }.joined(separator: ", ")
                    paceStr = "[\(ordered)]"
                } else if let p = bestPace {
                    paceStr = fmtPace(p)
                } else {
                    paceStr = "-"
                }
                print("  \(title) \(String(format: "%3dmin", dur))  \(paceStr)  [\(subtype)]")
            }
        }
        print("")
    }
}

// daydump: per-day calendar view via the REAL createMarathonPlanV3. This is
// the only ground-truth check for the day-scheduler — plan_debug's other
// modes call generatePlanV3 which doesn't do day assignment.
if mode == "daydump" {
    let calendar = Calendar.current
    // Start on a Monday so weekday math is intuitive. Day 1 = Tue, ..., Day 6 = Sun.
    var startComps = DateComponents()
    startComps.year = 2026; startComps.month = 1; startComps.day = 5  // Mon
    let startDate = calendar.date(from: startComps)!

    for c in filtered {
        let raceDate = calendar.date(byAdding: .weekOfYear, value: c.weeks, to: startDate)!
        let planId = UUID()
        let events = createMarathonPlanV3(startDate: startDate, raceDate: raceDate,
                                          from: workouts, planId: planId, config: c.config)

        // Group events by week-of-plan, then by weekday.
        var byWeek: [Int: [WorkoutEvent]] = [:]
        for ev in events {
            let weekIdx = calendar.dateComponents([.day], from: startDate, to: ev.date).day! / 7
            byWeek[weekIdx, default: []].append(ev)
        }

        let qualitySubtypes: Set<String> = [
            "intervals","hillRepeats","threshold","mileRepeats","ladderIntervals",
            "yasso800","timeTrial","marathonPace","fivekPace","tenkPace","fartlek",
            "pyramidIntervals"
        ]
        let dayNames = ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"]
        func dayName(_ date: Date) -> String {
            // Calendar.weekday: 1=Sun ... 7=Sat. Map to Mon=0..Sun=6.
            let wd = calendar.component(.weekday, from: date)
            let monIdx = (wd + 5) % 7
            return dayNames[monIdx]
        }

        print("============================================================")
        print("=== \(c.label) DAY-BY-DAY")
        print("============================================================")
        var totalConsecutive = 0
        for (week, evs) in byWeek.sorted(by: { $0.key < $1.key }) {
            print("W\(String(format: "%2d", week + 1)):")
            let sortedEvs = evs.sorted { $0.date < $1.date }
            var prevWasQuality = false
            var prevDate: Date? = nil
            for ev in sortedEvs {
                let subtype = ev.workout.subtype.rawValue
                let isQuality = qualitySubtypes.contains(subtype)
                let mark = isQuality ? "Q" : (subtype == "long" || subtype == "steadyLong" || subtype == "progressiveLong" || subtype == "raceRehearsalM" || subtype == "raceRehearsalHM" || subtype == "raceRehearsal10K" || subtype == "fastFinish" ? "L" : " ")
                var flag = ""
                if isQuality, prevWasQuality, let pd = prevDate {
                    let dayGap = calendar.dateComponents([.day], from: pd, to: ev.date).day ?? 0
                    if dayGap == 1 { flag = "  ⚠ back-to-back quality (prev day was also Q)"; totalConsecutive += 1 }
                }
                print("  \(dayName(ev.date)) \(mark)  \(ev.workout.title.padding(toLength: 32, withPad: " ", startingAt: 0))  \(Int(ev.workout.duration / 60))min  [\(subtype)]\(flag)")
                prevWasQuality = isQuality
                prevDate = ev.date
            }
        }
        if totalConsecutive > 0 {
            print("\nTotal back-to-back-quality occurrences: \(totalConsecutive)")
        }
    }
}

// tolerance: print the shared WorkoutPaceTolerance.seconds constant so
// Python tests assert against the same window the watch shows during a
// workout (no hardcoded "15" duplicated in two places).
if mode == "tolerance" {
    print("TOLERANCE_SECONDS=\(WorkoutPaceTolerance.seconds)")
}

// aerobic: per-workout aerobic-minutes count, computed from the REAL
// workout intervals' HR zones (Z1-Z2 = aerobic) and pace targets. Output
// is the source of truth for the Python aerobic-share test — no per-
// subtype heuristic, the test reads what the Swift catalog actually
// prescribes. If a catalog tweak changes a progressiveLong's Z2/Z3 split
// from 60/40 to 30/70, this mode reports the new aerobic minutes and
// the regression test sees the drift; the prior Python-heuristic version
// would have missed it.
//
// Aerobic classification per interval (in priority order):
//   1. heartRateZone target with zone <= 2 → aerobic
//   2. paceTarget with relative >= 1.10    → aerobic (Z2-ish; Z3 is 1.0)
//   3. interval type warmup/cooldown/recovery/rest → aerobic by convention
//   4. otherwise → non-aerobic (Z3+ work)
//
// Format: one line per workout, parseable:
//   W{N} | {subtype} | total={M}min | aerobic={A}min
if mode == "aerobic" {
    print("\n========== AEROBIC MINUTES ==========")
    for c in filtered {
        let plan = generatePlanV3(config: c.config, totalWeeks: c.weeks, allWorkouts: workouts, adaptive: adaptive)
        print("=== \(c.label)  (\(c.weeks)w)")
        for (weekIdx, weekWorkouts) in plan.sorted(by: { $0.key < $1.key }) {
            for (_, w) in weekWorkouts {
                var aerobicSecs: Double = 0
                for iv in w.intervals {
                    let zoneIsAerobic: Bool = {
                        switch iv.target {
                        case .heartRateZone(let zone):
                            return zone <= 2
                        case .paceTarget(_, let rel):
                            return rel >= 1.10  // Z2-or-easier multiplier window
                        case .secondsRange, .noRange:
                            return false
                        }
                    }()
                    let conventionalAerobic = iv.type == .warmup
                        || iv.type == .cooldown
                        || iv.type == .recovery
                        || iv.type == .rest
                    if zoneIsAerobic || conventionalAerobic {
                        aerobicSecs += iv.duration
                    }
                }
                let totalMin = Int(w.duration) / 60
                let aerobicMin = Int(aerobicSecs / 60.0)
                print("W\(weekIdx + 1) | \(w.subtype.rawValue) | total=\(totalMin)min | aerobic=\(aerobicMin)min")
            }
        }
    }
}

// gate: evaluate competitiveGateState() for a (VDOT, distance) pair and
// print the result in a parseable form. Used by tests to verify the same
// gate function the iOS app uses for sub-3 / sub-1:30 plan setup.
//
// Args (env, since CLI args are already taken by mode/filter):
//   VDOT=NN.N  — VDOT value as Double
//   DIST=42195 — race distance in meters (42195 marathon / 21097 half)
if mode == "gate" {
    let vdotStr = ProcessInfo.processInfo.environment["VDOT"] ?? ""
    let distStr = ProcessInfo.processInfo.environment["DIST"] ?? "42195"
    guard let vdotValue = Double(vdotStr), let dist = Int(distStr) else {
        print("ERROR: pass VDOT=NN.N and DIST=NNNNN as env vars")
        exit(1)
    }
    let vdot = VDOT(value: vdotValue)
    let state = competitiveGateState(vdot: vdot, distanceMeters: dist)
    switch state {
    case .clear:
        print("STATE=clear VDOT=\(vdotValue) DIST=\(dist)")
    case .buildBand(let weeks):
        print("STATE=buildBand RECOMMENDED_WEEKS=\(weeks) VDOT=\(vdotValue) DIST=\(dist)")
    case .blocked(let predicted):
        print("STATE=blocked PREDICTED_SECONDS=\(predicted) VDOT=\(vdotValue) DIST=\(dist)")
    }
}

// (The "recommend" mode lived here — it compared the app's UI-advised
// trainings-per-week against the engine config. That's a UI-layer concern
// tied to RunningLevel, which is app-only, so it's not part of this package.)

// Exercise the realistic-outcome projection across a matrix of starting
// VDOTs × runner levels × plan lengths. Output is parsed by the Python
// test suite to assert the growth math behaves correctly (Adv ≥ Beg at
// long plans; matching projections at short plans; sensible Pro gate
// behavior near build-band VDOT). Format:
//   projection <vdot> <level> <weeks> <distance_m> = <seconds>
if mode == "projection" {
    // Mirror of `planStimulusProfile` + `vdotGrowthPerWeek` + the level
    // baseCaps from PlanConfigurationView.swift. perWeek is derived from
    // the plan's actual structural load (avg weekly miles × 0.005 +
    // quality sessions/wk × 0.04) instead of being picked. Keep these
    // tables in lock-step with the iOS helpers — drift here means
    // projection tests will silently stop predicting what the app shows.
    func stimulusProfile(level: String, distance: Int) -> (mi: Double, q: Double) {
        switch distance {
        case 0..<7500:      // 5K
            switch level {
            case "beg": return (15, 1); case "int": return (25, 2)
            case "adv": return (35, 3); case "cmp": return (40, 3)
            default: return (0, 0)
            }
        case 7500..<15000:  // 10K
            switch level {
            case "beg": return (20, 1); case "int": return (35, 2)
            case "adv": return (45, 3); case "cmp": return (50, 3)
            default: return (0, 0)
            }
        case 15000..<30000: // Half
            switch level {
            case "beg": return (25, 1); case "int": return (40, 2)
            case "adv": return (50, 3); case "cmp": return (55, 3)
            default: return (0, 0)
            }
        default:            // Marathon
            switch level {
            case "beg": return (30, 1); case "int": return (45, 2)
            case "adv": return (55, 3); case "cmp": return (65, 3)
            default: return (0, 0)
            }
        }
    }
    let baseCaps: [String: Double] = [
        "beg":  8.0, "int":  9.0, "adv": 10.0, "cmp":  8.0,
    ]
    let levels = ["beg", "int", "adv", "cmp"]
    let vdots: [Double] = [30, 35, 40, 45, 50, 52, 54, 56, 58, 60]
    let weeks: [Int] = [8, 12, 18, 24, 36]
    let distances: [Int] = [10000, 21097, 42195]

    for v in vdots {
        let cur = VDOT(value: v)
        for lvlName in levels {
            let baseCap = baseCaps[lvlName]!
            let ceiling = VDOT.adaptationCeiling(baseCap: baseCap, current: cur)
            for w in weeks {
                for d in distances {
                    let p = stimulusProfile(level: lvlName, distance: d)
                    var basePerWeek = 0.005 * p.mi + 0.04 * p.q
                    if lvlName == "cmp" { basePerWeek *= 0.5 }
                    let perWeek = basePerWeek * VDOT.newnessBoost(current: cur)
                    if let projected = cur.realisticOutcome(
                            forDistance: d,
                            planWeeks: w,
                            perWeek: perWeek,
                            adaptationCeiling: ceiling) {
                        print("projection vdot=\(v) lvl=\(lvlName) weeks=\(w) dist=\(d) perWeek=\(String(format: "%.3f", perWeek)) ceiling=\(String(format: "%.2f", ceiling)) seconds=\(projected)")
                    }
                }
            }
        }
    }
}

// vdotpaces: derive every training pace from a race result, exactly as the
// app does (race=distance pace, easy=easyPaceSecondsPerKm, speed=5K pace).
// Prints the three values pacedump consumes (RACE_PACE/EASY_PACE/SPEED_PACE)
// so slow-runner plans can be generated with faithful paces.
//   DIST=5000 TIME=2400 ./plan_debug vdotpaces
if mode == "vdotpaces" {
    let dist = Int(ProcessInfo.processInfo.environment["DIST"] ?? "5000") ?? 5000
    let time = Int(ProcessInfo.processInfo.environment["TIME"] ?? "1200") ?? 1200
    guard let v = VDOT.from(distanceMeters: dist, timeSeconds: time) else {
        print("ERROR: bad DIST/TIME"); exit(1)
    }
    func f(_ s: Int) -> String { String(format: "%d:%02d", s/60, s%60) }
    let racePace: Int = {
        switch dist {
        case 42195: return v.marathonPaceSecondsPerKm
        case 21097: return v.halfMarathonPaceSecondsPerKm
        case 10000: return v.tenKPaceSecondsPerKm
        default: return v.fiveKPaceSecondsPerKm
        }
    }()
    print("VDOT=\(String(format: "%.1f", v.value)) for \(dist)m in \(f(time))")
    print("RACE_PACE=\(racePace)   # \(f(racePace))/km")
    print("EASY_PACE=\(v.easyPaceSecondsPerKm)   # \(f(v.easyPaceSecondsPerKm))/km  (raw 72%: \(f(v.paceAtVO2Fraction(0.72)))/km)")
    print("SPEED_PACE=\(v.fiveKPaceSecondsPerKm)   # \(f(v.fiveKPaceSecondsPerKm))/km")
    print("threshold=\(f(v.thresholdPaceSecondsPerKm))  interval=\(f(v.intervalPaceSecondsPerKm))  rep=\(f(v.repetitionPaceSecondsPerKm))")
    // Per-distance race pace at this VDOT — what the app picks as the goal pace
    // for each target distance from one recent-race result. EASY/SPEED(5K) are
    // VDOT constants (fitness), only RACE_PACE varies by target distance.
    print("RACE_5K=\(v.fiveKPaceSecondsPerKm)")
    print("RACE_10K=\(v.tenKPaceSecondsPerKm)")
    print("RACE_21K=\(v.halfMarathonPaceSecondsPerKm)")
    print("RACE_42K=\(v.marathonPaceSecondsPerKm)")
}

// progress: VDOT-gain-driven pace progression for one runner+plan. Mirrors the
// projection engine (newnessBoost + adaptationCeiling + saturating gain) to show
// week-1 (current VDOT) vs race-week (projected VDOT) paces + the span seconds.
//   DIST=5000 TIME=1500 LEVEL=beg TARGET=10000 WEEKS=12 ./plan_debug progress
if mode == "progress" {
    let dist = Int(ProcessInfo.processInfo.environment["DIST"] ?? "5000") ?? 5000
    let time = Int(ProcessInfo.processInfo.environment["TIME"] ?? "1500") ?? 1500
    let level = ProcessInfo.processInfo.environment["LEVEL"] ?? "beg"
    let target = Int(ProcessInfo.processInfo.environment["TARGET"] ?? "\(dist)") ?? dist
    let weeks = Int(ProcessInfo.processInfo.environment["WEEKS"] ?? "12") ?? 12
    guard let v0 = VDOT.from(distanceMeters: dist, timeSeconds: time) else { print("bad DIST/TIME"); exit(1) }
    func stim(_ lvl: String, _ d: Int) -> (mi: Double, q: Double) {
        switch d {
        case 0..<7500:      switch lvl { case "int": return (25,2); case "adv": return (35,3); case "cmp": return (40,3); default: return (15,1) }
        case 7500..<15000:  switch lvl { case "int": return (35,2); case "adv": return (45,3); case "cmp": return (50,3); default: return (20,1) }
        case 15000..<30000: switch lvl { case "int": return (40,2); case "adv": return (50,3); case "cmp": return (55,3); default: return (25,1) }
        default:            switch lvl { case "int": return (45,2); case "adv": return (55,3); case "cmp": return (65,3); default: return (30,1) }
        }
    }
    let baseCap = ["beg":8.0,"int":9.0,"adv":10.0,"cmp":8.0][level] ?? 8.0
    let ceiling = VDOT.adaptationCeiling(baseCap: baseCap, current: v0)
    let p = stim(level, target)
    var perWeek = 0.005*p.mi + 0.04*p.q
    if level == "cmp" { perWeek *= 0.5 }
    perWeek *= VDOT.newnessBoost(current: v0)
    let vdotGain = ceiling * (1.0 - exp(-(Double(weeks) * perWeek) / ceiling))
    let vEnd = VDOT(value: v0.value + vdotGain)
    func f(_ s: Int) -> String { String(format: "%d:%02d", s/60, s%60) }
    func raceP(_ vd: VDOT) -> Int {
        switch target { case 42195: return vd.marathonPaceSecondsPerKm; case 21097: return vd.halfMarathonPaceSecondsPerKm
                         case 10000: return vd.tenKPaceSecondsPerKm; default: return vd.fiveKPaceSecondsPerKm }
    }
    func row(_ n: String, _ a: Int, _ b: Int) {
        print("  \(n.padding(toLength: 10, withPad: " ", startingAt: 0)) \(f(a)) -> \(f(b))   (-\(a-b)s)")
    }
    print("LEVEL=\(level) TARGET=\(target)m WEEKS=\(weeks)  VDOT \(String(format:"%.1f",v0.value)) -> \(String(format:"%.1f",vEnd.value)) (gain \(String(format:"%.1f",vdotGain)), ceiling \(String(format:"%.1f",ceiling)))")
    row("easy", v0.easyPaceSecondsPerKm, vEnd.easyPaceSecondsPerKm)
    row("5K/speed", v0.fiveKPaceSecondsPerKm, vEnd.fiveKPaceSecondsPerKm)
    row("threshold", v0.thresholdPaceSecondsPerKm, vEnd.thresholdPaceSecondsPerKm)
    row("race", raceP(v0), raceP(vEnd))
    // Machine-readable start (current VDOT) + end (projected VDOT) anchors so a
    // generator can `eval` them straight into a pacedump run.
    print("RACE_PACE=\(raceP(v0))");  print("EASY_PACE=\(v0.easyPaceSecondsPerKm)");  print("SPEED_PACE=\(v0.fiveKPaceSecondsPerKm)")
    print("RACE_PACE_END=\(raceP(vEnd))"); print("EASY_PACE_END=\(vEnd.easyPaceSecondsPerKm)"); print("SPEED_PACE_END=\(vEnd.fiveKPaceSecondsPerKm)")
    print("VDOT_START=\(String(format: "%.1f", v0.value))"); print("VDOT_END=\(String(format: "%.1f", vEnd.value))")
}

// usedladders: print the distinct `key`s of every ladderIntervals workout that
// any plan in `cases` actually delivers. Used to safely cull never-selected
// ladder templates from the catalog (cull = catalog templates whose key never
// appears here). Honors the same filter/WEEKS/ADAPTIVE env as the other modes.
if mode == "usedladders" {
    var usedKeys = Set<String>()
    for c in filtered {
        let plan = generatePlanV3(config: c.config, totalWeeks: c.weeks, allWorkouts: workouts, adaptive: adaptive)
        for (_, weekWorkouts) in plan {
            for (_, w) in weekWorkouts where w.subtype == .ladderIntervals {
                usedKeys.insert(w.key)
            }
        }
    }
    for k in usedKeys.sorted() { print(k) }
    FileHandle.standardError.write("# \(usedKeys.count) distinct ladder keys delivered\n".data(using: .utf8)!)
}

// phases: for each filtered plan, print the phase split + per-week load target
// and multiplier. Shows how phase durations are derived and how load is balanced.
if mode == "phases" {
    for c in filtered {
        let d = calculatePhaseDurations(config: c.config, totalWeeks: c.weeks)
        let base = d["base"] ?? 0, speed = d["speed"] ?? 0, peak = d["peak"] ?? 0, taper = d["taper"] ?? 0
        print("\n=== \(c.label) (\(c.weeks)w): BASE \(base) | SPEED \(speed) | PEAK \(peak) | TAPER \(taper) ===")
        for w in 0..<c.weeks {
            let (phase, wip) = determinePhaseV3(weekIndex: w, baseDur: base, speedDur: speed, peakDur: peak, taperDur: taper)
            let t = calculateWeeklyTargetsV3(weekInPlan: w, weekInPhase: wip, phase: phase, phaseDurations: d, config: c.config)
            let pname = "\(phase)".uppercased().padding(toLength: 6, withPad: " ", startingAt: 0)
            print("W\(String(format: "%2d", w+1))  \(pname)  load=\(String(format: "%6d", Int(t.load)))  dur=\(String(format: "%4d", Int(t.duration)))min\(t.isDeloading ? "  [deload]" : "")")
        }
    }
}
