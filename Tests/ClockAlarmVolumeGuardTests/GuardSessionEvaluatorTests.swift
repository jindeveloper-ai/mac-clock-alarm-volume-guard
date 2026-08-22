import Foundation
import Testing

@testable import ClockAlarmVolumeGuard

struct GuardSessionEvaluatorTests {
  private let evaluator = GuardSessionEvaluator(activationObservationGrace: 15)

  @Test func pendingOccurrenceIsRemovedWhenAlarmIsDisabled() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let entry = guarded(id: 1, date: now.addingTimeInterval(5), observed: false)

    let result = evaluator.updatedEntries(
      [entry],
      activeAlarmIDs: [],
      upcomingOccurrenceKeys: [],
      now: now
    )
    #expect(result.isEmpty)
  }

  @Test func activeAlarmIsRetainedThenResolvesAfterDismissal() throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let entry = guarded(id: 2, date: now, observed: false)
    let active = evaluator.updatedEntries(
      [entry],
      activeAlarmIDs: [2],
      upcomingOccurrenceKeys: [],
      now: now
    )
    #expect(try #require(active.first).observedActive)

    let dismissed = evaluator.updatedEntries(
      active,
      activeAlarmIDs: [],
      upcomingOccurrenceKeys: [],
      now: now.addingTimeInterval(1)
    )
    #expect(dismissed.isEmpty)
  }

  @Test func overlappingAlarmsKeepGuardUntilBothResolve() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let entries = [
      guarded(id: 3, date: now, observed: true),
      guarded(id: 4, date: now.addingTimeInterval(5), observed: false),
    ]

    let result = evaluator.updatedEntries(
      entries,
      activeAlarmIDs: [4],
      upcomingOccurrenceKeys: [],
      now: now.addingTimeInterval(6)
    )
    #expect(result.count == 1)
    #expect(result.first?.alarmID == 4)
    #expect(result.first?.observedActive == true)
  }

  @Test func fireEventGetsShortObservationGrace() {
    let scheduled = Date(timeIntervalSince1970: 2_000_000_000)
    let entry = guarded(id: 5, date: scheduled, observed: false)

    let duringGrace = evaluator.updatedEntries(
      [entry],
      activeAlarmIDs: [],
      upcomingOccurrenceKeys: [],
      now: scheduled.addingTimeInterval(10)
    )
    let afterGrace = evaluator.updatedEntries(
      duringGrace,
      activeAlarmIDs: [],
      upcomingOccurrenceKeys: [],
      now: scheduled.addingTimeInterval(16)
    )
    #expect(duringGrace.count == 1)
    #expect(afterGrace.isEmpty)
  }

  private func guarded(id: Int64, date: Date, observed: Bool) -> GuardedOccurrence {
    GuardedOccurrence(
      alarmID: id,
      scheduledAt: date,
      kind: .scheduled,
      observedActive: observed
    )
  }
}
