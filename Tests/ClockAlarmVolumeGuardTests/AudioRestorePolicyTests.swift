import Testing

@testable import ClockAlarmVolumeGuard

struct AudioRestorePolicyTests {
  private let applied = DeviceControlState(
    deviceUID: "built-in",
    volumes: ["0": 0.8],
    mutes: ["0": 0]
  )

  @Test func allowsUnchangedAppliedState() {
    #expect(
      AudioRestorePolicy.canRestore(
        currentDefaultOutputUID: "built-in",
        currentDefaultSystemOutputUID: "built-in",
        currentBuiltInState: applied,
        appliedBuiltInState: applied
      ))
  }

  @Test func rejectsManualRouteChange() {
    #expect(
      !AudioRestorePolicy.canRestore(
        currentDefaultOutputUID: "headphones",
        currentDefaultSystemOutputUID: "built-in",
        currentBuiltInState: applied,
        appliedBuiltInState: applied
      ))
  }

  @Test func rejectsManualVolumeOrMuteChange() {
    let volumeChanged = DeviceControlState(
      deviceUID: "built-in",
      volumes: ["0": 0.5],
      mutes: ["0": 0]
    )
    let muteChanged = DeviceControlState(
      deviceUID: "built-in",
      volumes: ["0": 0.8],
      mutes: ["0": 1]
    )

    #expect(
      !AudioRestorePolicy.canRestore(
        currentDefaultOutputUID: "built-in",
        currentDefaultSystemOutputUID: "built-in",
        currentBuiltInState: volumeChanged,
        appliedBuiltInState: applied
      ))
    #expect(
      !AudioRestorePolicy.canRestore(
        currentDefaultOutputUID: "built-in",
        currentDefaultSystemOutputUID: "built-in",
        currentBuiltInState: muteChanged,
        appliedBuiltInState: applied
      ))
  }

  @Test func acceptsMinorHardwareRounding() {
    let rounded = DeviceControlState(
      deviceUID: "built-in",
      volumes: ["0": 0.795],
      mutes: ["0": 0]
    )
    #expect(
      AudioRestorePolicy.canRestore(
        currentDefaultOutputUID: "built-in",
        currentDefaultSystemOutputUID: "built-in",
        currentBuiltInState: rounded,
        appliedBuiltInState: applied
      ))
  }
}
