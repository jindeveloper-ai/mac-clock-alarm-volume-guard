import Foundation

struct AlarmRecord: Equatable, Sendable {
  let id: Int64
  let enabled: Bool
  let hour: Int
  let minute: Int
  let repeatSchedule: Int
  let sleepAlarm: Bool
  let firedDate: Date?
  let dismissedDate: Date?
  let snoozeFireDate: Date?
  let keepOffUntilDate: Date?
  let lastModifiedDate: Date?
}

enum AlarmOccurrenceKind: String, Codable, Sendable {
  case scheduled
  case snooze
  case activeRecovery
}

struct AlarmOccurrence: Hashable, Codable, Sendable {
  let alarmID: Int64
  let scheduledAt: Date
  let kind: AlarmOccurrenceKind

  var key: String {
    let milliseconds = Int64((scheduledAt.timeIntervalSince1970 * 1_000).rounded())
    return "\(alarmID):\(milliseconds):\(kind.rawValue)"
  }
}

struct GuardedOccurrence: Codable, Equatable, Sendable {
  let alarmID: Int64
  let scheduledAt: Date
  let kind: AlarmOccurrenceKind
  var observedActive: Bool

  var occurrence: AlarmOccurrence {
    AlarmOccurrence(alarmID: alarmID, scheduledAt: scheduledAt, kind: kind)
  }
}

struct DeviceControlState: Codable, Equatable, Sendable {
  let deviceUID: String
  let volumes: [String: Float]
  let mutes: [String: UInt32]
}

struct AudioRouteSnapshot: Codable, Equatable, Sendable {
  let previousDefaultOutputUID: String?
  let previousDefaultSystemOutputUID: String?
  let builtInBefore: DeviceControlState
  let builtInApplied: DeviceControlState
  let appliedAt: Date
}

struct GuardJournal: Codable, Equatable, Sendable {
  let audioSnapshot: AudioRouteSnapshot
  var guardedOccurrences: [GuardedOccurrence]
}

enum RestoreOutcome: String, Codable, Sendable {
  case restored
  case skippedUserChange
  case partiallyRestored
}

struct AudioDiagnostics: Codable, Equatable, Sendable {
  let builtInDeviceName: String
  let builtInDeviceUID: String
  let defaultOutputUID: String?
  let defaultSystemOutputUID: String?
  let volumeValues: [String: Float]
  let muteValues: [String: UInt32]
}

enum AudioRestorePolicy {
  static func canRestore(
    currentDefaultOutputUID: String?,
    currentDefaultSystemOutputUID: String?,
    currentBuiltInState: DeviceControlState,
    appliedBuiltInState: DeviceControlState,
    volumeTolerance: Float = 0.01
  ) -> Bool {
    guard currentDefaultOutputUID == appliedBuiltInState.deviceUID,
      currentDefaultSystemOutputUID == appliedBuiltInState.deviceUID,
      currentBuiltInState.deviceUID == appliedBuiltInState.deviceUID,
      currentBuiltInState.mutes == appliedBuiltInState.mutes,
      currentBuiltInState.volumes.keys == appliedBuiltInState.volumes.keys
    else {
      return false
    }

    return currentBuiltInState.volumes.allSatisfy { element, value in
      guard let appliedValue = appliedBuiltInState.volumes[element] else {
        return false
      }
      return abs(value - appliedValue) <= volumeTolerance
    }
  }
}
