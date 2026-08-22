import CSQLite
import Foundation
import Testing

@testable import ClockAlarmVolumeGuard

@Suite(.serialized)
final class AlarmStoreIntegrationTests {
  private var temporaryDirectories: [URL] = []

  deinit {
    for directory in temporaryDirectories {
      try? FileManager.default.removeItem(at: directory)
    }
  }

  @Test func readsOnlyRequiredAlarmFields() throws {
    let databaseURL = try createDatabase(schema: fullSchema)
    let fired = Date(timeIntervalSinceReferenceDate: 700_000_000)
    try execute(
      """
      INSERT INTO ZMTCDALARM (
          Z_PK, ZENABLED, ZHOUR, ZMINUTE, ZREPEATSCHEDULE, ZSLEEPALARM,
          ZFIREDDATE, ZDISMISSEDDATE, ZSNOOZEFIREDATE, ZKEEPOFFUNTILDATE,
          ZLASTMODIFIEDDATE
      ) VALUES (
          1, 1, 9, 30, 31, 0, \(fired.timeIntervalSinceReferenceDate), NULL, NULL, NULL,
          \(fired.timeIntervalSinceReferenceDate)
      );
      """,
      databaseURL: databaseURL
    )

    let before =
      try FileManager.default.attributesOfItem(atPath: databaseURL.path)[.modificationDate] as? Date
    let alarms = try SQLiteAlarmStore(databaseURL: databaseURL).readAlarms()
    let after =
      try FileManager.default.attributesOfItem(atPath: databaseURL.path)[.modificationDate] as? Date

    let alarm = try #require(alarms.first)
    #expect(alarms.count == 1)
    #expect(alarm.id == 1)
    #expect(alarm.enabled)
    #expect(alarm.hour == 9)
    #expect(alarm.minute == 30)
    #expect(alarm.repeatSchedule == 31)
    #expect(alarm.firedDate == fired)
    #expect(alarm.lastModifiedDate == fired)
    #expect(before == after)
  }

  @Test func rejectsUnsupportedSchemaBeforeQueryingRows() throws {
    let databaseURL = try createDatabase(
      schema: "CREATE TABLE ZMTCDALARM (Z_PK INTEGER PRIMARY KEY, ZENABLED INTEGER);"
    )

    do {
      _ = try SQLiteAlarmStore(databaseURL: databaseURL).readAlarms()
      Issue.record("Expected an unsupported schema error")
    } catch {
      guard case AlarmStoreError.schemaMismatch(let missingColumns) = error else {
        Issue.record("Expected schema mismatch, got \(error)")
        return
      }
      #expect(missingColumns.contains("ZHOUR"))
      #expect(missingColumns.contains("ZSNOOZEFIREDATE"))
    }
  }

  @Test func missingDatabaseFailsWithoutCreatingIt() {
    let missingURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("local.sqlite")

    do {
      _ = try SQLiteAlarmStore(databaseURL: missingURL).readAlarms()
      Issue.record("Expected a missing database error")
    } catch {
      guard case AlarmStoreError.databaseMissing = error else {
        Issue.record("Expected database missing, got \(error)")
        return
      }
    }
    #expect(!FileManager.default.fileExists(atPath: missingURL.path))
  }

  private var fullSchema: String {
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
    """
  }

  private func createDatabase(schema: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClockAlarmVolumeGuardTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    temporaryDirectories.append(directory)
    let databaseURL = directory.appendingPathComponent("local.sqlite")
    try execute(schema, databaseURL: databaseURL)
    return databaseURL
  }

  private func execute(_ sql: String, databaseURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
      throw NSError(domain: "AlarmStoreIntegrationTests", code: 1)
    }
    defer { sqlite3_close(database) }

    var errorMessage: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
      let message = errorMessage.map { String(cString: $0) } ?? "unknown SQLite error"
      sqlite3_free(errorMessage)
      throw NSError(
        domain: "AlarmStoreIntegrationTests",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: message]
      )
    }
  }
}
