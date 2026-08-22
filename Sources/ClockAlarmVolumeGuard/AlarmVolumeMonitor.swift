import Darwin
import Foundation

final class AlarmVolumeMonitor {
  private let alarmStore: AlarmStoreReading
  private let audioController: AudioControlling
  private let journalStore: StateJournalPersisting
  private let calculator: AlarmScheduleCalculator
  private let evaluator: GuardSessionEvaluator
  private let logger: StructuredLogger
  private let notifier: RateLimitedNotifier
  private let leadSeconds: TimeInterval
  private let minimumVolume: Float
  private let queue: DispatchQueue

  private var currentJournal: GuardJournal?
  private var directoryDescriptor: Int32 = -1
  private var directorySource: DispatchSourceFileSystemObject?
  private var scheduledTimer: DispatchSourceTimer?
  private var periodicTimer: DispatchSourceTimer?
  private var activeTimer: DispatchSourceTimer?
  private var pendingRefresh: DispatchWorkItem?
  private var scheduledOccurrenceKey: String?
  private var lastRefreshSignature = ""
  private var lastRefreshLoggedAt = Date.distantPast
  private var stopping = false

  init(
    alarmStore: AlarmStoreReading,
    audioController: AudioControlling,
    journalStore: StateJournalPersisting,
    leadSeconds: TimeInterval,
    minimumVolume: Float,
    logger: StructuredLogger,
    notifier: RateLimitedNotifier,
    queue: DispatchQueue = .main
  ) {
    self.alarmStore = alarmStore
    self.audioController = audioController
    self.journalStore = journalStore
    self.leadSeconds = leadSeconds
    self.minimumVolume = minimumVolume
    self.logger = logger
    self.notifier = notifier
    self.queue = queue
    calculator = AlarmScheduleCalculator()
    evaluator = GuardSessionEvaluator()
  }

  func start() {
    logger.info(
      "run_manifest",
      [
        "request": "guard_all_enabled_clock_alarms",
        "database": alarmStore.databaseURL.path,
        "lead_seconds": String(Int(leadSeconds)),
        "minimum_volume": String(format: "%.2f", minimumVolume),
        "expected_evidence": "read_only_alarm_state,coreaudio_state,restore_outcome",
      ])

    do {
      currentJournal = try journalStore.load()
      if currentJournal != nil {
        logger.info("restore_journal_loaded")
      }
    } catch {
      logger.error("restore_journal_load_failed", ["error": error.localizedDescription])
      notifier.notify(
        title: "Clock Alarm Volume Guard",
        message: "저장된 오디오 복원 상태를 읽지 못했습니다. doctor 명령을 실행해 주세요."
      )
    }

    startDirectoryWatch()
    startPeriodicRefresh()
    refresh(reason: "startup")
  }

  func stopAndRestore() {
    guard !stopping else { return }
    stopping = true
    pendingRefresh?.cancel()
    scheduledTimer?.cancel()
    periodicTimer?.cancel()
    activeTimer?.cancel()
    directorySource?.cancel()

    if let currentJournal {
      restoreAudio(for: currentJournal, reason: "monitor_stopped")
    }
    logger.info("monitor_stopped")
  }

  private func startDirectoryWatch() {
    let directoryURL = alarmStore.databaseURL.deletingLastPathComponent()
    directoryDescriptor = open(directoryURL.path, O_EVTONLY)
    guard directoryDescriptor >= 0 else {
      logger.error("database_watch_unavailable", ["path": directoryURL.path])
      return
    }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: directoryDescriptor,
      eventMask: [.write, .extend, .attrib, .link, .rename, .delete, .revoke],
      queue: queue
    )
    source.setEventHandler { [weak self] in
      self?.requestRefresh(reason: "database_changed", debounce: 0.25)
    }
    source.setCancelHandler { [descriptor = directoryDescriptor] in
      if descriptor >= 0 {
        close(descriptor)
      }
    }
    source.resume()
    directorySource = source
  }

  private func startPeriodicRefresh() {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(2))
    timer.setEventHandler { [weak self] in
      self?.refresh(reason: "periodic")
    }
    timer.resume()
    periodicTimer = timer
  }

  private func setActiveRefreshEnabled(_ enabled: Bool) {
    if enabled, activeTimer == nil {
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
      timer.setEventHandler { [weak self] in
        self?.refresh(reason: "active_session")
      }
      timer.resume()
      activeTimer = timer
    } else if !enabled, let activeTimer {
      activeTimer.cancel()
      self.activeTimer = nil
    }
  }

  private func requestRefresh(reason: String, debounce: TimeInterval) {
    pendingRefresh?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.refresh(reason: reason)
    }
    pendingRefresh = work
    queue.asyncAfter(deadline: .now() + debounce, execute: work)
  }

  private func refresh(reason: String) {
    guard !stopping else { return }
    do {
      let alarms = try alarmStore.readAlarms()
      let now = Date()
      let calendar = Calendar.autoupdatingCurrent
      let upcoming = calculator.upcomingOccurrences(for: alarms, after: now, calendar: calendar)
      let active = calculator.activeAlarmOccurrences(for: alarms, at: now)
      let due = upcoming.filter { occurrence in
        occurrence.scheduledAt.addingTimeInterval(-leadSeconds) <= now
          && now <= occurrence.scheduledAt.addingTimeInterval(evaluator.activationObservationGrace)
      }

      if !due.isEmpty || !active.isEmpty {
        try ensureAudioApplied(due: due, active: active)
      }

      if var journal = currentJournal {
        appendMissingOccurrences(due + active, to: &journal)
        let activeIDs = Set(active.map(\.alarmID))
        let upcomingKeys = Set(upcoming.map(\.key))
        journal.guardedOccurrences = evaluator.updatedEntries(
          journal.guardedOccurrences,
          activeAlarmIDs: activeIDs,
          upcomingOccurrenceKeys: upcomingKeys,
          now: now
        )

        if journal.guardedOccurrences.isEmpty, active.isEmpty {
          restoreAudio(for: journal, reason: "alarm_inactive")
        } else {
          try persist(journal)
        }
      }

      setActiveRefreshEnabled(currentJournal != nil)
      scheduleNextTimer(upcoming: upcoming, now: now)
      logSuccessfulRefresh(
        reason: reason,
        alarmCount: alarms.count,
        enabledCount: alarms.filter(\.enabled).count,
        upcomingCount: upcoming.count,
        activeCount: active.count,
        guardedCount: currentJournal?.guardedOccurrences.count ?? 0,
        now: now
      )
    } catch {
      logger.error(
        "alarm_refresh_failed",
        [
          "reason": reason,
          "error": error.localizedDescription,
          "completed_count": "0",
          "incomplete_count": "1",
          "failure_count": "1",
        ])
      notifier.notify(
        title: "Clock Alarm Volume Guard",
        message: "시계 알람 정보를 안전하게 읽지 못했습니다. 오디오는 변경하지 않습니다."
      )
    }
  }

  private func ensureAudioApplied(
    due: [AlarmOccurrence],
    active: [AlarmOccurrence]
  ) throws {
    if var journal = currentJournal {
      appendMissingOccurrences(due + active, to: &journal)
      try persist(journal)
      return
    }

    let snapshot = try audioController.applyMinimumVolume(minimumVolume)
    var entries: [GuardedOccurrence] = []
    appendMissingOccurrences(due + active, to: &entries)
    let journal = GuardJournal(audioSnapshot: snapshot, guardedOccurrences: entries)

    do {
      try journalStore.save(journal)
      currentJournal = journal
    } catch {
      _ = try? audioController.restoreIfUnchanged(snapshot)
      throw error
    }

    logger.info(
      "audio_guard_applied",
      [
        "occurrence_count": String(entries.count),
        "minimum_volume": String(format: "%.2f", minimumVolume),
      ])
  }

  private func appendMissingOccurrences(
    _ occurrences: [AlarmOccurrence],
    to journal: inout GuardJournal
  ) {
    appendMissingOccurrences(occurrences, to: &journal.guardedOccurrences)
  }

  private func appendMissingOccurrences(
    _ occurrences: [AlarmOccurrence],
    to entries: inout [GuardedOccurrence]
  ) {
    var keys = Set(entries.map { $0.occurrence.key })
    for occurrence in occurrences where !keys.contains(occurrence.key) {
      entries.append(
        GuardedOccurrence(
          alarmID: occurrence.alarmID,
          scheduledAt: occurrence.scheduledAt,
          kind: occurrence.kind,
          observedActive: occurrence.kind == .activeRecovery
        )
      )
      keys.insert(occurrence.key)
    }
  }

  private func persist(_ journal: GuardJournal) throws {
    try journalStore.save(journal)
    currentJournal = journal
  }

  private func restoreAudio(for journal: GuardJournal, reason: String) {
    do {
      let outcome = try audioController.restoreIfUnchanged(journal.audioSnapshot)
      try journalStore.clear()
      currentJournal = nil
      setActiveRefreshEnabled(false)
      logger.info(
        "audio_restore_finished",
        [
          "reason": reason,
          "outcome": outcome.rawValue,
        ])
    } catch {
      logger.error(
        "audio_restore_failed",
        [
          "reason": reason,
          "error": error.localizedDescription,
        ])
      notifier.notify(
        title: "Clock Alarm Volume Guard",
        message: "알람 전 오디오 상태를 복원하지 못했습니다. doctor 명령을 확인해 주세요."
      )
    }
  }

  private func scheduleNextTimer(upcoming: [AlarmOccurrence], now: Date) {
    guard
      let next = upcoming.first(where: {
        $0.scheduledAt.addingTimeInterval(-leadSeconds) > now
      })
    else {
      scheduledTimer?.cancel()
      scheduledTimer = nil
      scheduledOccurrenceKey = nil
      return
    }

    guard scheduledOccurrenceKey != next.key else {
      return
    }

    scheduledTimer?.cancel()
    scheduledTimer = nil
    scheduledOccurrenceKey = next.key

    let delay = next.scheduledAt.addingTimeInterval(-leadSeconds).timeIntervalSince(now)
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(
      deadline: .now() + max(delay, 0),
      leeway: .milliseconds(100)
    )
    timer.setEventHandler { [weak self] in
      self?.scheduledOccurrenceKey = nil
      self?.refresh(reason: "scheduled_trigger")
    }
    timer.resume()
    scheduledTimer = timer

    logger.info(
      "next_alarm_scheduled",
      [
        "seconds_until_guard": String(format: "%.1f", delay),
        "kind": next.kind.rawValue,
      ])
  }

  private func logSuccessfulRefresh(
    reason: String,
    alarmCount: Int,
    enabledCount: Int,
    upcomingCount: Int,
    activeCount: Int,
    guardedCount: Int,
    now: Date
  ) {
    let signature = "\(alarmCount):\(enabledCount):\(upcomingCount):\(activeCount):\(guardedCount)"
    let routineRefresh = reason == "periodic" || reason == "active_session"
    guard
      !routineRefresh || signature != lastRefreshSignature
        || now.timeIntervalSince(lastRefreshLoggedAt) >= 30 * 60
    else {
      return
    }

    lastRefreshSignature = signature
    lastRefreshLoggedAt = now
    logger.info(
      "alarm_refresh",
      [
        "reason": reason,
        "alarm_count": String(alarmCount),
        "enabled_count": String(enabledCount),
        "upcoming_count": String(upcomingCount),
        "active_count": String(activeCount),
        "guarded_count": String(guardedCount),
        "completed_count": "1",
        "incomplete_count": "0",
        "failure_count": "0",
      ])
  }
}
