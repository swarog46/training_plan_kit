//
//  RaceWorkoutFactory.swift
//  RunPlan
//
//  Race-day workout + weekday-date helpers used by PlanGeneratorV3.
//

import Foundation

public func createRaceWorkout(level: RunnerLevel, distance: Int64) -> Workout? {
    // Create a race day workout with free run configuration
    // The workout can be started on the watch just like a regular free run
    return Workout(
        id: -1, // Special ID for race workout
        title: "Race Day",
        type: WorkoutType.race,
        subtype: .easy, // Default subtype
        trainingType: .distanceBased,
        targetType: .noTarget,
        duration: 0, // Open-ended duration
        distance: distance, // Store the actual race distance
        key: "race_day",
        trainingLoad: 0,
        intervals: [
            // Z3 tag = race day renders at the PLANNED race pace (exact), not
            // the easy-pace fallback .noRange would get. Interval type stays
            // .free — the watch keys free-run behavior off workout.type == .race.
            WorkoutInterval(
                id: 1,
                type: .free,
                duration: 0,
                distance: 0,
                targetType: .heartRate,
                target: .heartRateZone(zone: 3)
            )
        ],
        workRestRatio: 0,
        workDuration: 0,
        restDuration: 0,
        workDistance: 0,
        restDistance: 0
    )
}

func getDateForWeekday(weekStartDate: Date, weekdayIndex: Int) -> Date? {
    let calendar = Calendar.current

    // Get the start of the week based on locale
    guard let localeWeekStart = calendar.date(from:
        calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: weekStartDate)) else {
        return nil
    }

    // Handle the special case for Sunday (0)
    if weekdayIndex == 0 {
        // For Sunday, add 7 days to get the next Sunday
        // First, get this week's Sunday
        let thisSunday = calendar.date(
            byAdding: .day,
            value: 1 - calendar.component(.weekday, from: localeWeekStart),
            to: localeWeekStart
        )!

        // Then add 7 days to get next Sunday
        return calendar.date(byAdding: .day, value: 7, to: thisSunday)
    } else {
        // For other days, standard conversion
        // Convert 0-based weekdayIndex to calendar's 1-based weekday
        let calendarWeekday = weekdayIndex + 1

        // Calculate days to add to get from locale week start to the desired weekday
        let daysToAdd = calendarWeekday - calendar.component(.weekday, from: localeWeekStart)

        // Calculate the resulting date
        guard let resultDate = calendar.date(byAdding: .day, value: daysToAdd, to: localeWeekStart) else {
            return nil
        }

        // If the result is before our weekStartDate, add 7 days to get the next occurrence
        if resultDate < weekStartDate {
            return calendar.date(byAdding: .day, value: 7, to: resultDate)
        }

        return resultDate
    }
}
