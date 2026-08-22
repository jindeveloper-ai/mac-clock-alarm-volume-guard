import Foundation

struct AlarmScheduleCalculator {
  static let activeRecoveryLimit: TimeInterval = 24 * 60 * 60

  func upcomingOccurrences(
    for alarms: [AlarmRecord],
    after now: Date,
    calendar inputCalendar: Calendar
  ) -> [AlarmOccurrence] {
    var calendar = inputCalendar
    calendar.timeZone = inputCalendar.timeZone

    var occurrences: [AlarmOccurrence] = []
    for alarm in alarms where alarm.enabled {
      if let snoozeDate = alarm.snoozeFireDate,
        snoozeDate > now,
        isAllowedByKeepOff(snoozeDate, alarm: alarm)
      {
        occurrences.append(
          AlarmOccurrence(alarmID: alarm.id, scheduledAt: snoozeDate, kind: .snooze)
        )
      }

      let scheduledSearchStart = max(now, alarm.keepOffUntilDate ?? now)
      if let scheduledDate = nextScheduledDate(
        for: alarm,
        after: scheduledSearchStart,
        calendar: calendar
      ) {
        occurrences.append(
          AlarmOccurrence(alarmID: alarm.id, scheduledAt: scheduledDate, kind: .scheduled)
        )
      }
    }

    return occurrences.sorted {
      if $0.scheduledAt == $1.scheduledAt {
        return $0.alarmID < $1.alarmID
      }
      return $0.scheduledAt < $1.scheduledAt
    }
  }

  func activeAlarmOccurrences(
    for alarms: [AlarmRecord],
    at now: Date
  ) -> [AlarmOccurrence] {
    alarms.compactMap { alarm in
      guard let firedDate = alarm.firedDate,
        firedDate <= now,
        now.timeIntervalSince(firedDate) <= Self.activeRecoveryLimit,
        alarm.dismissedDate.map({ $0 < firedDate }) ?? true,
        alarm.lastModifiedDate.map({ $0 <= firedDate.addingTimeInterval(1) }) ?? true
      else {
        return nil
      }
      return AlarmOccurrence(alarmID: alarm.id, scheduledAt: firedDate, kind: .activeRecovery)
    }
  }

  private func isAllowedByKeepOff(_ date: Date, alarm: AlarmRecord) -> Bool {
    guard let keepOffUntil = alarm.keepOffUntilDate else {
      return true
    }
    return date >= keepOffUntil
  }

  private func nextScheduledDate(
    for alarm: AlarmRecord,
    after now: Date,
    calendar: Calendar
  ) -> Date? {
    if alarm.repeatSchedule == 0 {
      let components = DateComponents(hour: alarm.hour, minute: alarm.minute, second: 0)
      return calendar.nextDate(
        after: now.addingTimeInterval(-0.5),
        matching: components,
        matchingPolicy: .nextTime,
        repeatedTimePolicy: .first,
        direction: .forward
      )
    }

    for dayOffset in 0...7 {
      guard let day = calendar.date(byAdding: .day, value: dayOffset, to: now) else {
        continue
      }
      let weekday = calendar.component(.weekday, from: day)
      guard let bit = repeatBit(forCalendarWeekday: weekday),
        alarm.repeatSchedule & (1 << bit) != 0
      else {
        continue
      }

      let startOfDay = calendar.startOfDay(for: day)
      let components = DateComponents(hour: alarm.hour, minute: alarm.minute, second: 0)
      guard
        let candidate = calendar.nextDate(
          after: startOfDay.addingTimeInterval(-1),
          matching: components,
          matchingPolicy: .nextTime,
          repeatedTimePolicy: .first,
          direction: .forward
        ), calendar.isDate(candidate, inSameDayAs: startOfDay),
        candidate >= now.addingTimeInterval(-0.5)
      else {
        continue
      }
      return candidate
    }
    return nil
  }

  private func repeatBit(forCalendarWeekday weekday: Int) -> Int? {
    switch weekday {
    case 2: return 0  // Monday
    case 3: return 1  // Tuesday
    case 4: return 2  // Wednesday
    case 5: return 3  // Thursday
    case 6: return 4  // Friday
    case 7: return 5  // Saturday
    case 1: return 6  // Sunday
    default: return nil
    }
  }
}

struct GuardSessionEvaluator {
  let activationObservationGrace: TimeInterval

  init(activationObservationGrace: TimeInterval = 15) {
    self.activationObservationGrace = activationObservationGrace
  }

  func updatedEntries(
    _ entries: [GuardedOccurrence],
    activeAlarmIDs: Set<Int64>,
    upcomingOccurrenceKeys: Set<String>,
    now: Date
  ) -> [GuardedOccurrence] {
    entries.compactMap { original in
      var entry = original
      if activeAlarmIDs.contains(entry.alarmID) {
        entry.observedActive = true
        return entry
      }

      if entry.observedActive {
        return nil
      }

      if now < entry.scheduledAt {
        return upcomingOccurrenceKeys.contains(entry.occurrence.key) ? entry : nil
      }

      if now <= entry.scheduledAt.addingTimeInterval(activationObservationGrace) {
        return entry
      }
      return nil
    }
  }
}
