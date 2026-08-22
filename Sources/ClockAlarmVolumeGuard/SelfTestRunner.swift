#if DEBUG
  import CSQLite
  import Foundation

  private enum SelfTestFailure: LocalizedError {
    case assertion(String)

    var errorDescription: String? {
      switch self {
      case .assertion(let message): return message
      }
    }
  }

  private struct SelfTestCase {
    let name: String
    let body: () throws -> Void
  }

  func runDeterministicSelfTests() -> Int32 {
    let tests = deterministicSelfTests()
    var failures: [[String: String]] = []

    for test in tests {
      do {
        try test.body()
      } catch {
        failures.append(["name": test.name, "error": error.localizedDescription])
      }
    }

    let payload: [String: Any] = [
      "ok": failures.isEmpty,
      "test_count": tests.count,
      "passed_count": tests.count - failures.count,
      "failed_count": failures.count,
      "failures": failures,
    ]
    if let data = try? JSONSerialization.data(
      withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    {
      FileHandle.standardOutput.write(data)
      FileHandle.standardOutput.write(Data("\n".utf8))
    }
    return failures.isEmpty ? 0 : 1
  }

  private func deterministicSelfTests() -> [SelfTestCase] {
    [
      SelfTestCase(name: "repeat_masks", body: testRepeatMasks),
      SelfTestCase(name: "one_shot_rollover", body: testOneShotRollover),
      SelfTestCase(name: "snooze_and_keep_off", body: testSnoozeAndKeepOff),
      SelfTestCase(name: "active_alarm_detection", body: testActiveAlarmDetection),
      SelfTestCase(name: "dst_gap", body: testDSTGap),
      SelfTestCase(name: "guard_session_lifecycle", body: testGuardSessionLifecycle),
      SelfTestCase(name: "overlapping_alarms", body: testOverlappingAlarms),
      SelfTestCase(name: "audio_restore_policy", body: testAudioRestorePolicy),
      SelfTestCase(name: "sqlite_read_only_and_schema", body: testSQLiteReadOnlyAndSchema),
      SelfTestCase(name: "state_journal_round_trip", body: testStateJournalRoundTrip),
    ]
  }

  private func testRepeatMasks() throws {
    let calendar = utcCalendar()
    let now = try required(
      calendar.date(
        from: DateComponents(
          year: 2026,
          month: 8,
          day: 21,
          hour: 12
        )), "Unable to create repeat-mask test date")
    let calculator = AlarmScheduleCalculator()
    let weekday = sampleAlarm(id: 1, hour: 9, minute: 30, repeatSchedule: 31)
    let weekend = sampleAlarm(id: 2, hour: 9, minute: 30, repeatSchedule: 96)
    let occurrences = calculator.upcomingOccurrences(
      for: [weekday, weekend],
      after: now,
      calendar: calendar
    )
    let weekdayDate = try required(
      occurrences.first(where: { $0.alarmID == 1 })?.scheduledAt,
      "Missing weekday occurrence"
    )
    let weekendDate = try required(
      occurrences.first(where: { $0.alarmID == 2 })?.scheduledAt,
      "Missing weekend occurrence"
    )
    try expect(
      calendar.component(.weekday, from: weekdayDate) == 2, "Weekday mask did not choose Monday")
    try expect(
      calendar.component(.weekday, from: weekendDate) == 7, "Weekend mask did not choose Saturday")
  }

  private func testOneShotRollover() throws {
    let calendar = utcCalendar()
    let now = try required(
      calendar.date(
        from: DateComponents(
          year: 2026,
          month: 8,
          day: 22,
          hour: 10
        )), "Unable to create one-shot test date")
    let occurrence = try required(
      AlarmScheduleCalculator().upcomingOccurrences(
        for: [sampleAlarm(id: 3, hour: 9, minute: 30, repeatSchedule: 0)],
        after: now,
        calendar: calendar
      ).first,
      "Missing one-shot occurrence"
    )
    try expect(
      calendar.component(.day, from: occurrence.scheduledAt) == 23,
      "One-shot alarm did not roll to tomorrow")
  }

  private func testSnoozeAndKeepOff() throws {
    let calendar = utcCalendar()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let snoozeDate = now.addingTimeInterval(600)
    let calculator = AlarmScheduleCalculator()
    let snoozed = sampleAlarm(
      id: 4,
      repeatSchedule: 127,
      snoozeFireDate: snoozeDate
    )
    let snoozeOccurrences = calculator.upcomingOccurrences(
      for: [snoozed],
      after: now,
      calendar: calendar
    )
    try expect(
      snoozeOccurrences.contains(
        AlarmOccurrence(alarmID: 4, scheduledAt: snoozeDate, kind: .snooze)
      ),
      "Future snooze was not scheduled"
    )

    let keptOff = sampleAlarm(
      id: 5,
      repeatSchedule: 127,
      snoozeFireDate: now.addingTimeInterval(60),
      keepOffUntilDate: now.addingTimeInterval(86_400)
    )
    let keptOffOccurrences = calculator.upcomingOccurrences(
      for: [keptOff],
      after: now,
      calendar: calendar
    )
    try expect(keptOffOccurrences.count == 1, "Keep-off did not suppress only earlier occurrences")
    try expect(
      keptOffOccurrences[0].kind == .scheduled
        && keptOffOccurrences[0].scheduledAt >= now.addingTimeInterval(86_400),
      "Keep-off did not find the next allowed schedule"
    )
  }

  private func testActiveAlarmDetection() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let active = sampleAlarm(id: 6, firedDate: now.addingTimeInterval(-5))
    let dismissed = sampleAlarm(
      id: 7,
      firedDate: now.addingTimeInterval(-10),
      dismissedDate: now.addingTimeInterval(-2)
    )
    let edited = sampleAlarm(
      id: 14,
      firedDate: now.addingTimeInterval(-10),
      lastModifiedDate: now.addingTimeInterval(-2)
    )
    let activeIDs = AlarmScheduleCalculator()
      .activeAlarmOccurrences(for: [active, dismissed, edited], at: now)
      .map(\.alarmID)
    try expect(activeIDs == [6], "Dismissed alarm was incorrectly considered active")
  }

  private func testDSTGap() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try required(
      TimeZone(identifier: "America/Los_Angeles"),
      "Missing DST test time zone"
    )
    let now = try required(
      calendar.date(
        from: DateComponents(
          year: 2026,
          month: 3,
          day: 8,
          hour: 0
        )), "Unable to create DST test date")
    let occurrence = try required(
      AlarmScheduleCalculator().upcomingOccurrences(
        for: [sampleAlarm(id: 8, hour: 2, minute: 30, repeatSchedule: 64)],
        after: now,
        calendar: calendar
      ).first,
      "Missing DST occurrence"
    )
    try expect(
      calendar.isDate(occurrence.scheduledAt, inSameDayAs: now) && occurrence.scheduledAt > now,
      "DST gap did not resolve to a valid later local time"
    )
  }

  private func testGuardSessionLifecycle() throws {
    let evaluator = GuardSessionEvaluator(activationObservationGrace: 15)
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let pending = GuardedOccurrence(
      alarmID: 9,
      scheduledAt: now.addingTimeInterval(5),
      kind: .scheduled,
      observedActive: false
    )
    try expect(
      evaluator.updatedEntries(
        [pending],
        activeAlarmIDs: [],
        upcomingOccurrenceKeys: [],
        now: now
      ).isEmpty,
      "Disabled pending alarm did not release guard"
    )

    let firing = GuardedOccurrence(
      alarmID: 10,
      scheduledAt: now,
      kind: .scheduled,
      observedActive: false
    )
    let active = evaluator.updatedEntries(
      [firing],
      activeAlarmIDs: [10],
      upcomingOccurrenceKeys: [],
      now: now
    )
    try expect(active.first?.observedActive == true, "Active alarm was not recorded")
    try expect(
      evaluator.updatedEntries(
        active,
        activeAlarmIDs: [],
        upcomingOccurrenceKeys: [],
        now: now.addingTimeInterval(1)
      ).isEmpty,
      "Dismissed alarm did not release guard"
    )
  }

  private func testOverlappingAlarms() throws {
    let evaluator = GuardSessionEvaluator()
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let entries = [
      GuardedOccurrence(
        alarmID: 11,
        scheduledAt: now,
        kind: .scheduled,
        observedActive: true
      ),
      GuardedOccurrence(
        alarmID: 12,
        scheduledAt: now.addingTimeInterval(5),
        kind: .scheduled,
        observedActive: false
      ),
    ]
    let remaining = evaluator.updatedEntries(
      entries,
      activeAlarmIDs: [12],
      upcomingOccurrenceKeys: [],
      now: now.addingTimeInterval(6)
    )
    try expect(
      remaining.count == 1 && remaining.first?.alarmID == 12,
      "Overlapping alarm guard resolved too early"
    )
  }

  private func testAudioRestorePolicy() throws {
    let applied = DeviceControlState(
      deviceUID: "built-in",
      volumes: ["0": 0.8],
      mutes: ["0": 0]
    )
    try expect(
      AudioRestorePolicy.canRestore(
        currentDefaultOutputUID: "built-in",
        currentDefaultSystemOutputUID: "built-in",
        currentBuiltInState: applied,
        appliedBuiltInState: applied
      ),
      "Unchanged applied audio state was not restorable"
    )
    try expect(
      !AudioRestorePolicy.canRestore(
        currentDefaultOutputUID: "headphones",
        currentDefaultSystemOutputUID: "built-in",
        currentBuiltInState: applied,
        appliedBuiltInState: applied
      ),
      "A user route change did not block restoration"
    )

    let userVolume = DeviceControlState(
      deviceUID: "built-in",
      volumes: ["0": 0.6],
      mutes: ["0": 0]
    )
    try expect(
      !AudioRestorePolicy.canRestore(
        currentDefaultOutputUID: "built-in",
        currentDefaultSystemOutputUID: "built-in",
        currentBuiltInState: userVolume,
        appliedBuiltInState: applied
      ),
      "A user volume change did not block restoration"
    )
  }

  private func testSQLiteReadOnlyAndSchema() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClockAlarmVolumeGuardSelfTest-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let databaseURL = directory.appendingPathComponent("local.sqlite")
    try executeSQLite(
      """
      CREATE TABLE ZMTCDALARM (
          Z_PK INTEGER PRIMARY KEY,
          ZENABLED INTEGER,
          ZHOUR INTEGER,
          ZMINUTE INTEGER,
          ZREPEATSCHEDULE INTEGER,
          ZSLEEPALARM INTEGER,
          ZFIREDDATE REAL,
        ZDISMISSEDDATE REAL,
        ZSNOOZEFIREDATE REAL,
        ZKEEPOFFUNTILDATE REAL,
        ZLASTMODIFIEDDATE REAL
      );
      INSERT INTO ZMTCDALARM VALUES (1, 1, 9, 30, 31, 0, NULL, NULL, NULL, NULL, NULL);
      """,
      databaseURL: databaseURL
    )
    let before =
      try FileManager.default.attributesOfItem(atPath: databaseURL.path)[.modificationDate] as? Date
    let alarms = try SQLiteAlarmStore(databaseURL: databaseURL).readAlarms()
    let after =
      try FileManager.default.attributesOfItem(atPath: databaseURL.path)[.modificationDate] as? Date
    try expect(
      alarms.count == 1 && alarms[0].repeatSchedule == 31, "SQLite alarm row was not decoded")
    try expect(before == after, "Read-only alarm query modified the database")
  }

  private func testStateJournalRoundTrip() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClockAlarmVolumeGuardJournalSelfTest-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileStateJournal(fileURL: directory.appendingPathComponent("state.json"))
    let journal = GuardJournal(
      audioSnapshot: AudioRouteSnapshot(
        previousDefaultOutputUID: "external",
        previousDefaultSystemOutputUID: "external-system",
        builtInBefore: DeviceControlState(
          deviceUID: "built-in",
          volumes: ["0": 0.2],
          mutes: ["0": 1]
        ),
        builtInApplied: DeviceControlState(
          deviceUID: "built-in",
          volumes: ["0": 0.8],
          mutes: ["0": 0]
        ),
        appliedAt: Date(timeIntervalSince1970: 1_900_000_000)
      ),
      guardedOccurrences: [
        GuardedOccurrence(
          alarmID: 13,
          scheduledAt: Date(timeIntervalSince1970: 1_900_000_010),
          kind: .scheduled,
          observedActive: false
        )
      ]
    )
    try store.save(journal)
    let loadedJournal = try store.load()
    try expect(loadedJournal == journal, "Restore journal did not round-trip")
    try store.clear()
    let clearedJournal = try store.load()
    try expect(clearedJournal == nil, "Restore journal did not clear")
  }

  private func sampleAlarm(
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

  private func executeSQLite(_ sql: String, databaseURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
      throw SelfTestFailure.assertion("Unable to create SQLite self-test database")
    }
    defer { sqlite3_close(database) }

    var errorMessage: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
      let message = errorMessage.map { String(cString: $0) } ?? "unknown SQLite error"
      sqlite3_free(errorMessage)
      throw SelfTestFailure.assertion(message)
    }
  }

  private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }

  private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
      throw SelfTestFailure.assertion(message)
    }
  }

  private func required<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else {
      throw SelfTestFailure.assertion(message)
    }
    return value
  }
#endif
