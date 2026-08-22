import CSQLite
import Foundation

protocol AlarmStoreReading {
  var databaseURL: URL { get }
  func readAlarms() throws -> [AlarmRecord]
}

enum AlarmStoreError: LocalizedError, Equatable {
  case databaseMissing(String)
  case openFailed(String)
  case databaseNotReadOnly
  case schemaMismatch(missingColumns: [String])
  case queryFailed(String)

  var errorDescription: String? {
    switch self {
    case .databaseMissing(let path):
      return "Clock alarm database is missing: \(path)"
    case .openFailed(let message):
      return "Unable to open Clock alarm database read-only: \(message)"
    case .databaseNotReadOnly:
      return "Clock alarm database connection is not read-only"
    case .schemaMismatch(let missingColumns):
      return
        "Clock alarm database schema is unsupported; missing: \(missingColumns.joined(separator: ", "))"
    case .queryFailed(let message):
      return "Clock alarm query failed: \(message)"
    }
  }
}

struct SQLiteAlarmStore: AlarmStoreReading {
  static let requiredColumns: Set<String> = [
    "Z_PK",
    "ZENABLED",
    "ZHOUR",
    "ZMINUTE",
    "ZREPEATSCHEDULE",
    "ZSLEEPALARM",
    "ZFIREDDATE",
    "ZDISMISSEDDATE",
    "ZSNOOZEFIREDATE",
    "ZKEEPOFFUNTILDATE",
    "ZLASTMODIFIEDDATE",
  ]

  let databaseURL: URL

  init(databaseURL: URL = SQLiteAlarmStore.defaultDatabaseURL()) {
    self.databaseURL = databaseURL
  }

  static func defaultDatabaseURL(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL {
    homeDirectory
      .appendingPathComponent("Library/Group Containers/group.com.apple.mobiletimerd")
      .appendingPathComponent("local.sqlite")
  }

  func readAlarms() throws -> [AlarmRecord] {
    guard FileManager.default.fileExists(atPath: databaseURL.path) else {
      throw AlarmStoreError.databaseMissing(databaseURL.path)
    }

    var database: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    let openStatus = sqlite3_open_v2(databaseURL.path, &database, flags, nil)
    guard openStatus == SQLITE_OK, let database else {
      let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
      if let database {
        sqlite3_close(database)
      }
      throw AlarmStoreError.openFailed(message)
    }
    defer { sqlite3_close(database) }

    guard sqlite3_db_readonly(database, "main") == 1 else {
      throw AlarmStoreError.databaseNotReadOnly
    }

    sqlite3_busy_timeout(database, 1_000)
    try validateSchema(database)
    return try fetchAlarms(database)
  }

  private func validateSchema(_ database: OpaquePointer) throws {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(database, "PRAGMA table_info(ZMTCDALARM)", -1, &statement, nil)
        == SQLITE_OK,
      let statement
    else {
      throw AlarmStoreError.queryFailed(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }

    var columns = Set<String>()
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let name = sqlite3_column_text(statement, 1) else { continue }
      columns.insert(String(cString: name))
    }

    let missing = Self.requiredColumns.subtracting(columns).sorted()
    guard missing.isEmpty else {
      throw AlarmStoreError.schemaMismatch(missingColumns: missing)
    }
  }

  private func fetchAlarms(_ database: OpaquePointer) throws -> [AlarmRecord] {
    let sql = """
      SELECT
          Z_PK,
          ZENABLED,
          ZHOUR,
          ZMINUTE,
          ZREPEATSCHEDULE,
          ZSLEEPALARM,
          ZFIREDDATE,
          ZDISMISSEDDATE,
          ZSNOOZEFIREDATE,
          ZKEEPOFFUNTILDATE,
          ZLASTMODIFIEDDATE
      FROM ZMTCDALARM
      """

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw AlarmStoreError.queryFailed(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }

    var alarms: [AlarmRecord] = []
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE {
        break
      }
      guard status == SQLITE_ROW else {
        throw AlarmStoreError.queryFailed(String(cString: sqlite3_errmsg(database)))
      }

      alarms.append(
        AlarmRecord(
          id: sqlite3_column_int64(statement, 0),
          enabled: sqlite3_column_int(statement, 1) != 0,
          hour: Int(sqlite3_column_int(statement, 2)),
          minute: Int(sqlite3_column_int(statement, 3)),
          repeatSchedule: Int(sqlite3_column_int(statement, 4)),
          sleepAlarm: sqlite3_column_int(statement, 5) != 0,
          firedDate: referenceDate(statement, column: 6),
          dismissedDate: referenceDate(statement, column: 7),
          snoozeFireDate: referenceDate(statement, column: 8),
          keepOffUntilDate: referenceDate(statement, column: 9),
          lastModifiedDate: referenceDate(statement, column: 10)
        )
      )
    }
    return alarms
  }

  private func referenceDate(_ statement: OpaquePointer, column: Int32) -> Date? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
      return nil
    }
    return Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, column))
  }
}
