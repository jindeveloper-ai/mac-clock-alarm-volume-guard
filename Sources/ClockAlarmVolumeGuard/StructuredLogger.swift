import Foundation

final class StructuredLogger {
  private let lock = NSLock()

  func info(_ event: String, _ fields: [String: String] = [:]) {
    write(level: "info", event: event, fields: fields)
  }

  func error(_ event: String, _ fields: [String: String] = [:]) {
    write(level: "error", event: event, fields: fields)
  }

  private func write(level: String, event: String, fields: [String: String]) {
    var payload = fields
    payload["timestamp"] = ISO8601DateFormatter().string(from: Date())
    payload["level"] = level
    payload["event"] = event

    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
      var line = String(data: data, encoding: .utf8)
    else {
      return
    }
    line.append("\n")

    lock.lock()
    defer { lock.unlock() }
    FileHandle.standardOutput.write(Data(line.utf8))
  }
}

final class RateLimitedNotifier {
  private let interval: TimeInterval
  private var lastNotificationAt: Date?

  init(interval: TimeInterval = 60 * 60) {
    self.interval = interval
  }

  func notify(title: String, message: String, now: Date = Date()) {
    if let lastNotificationAt, now.timeIntervalSince(lastNotificationAt) < interval {
      return
    }
    lastNotificationAt = now

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = [
      "-e",
      "display notification \(appleScriptLiteral(message)) with title \(appleScriptLiteral(title))",
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
  }

  private func appleScriptLiteral(_ value: String) -> String {
    let escaped =
      value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: " ")
    return "\"\(escaped)\""
  }
}
