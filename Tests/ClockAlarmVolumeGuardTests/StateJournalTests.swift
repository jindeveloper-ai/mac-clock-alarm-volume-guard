import Foundation
import Testing

@testable import ClockAlarmVolumeGuard

struct StateJournalTests {
  @Test func roundTripsAndClearsRestoreState() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClockAlarmVolumeGuardJournal-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("state.json")
    let store = FileStateJournal(fileURL: fileURL)
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
          alarmID: 1,
          scheduledAt: Date(timeIntervalSince1970: 1_900_000_010),
          kind: .scheduled,
          observedActive: false
        )
      ]
    )

    try store.save(journal)
    #expect(try store.load() == journal)
    let permissions =
      try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)

    try store.clear()
    #expect(try store.load() == nil)
  }
}
