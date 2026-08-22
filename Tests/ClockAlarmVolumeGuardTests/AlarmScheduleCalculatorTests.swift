import Foundation
import Testing

@testable import ClockAlarmVolumeGuard

struct AlarmScheduleCalculatorTests {
  private let calculator = AlarmScheduleCalculator()

  @Test func repeatMasksSelectCorrectNextDay() throws {
    let calendar = utcCalendar()
    let friday = try #require(
      calendar.date(
        from: DateComponents(
          year: 2026,
          month: 8,
          day: 21,
          hour: 12
        )))

    let weekday = alarm(id: 1, hour: 9, minute: 30, repeatSchedule: 31)
    let weekend = alarm(id: 2, hour: 9, minute: 30, repeatSchedule: 96)
    let occurrences = calculator.upcomingOccurrences(
      for: [weekday, weekend],
      after: friday,
      calendar: calendar
    )

    let weekendDate = try #require(
      occurrences.first(where: { $0.alarmID == 2 })?.scheduledAt
    )
    let weekdayDate = try #require(
      occurrences.first(where: { $0.alarmID == 1 })?.scheduledAt
    )
    #expect(calendar.component(.weekday, from: weekendDate) == 7)
    #expect(calendar.component(.weekday, from: weekdayDate) == 2)
  }

  @Test func oneShotRollsForwardToNextDay() throws {
    let calendar = utcCalendar()
    let now = try #require(
      calendar.date(
        from: DateComponents(
          year: 2026,
          month: 8,
          day: 22,
          hour: 10
        )))
    let record = alarm(id: 7, hour: 9, minute: 30, repeatSchedule: 0)

    let occurrence = try #require(
      calculator.upcomingOccurrences(for: [record], after: now, calendar: calendar).first
    )
    #expect(calendar.component(.day, from: occurrence.scheduledAt) == 23)
    #expect(calendar.component(.hour, from: occurrence.scheduledAt) == 9)
    #expect(calendar.component(.minute, from: occurrence.scheduledAt) == 30)
  }

  @Test func futureSnoozeIsEmittedWithNextNormalOccurrence() throws {
    let calendar = utcCalendar()
    let now = try #require(
      calendar.date(
        from: DateComponents(
          year: 2026,
          month: 8,
          day: 22,
          hour: 9,
          minute: 31
        )))
    let snooze = now.addingTimeInterval(10 * 60)
    let record = alarm(
      id: 9,
      hour: 9,
      minute: 30,
      repeatSchedule: 127,
      snoozeFireDate: snooze
    )

    let occurrences = calculator.upcomingOccurrences(
      for: [record],
      after: now,
      calendar: calendar
    )
    #expect(
      occurrences.contains(
        AlarmOccurrence(alarmID: 9, scheduledAt: snooze, kind: .snooze)
      )
    )
    #expect(occurrences.contains(where: { $0.kind == .scheduled }))
  }

  @Test func keepOffDateSuppressesEarlierOccurrencesAndFindsNextAllowedSchedule() throws {
    let calendar = utcCalendar()
    let now = try #require(
      calendar.date(
        from: DateComponents(
          year: 2026,
          month: 8,
          day: 22,
          hour: 9
        )))
    let record = alarm(
      id: 10,
      hour: 9,
      minute: 30,
      repeatSchedule: 127,
      snoozeFireDate: now.addingTimeInterval(60),
      keepOffUntilDate: now.addingTimeInterval(24 * 60 * 60)
    )

    let occurrences = calculator.upcomingOccurrences(
      for: [record],
      after: now,
      calendar: calendar
    )
    #expect(occurrences.count == 1)
    #expect(occurrences.first?.kind == .scheduled)
    #expect(occurrences.first?.scheduledAt == now.addingTimeInterval(24.5 * 60 * 60))
  }

  @Test func firedAlarmRemainsActiveUntilLaterDismissal() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let active = alarm(
      id: 11,
      firedDate: now.addingTimeInterval(-5),
      dismissedDate: nil
    )
    let dismissed = alarm(
      id: 12,
      firedDate: now.addingTimeInterval(-10),
      dismissedDate: now.addingTimeInterval(-2)
    )

    let activeOccurrences = calculator.activeAlarmOccurrences(for: [active, dismissed], at: now)
    #expect(activeOccurrences.map(\.alarmID) == [11])
  }

  @Test func alarmEditedAfterFiringDoesNotRemainActive() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let edited = alarm(
      id: 14,
      firedDate: now.addingTimeInterval(-10),
      lastModifiedDate: now.addingTimeInterval(-5)
    )

    let activeOccurrences = calculator.activeAlarmOccurrences(for: [edited], at: now)
    #expect(activeOccurrences.isEmpty)
  }

  @Test func dstGapChoosesValidLaterLocalTimeOnSameDay() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let now = try #require(
      calendar.date(
        from: DateComponents(
          year: 2026,
          month: 3,
          day: 8,
          hour: 0
        )))
    let record = alarm(id: 13, hour: 2, minute: 30, repeatSchedule: 64)

    let occurrence = try #require(
      calculator.upcomingOccurrences(for: [record], after: now, calendar: calendar).first
    )
    #expect(calendar.isDate(occurrence.scheduledAt, inSameDayAs: now))
    #expect(occurrence.scheduledAt > now)
  }

  private func alarm(
    id: Int64,
    enabled: Bool = true,
    hour: Int = 9,
    minute: Int = 30,
    repeatSchedule: Int = 0,
    firedDate: Date? = nil,
    dismissedDate: Date? = nil,
    snoozeFireDate: Date? = nil,
    keepOffUntilDate: Date? = nil,
    lastModifiedDate: Date? = nil
  ) -> AlarmRecord {
    AlarmRecord(
      id: id,
      enabled: enabled,
      hour: hour,
      minute: minute,
      repeatSchedule: repeatSchedule,
      sleepAlarm: false,
      firedDate: firedDate,
      dismissedDate: dismissedDate,
      snoozeFireDate: snoozeFireDate,
      keepOffUntilDate: keepOffUntilDate,
      lastModifiedDate: lastModifiedDate
    )
  }

  private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }
}
