import Darwin
import Foundation

enum Command: String {
  case monitor
  case doctor
  case restore
  case selfTest = "self-test"
  case help
}

struct CommandLineOptions {
  let command: Command
  let leadSeconds: TimeInterval
  let minimumVolume: Float
  let databaseURL: URL

  static func parse(_ arguments: [String]) throws -> CommandLineOptions {
    var command: Command = .monitor
    var leadSeconds: TimeInterval = 10
    var minimumVolume: Float = 0.80
    var databaseURL = SQLiteAlarmStore.defaultDatabaseURL()

    var index = 1
    if index < arguments.count, !arguments[index].hasPrefix("-") {
      command = Command(rawValue: arguments[index]) ?? .help
      index += 1
    }

    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--lead-seconds":
        index += 1
        guard index < arguments.count,
          let value = TimeInterval(arguments[index]),
          (0...120).contains(value)
        else {
          throw CLIError.invalidArgument("--lead-seconds must be between 0 and 120")
        }
        leadSeconds = value
      case "--minimum-volume":
        index += 1
        guard index < arguments.count,
          let value = Float(arguments[index]),
          (0...1).contains(value)
        else {
          throw CLIError.invalidArgument("--minimum-volume must be between 0 and 1")
        }
        minimumVolume = value
      case "--database":
        index += 1
        guard index < arguments.count else {
          throw CLIError.invalidArgument("--database requires an absolute path")
        }
        let databasePath = arguments[index]
        guard databasePath.hasPrefix("/") else {
          throw CLIError.invalidArgument("--database requires an absolute path")
        }
        databaseURL = URL(fileURLWithPath: databasePath).standardizedFileURL
      case "--help", "-h":
        command = .help
      default:
        throw CLIError.invalidArgument("Unknown argument: \(argument)")
      }
      index += 1
    }

    return CommandLineOptions(
      command: command,
      leadSeconds: leadSeconds,
      minimumVolume: minimumVolume,
      databaseURL: databaseURL
    )
  }
}

enum CLIError: LocalizedError {
  case invalidArgument(String)

  var errorDescription: String? {
    switch self {
    case .invalidArgument(let message): return message
    }
  }
}

func printUsage() {
  print(
    """
    Usage:
      clock-alarm-volume-guard monitor [--lead-seconds 10] [--minimum-volume 0.80]
      clock-alarm-volume-guard doctor
      clock-alarm-volume-guard restore
      clock-alarm-volume-guard self-test

    Commands:
      monitor  Read Clock alarms without modifying them and guard the built-in speaker.
      doctor   Validate Clock database access and CoreAudio without changing audio state.
      restore  Restore a persisted audio snapshot when it still matches the guard state.
      self-test  Run deterministic local behavior tests in a debug build.
    """
  )
}

func runDoctor(options: CommandLineOptions) -> Int32 {
  let store = SQLiteAlarmStore(databaseURL: options.databaseURL)
  let audio = CoreAudioController()

  do {
    let alarms = try store.readAlarms()
    let diagnostics = try audio.diagnostics()
    let payload: [String: Any] = [
      "ok": true,
      "database": options.databaseURL.path,
      "alarm_count": alarms.count,
      "enabled_alarm_count": alarms.filter(\.enabled).count,
      "built_in_device_name": diagnostics.builtInDeviceName,
      "built_in_device_uid": diagnostics.builtInDeviceUID,
      "default_output_is_built_in": diagnostics.defaultOutputUID == diagnostics.builtInDeviceUID,
      "default_system_output_is_built_in": diagnostics.defaultSystemOutputUID
        == diagnostics.builtInDeviceUID,
      "volume_values": diagnostics.volumeValues,
      "mute_values": diagnostics.muteValues,
      "audio_was_modified": false,
    ]
    let data = try JSONSerialization.data(
      withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    return 0
  } catch {
    let payload =
      [
        "ok": false,
        "error": error.localizedDescription,
        "audio_was_modified": false,
      ] as [String: Any]
    if let data = try? JSONSerialization.data(
      withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    {
      FileHandle.standardError.write(data)
      FileHandle.standardError.write(Data("\n".utf8))
    }
    return 1
  }
}

func runRestore() -> Int32 {
  let journalStore = FileStateJournal()
  do {
    guard let journal = try journalStore.load() else {
      print("{\"ok\":true,\"outcome\":\"no_saved_state\"}")
      return 0
    }
    let outcome = try CoreAudioController().restoreIfUnchanged(journal.audioSnapshot)
    try journalStore.clear()
    let payload = ["ok": true, "outcome": outcome.rawValue] as [String: Any]
    let data = try JSONSerialization.data(
      withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    return 0
  } catch {
    let payload = ["ok": false, "error": error.localizedDescription] as [String: Any]
    if let data = try? JSONSerialization.data(
      withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    {
      FileHandle.standardError.write(data)
      FileHandle.standardError.write(Data("\n".utf8))
    }
    return 1
  }
}

do {
  let options = try CommandLineOptions.parse(CommandLine.arguments)
  switch options.command {
  case .help:
    printUsage()
    exit(0)
  case .doctor:
    exit(runDoctor(options: options))
  case .restore:
    exit(runRestore())
  case .selfTest:
    #if DEBUG
      exit(runDeterministicSelfTests())
    #else
      FileHandle.standardError.write(Data("self-test is available only in a debug build\n".utf8))
      exit(2)
    #endif
  case .monitor:
    let logger = StructuredLogger()
    let monitor = AlarmVolumeMonitor(
      alarmStore: SQLiteAlarmStore(databaseURL: options.databaseURL),
      audioController: CoreAudioController(),
      journalStore: FileStateJournal(),
      leadSeconds: options.leadSeconds,
      minimumVolume: options.minimumVolume,
      logger: logger,
      notifier: RateLimitedNotifier()
    )

    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let stopHandler = {
      monitor.stopAndRestore()
      exit(0)
    }
    terminationSource.setEventHandler(handler: stopHandler)
    interruptSource.setEventHandler(handler: stopHandler)
    terminationSource.resume()
    interruptSource.resume()

    monitor.start()
    dispatchMain()
  }
} catch {
  FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
  printUsage()
  exit(2)
}
