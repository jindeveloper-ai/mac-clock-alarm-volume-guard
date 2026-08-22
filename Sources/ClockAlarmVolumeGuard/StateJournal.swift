import Foundation

protocol StateJournalPersisting {
  func load() throws -> GuardJournal?
  func save(_ journal: GuardJournal) throws
  func clear() throws
}

enum StateJournalError: LocalizedError {
  case invalidState(String)

  var errorDescription: String? {
    switch self {
    case .invalidState(let message):
      return "Invalid audio restore journal: \(message)"
    }
  }
}

struct FileStateJournal: StateJournalPersisting {
  let fileURL: URL

  init(fileURL: URL = FileStateJournal.defaultFileURL()) {
    self.fileURL = fileURL
  }

  static func defaultFileURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser)
    -> URL
  {
    homeDirectory
      .appendingPathComponent("Library/Application Support/ClockAlarmVolumeGuard")
      .appendingPathComponent("state.json")
  }

  func load() throws -> GuardJournal? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return nil
    }
    do {
      let data = try Data(contentsOf: fileURL)
      return try decoder.decode(GuardJournal.self, from: data)
    } catch {
      throw StateJournalError.invalidState(error.localizedDescription)
    }
  }

  func save(_ journal: GuardJournal) throws {
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let data = try encoder.encode(journal)
    try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }

  func clear() throws {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return
    }
    try FileManager.default.removeItem(at: fileURL)
  }

  private var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }

  private var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
