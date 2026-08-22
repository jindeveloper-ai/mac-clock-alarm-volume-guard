import CoreAudio
import Foundation

protocol AudioControlling {
  func diagnostics() throws -> AudioDiagnostics
  func applyMinimumVolume(_ minimumVolume: Float) throws -> AudioRouteSnapshot
  func restoreIfUnchanged(_ snapshot: AudioRouteSnapshot) throws -> RestoreOutcome
}

enum AudioControllerError: LocalizedError {
  case coreAudio(operation: String, status: OSStatus)
  case noBuiltInOutput
  case noSoftwareVolumeControl
  case invalidControlValue(String)

  var errorDescription: String? {
    switch self {
    case .coreAudio(let operation, let status):
      return "CoreAudio \(operation) failed with status \(status)"
    case .noBuiltInOutput:
      return "No built-in output device is available"
    case .noSoftwareVolumeControl:
      return "The built-in output has no writable software volume control"
    case .invalidControlValue(let value):
      return "Invalid audio control value: \(value)"
    }
  }
}

final class CoreAudioController: AudioControlling {
  private let systemObject = AudioObjectID(kAudioObjectSystemObject)
  private let masterElement = AudioObjectPropertyElement(kAudioObjectPropertyElementMain)

  func diagnostics() throws -> AudioDiagnostics {
    let builtIn = try builtInOutputDevice()
    let state = try captureControlState(for: builtIn)
    return AudioDiagnostics(
      builtInDeviceName: try stringProperty(
        objectID: builtIn,
        selector: kAudioObjectPropertyName
      ) ?? "Built-in Output",
      builtInDeviceUID: state.deviceUID,
      defaultOutputUID: try defaultDeviceUID(selector: kAudioHardwarePropertyDefaultOutputDevice),
      defaultSystemOutputUID: try defaultDeviceUID(
        selector: kAudioHardwarePropertyDefaultSystemOutputDevice
      ),
      volumeValues: state.volumes,
      muteValues: state.mutes
    )
  }

  func applyMinimumVolume(_ minimumVolume: Float) throws -> AudioRouteSnapshot {
    guard (0...1).contains(minimumVolume) else {
      throw AudioControllerError.invalidControlValue(String(minimumVolume))
    }

    let builtIn = try builtInOutputDevice()
    let previousDefaultOutputUID = try defaultDeviceUID(
      selector: kAudioHardwarePropertyDefaultOutputDevice
    )
    let previousDefaultSystemOutputUID = try defaultDeviceUID(
      selector: kAudioHardwarePropertyDefaultSystemOutputDevice
    )
    let before = try captureControlState(for: builtIn)

    do {
      try setDefaultDevice(builtIn, selector: kAudioHardwarePropertyDefaultOutputDevice)
      try setDefaultDevice(builtIn, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
      try setMuted(false, deviceID: builtIn)
      try setMinimumVolume(minimumVolume, deviceID: builtIn)
    } catch {
      try? restoreControls(before, to: builtIn)
      if let previousDefaultOutputUID,
        let previousOutput = try? deviceID(forUID: previousDefaultOutputUID)
      {
        try? setDefaultDevice(previousOutput, selector: kAudioHardwarePropertyDefaultOutputDevice)
      }
      if let previousDefaultSystemOutputUID,
        let previousSystemOutput = try? deviceID(forUID: previousDefaultSystemOutputUID)
      {
        try? setDefaultDevice(
          previousSystemOutput,
          selector: kAudioHardwarePropertyDefaultSystemOutputDevice
        )
      }
      throw error
    }

    let applied = try captureControlState(for: builtIn)
    return AudioRouteSnapshot(
      previousDefaultOutputUID: previousDefaultOutputUID,
      previousDefaultSystemOutputUID: previousDefaultSystemOutputUID,
      builtInBefore: before,
      builtInApplied: applied,
      appliedAt: Date()
    )
  }

  func restoreIfUnchanged(_ snapshot: AudioRouteSnapshot) throws -> RestoreOutcome {
    guard let builtIn = try deviceID(forUID: snapshot.builtInApplied.deviceUID) else {
      throw AudioControllerError.noBuiltInOutput
    }

    let currentDefaultOutputUID = try defaultDeviceUID(
      selector: kAudioHardwarePropertyDefaultOutputDevice
    )
    let currentDefaultSystemOutputUID = try defaultDeviceUID(
      selector: kAudioHardwarePropertyDefaultSystemOutputDevice
    )
    let currentState = try captureControlState(for: builtIn)

    guard
      AudioRestorePolicy.canRestore(
        currentDefaultOutputUID: currentDefaultOutputUID,
        currentDefaultSystemOutputUID: currentDefaultSystemOutputUID,
        currentBuiltInState: currentState,
        appliedBuiltInState: snapshot.builtInApplied
      )
    else {
      return .skippedUserChange
    }

    try restoreControls(snapshot.builtInBefore, to: builtIn)
    var routeFullyRestored = true

    if let outputUID = snapshot.previousDefaultOutputUID {
      if let outputDevice = try deviceID(forUID: outputUID) {
        try setDefaultDevice(outputDevice, selector: kAudioHardwarePropertyDefaultOutputDevice)
      } else {
        routeFullyRestored = false
      }
    }

    if let systemOutputUID = snapshot.previousDefaultSystemOutputUID {
      if let systemOutputDevice = try deviceID(forUID: systemOutputUID) {
        try setDefaultDevice(
          systemOutputDevice,
          selector: kAudioHardwarePropertyDefaultSystemOutputDevice
        )
      } else {
        routeFullyRestored = false
      }
    }

    return routeFullyRestored ? .restored : .partiallyRestored
  }

  private func builtInOutputDevice() throws -> AudioDeviceID {
    let currentDefault = try defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
    let candidates = try allDeviceIDs().filter { deviceID in
      guard
        let transport: UInt32 = try? scalarProperty(
          objectID: deviceID,
          selector: kAudioDevicePropertyTransportType
        ), transport == kAudioDeviceTransportTypeBuiltIn
      else {
        return false
      }
      return (try? outputChannelCount(deviceID: deviceID)) ?? 0 > 0
    }

    if let currentDefault, candidates.contains(currentDefault) {
      return currentDefault
    }
    guard
      let best = try candidates.max(by: {
        try outputChannelCount(deviceID: $0) < outputChannelCount(deviceID: $1)
      })
    else {
      throw AudioControllerError.noBuiltInOutput
    }
    return best
  }

  private func allDeviceIDs() throws -> [AudioDeviceID] {
    var address = address(
      selector: kAudioHardwarePropertyDevices,
      scope: kAudioObjectPropertyScopeGlobal,
      element: masterElement
    )
    var size: UInt32 = 0
    try check(
      AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size),
      operation: "read device-list size"
    )
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    guard count > 0 else {
      return []
    }
    var devices = Array(repeating: AudioDeviceID(kAudioObjectUnknown), count: count)
    try devices.withUnsafeMutableBytes { buffer in
      var mutableSize = size
      try check(
        AudioObjectGetPropertyData(
          systemObject,
          &address,
          0,
          nil,
          &mutableSize,
          buffer.baseAddress!
        ),
        operation: "read device list"
      )
    }
    return devices
  }

  private func defaultDeviceID(selector: AudioObjectPropertySelector) throws -> AudioDeviceID? {
    let device: AudioDeviceID = try scalarProperty(objectID: systemObject, selector: selector)
    return device == kAudioObjectUnknown ? nil : device
  }

  private func defaultDeviceUID(selector: AudioObjectPropertySelector) throws -> String? {
    guard let device = try defaultDeviceID(selector: selector) else {
      return nil
    }
    return try stringProperty(objectID: device, selector: kAudioDevicePropertyDeviceUID)
  }

  private func deviceID(forUID uid: String) throws -> AudioDeviceID? {
    for deviceID in try allDeviceIDs() {
      if try stringProperty(objectID: deviceID, selector: kAudioDevicePropertyDeviceUID) == uid {
        return deviceID
      }
    }
    return nil
  }

  private func setDefaultDevice(
    _ deviceID: AudioDeviceID,
    selector: AudioObjectPropertySelector
  ) throws {
    var address = address(
      selector: selector,
      scope: kAudioObjectPropertyScopeGlobal,
      element: masterElement
    )
    var mutableDeviceID = deviceID
    try check(
      AudioObjectSetPropertyData(
        systemObject,
        &address,
        0,
        nil,
        UInt32(MemoryLayout<AudioDeviceID>.size),
        &mutableDeviceID
      ),
      operation: "set default output"
    )
  }

  private func outputChannelCount(deviceID: AudioDeviceID) throws -> Int {
    var address = address(
      selector: kAudioDevicePropertyStreamConfiguration,
      scope: kAudioObjectPropertyScopeOutput,
      element: masterElement
    )
    var size: UInt32 = 0
    try check(
      AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size),
      operation: "read output stream size"
    )

    let storage = UnsafeMutableRawPointer.allocate(
      byteCount: Int(size),
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { storage.deallocate() }

    var mutableSize = size
    try check(
      AudioObjectGetPropertyData(deviceID, &address, 0, nil, &mutableSize, storage),
      operation: "read output streams"
    )
    let list = UnsafeMutableAudioBufferListPointer(
      storage.assumingMemoryBound(to: AudioBufferList.self)
    )
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
  }

  private func captureControlState(for deviceID: AudioDeviceID) throws -> DeviceControlState {
    guard let uid = try stringProperty(objectID: deviceID, selector: kAudioDevicePropertyDeviceUID)
    else {
      throw AudioControllerError.noBuiltInOutput
    }

    let channelCount = try outputChannelCount(deviceID: deviceID)
    let volumeElements = controlElements(
      deviceID: deviceID,
      selector: kAudioDevicePropertyVolumeScalar,
      channelCount: channelCount
    )
    let muteElements = controlElements(
      deviceID: deviceID,
      selector: kAudioDevicePropertyMute,
      channelCount: channelCount
    )

    var volumes: [String: Float] = [:]
    for element in volumeElements {
      let value: Float32 = try scalarProperty(
        objectID: deviceID,
        selector: kAudioDevicePropertyVolumeScalar,
        scope: kAudioObjectPropertyScopeOutput,
        element: element
      )
      volumes[String(element)] = value
    }

    var mutes: [String: UInt32] = [:]
    for element in muteElements {
      let value: UInt32 = try scalarProperty(
        objectID: deviceID,
        selector: kAudioDevicePropertyMute,
        scope: kAudioObjectPropertyScopeOutput,
        element: element
      )
      mutes[String(element)] = value
    }

    return DeviceControlState(deviceUID: uid, volumes: volumes, mutes: mutes)
  }

  private func controlElements(
    deviceID: AudioDeviceID,
    selector: AudioObjectPropertySelector,
    channelCount: Int
  ) -> [AudioObjectPropertyElement] {
    if hasProperty(
      objectID: deviceID,
      selector: selector,
      scope: kAudioObjectPropertyScopeOutput,
      element: masterElement
    ) {
      return [masterElement]
    }

    return (1...max(channelCount, 1)).compactMap { channel -> AudioObjectPropertyElement? in
      let element = AudioObjectPropertyElement(channel)
      return hasProperty(
        objectID: deviceID,
        selector: selector,
        scope: kAudioObjectPropertyScopeOutput,
        element: element
      ) ? element : nil
    }
  }

  private func setMuted(_ muted: Bool, deviceID: AudioDeviceID) throws {
    let channelCount = try outputChannelCount(deviceID: deviceID)
    let elements = controlElements(
      deviceID: deviceID,
      selector: kAudioDevicePropertyMute,
      channelCount: channelCount
    )
    for element in elements
    where try isSettable(
      objectID: deviceID,
      selector: kAudioDevicePropertyMute,
      scope: kAudioObjectPropertyScopeOutput,
      element: element
    ) {
      try setScalarProperty(
        objectID: deviceID,
        selector: kAudioDevicePropertyMute,
        value: muted ? UInt32(1) : UInt32(0),
        scope: kAudioObjectPropertyScopeOutput,
        element: element
      )
    }
  }

  private func setMinimumVolume(_ minimumVolume: Float, deviceID: AudioDeviceID) throws {
    let channelCount = try outputChannelCount(deviceID: deviceID)
    let elements = controlElements(
      deviceID: deviceID,
      selector: kAudioDevicePropertyVolumeScalar,
      channelCount: channelCount
    )
    var writableCount = 0
    for element in elements
    where try isSettable(
      objectID: deviceID,
      selector: kAudioDevicePropertyVolumeScalar,
      scope: kAudioObjectPropertyScopeOutput,
      element: element
    ) {
      writableCount += 1
      let current: Float32 = try scalarProperty(
        objectID: deviceID,
        selector: kAudioDevicePropertyVolumeScalar,
        scope: kAudioObjectPropertyScopeOutput,
        element: element
      )
      if current < minimumVolume {
        try setScalarProperty(
          objectID: deviceID,
          selector: kAudioDevicePropertyVolumeScalar,
          value: Float32(minimumVolume),
          scope: kAudioObjectPropertyScopeOutput,
          element: element
        )
      }
    }
    guard writableCount > 0 else {
      throw AudioControllerError.noSoftwareVolumeControl
    }
  }

  private func restoreControls(_ state: DeviceControlState, to deviceID: AudioDeviceID) throws {
    for (elementText, volume) in state.volumes {
      guard let element = UInt32(elementText),
        try isSettable(
          objectID: deviceID,
          selector: kAudioDevicePropertyVolumeScalar,
          scope: kAudioObjectPropertyScopeOutput,
          element: element
        )
      else { continue }
      try setScalarProperty(
        objectID: deviceID,
        selector: kAudioDevicePropertyVolumeScalar,
        value: volume,
        scope: kAudioObjectPropertyScopeOutput,
        element: element
      )
    }

    for (elementText, mute) in state.mutes {
      guard let element = UInt32(elementText),
        try isSettable(
          objectID: deviceID,
          selector: kAudioDevicePropertyMute,
          scope: kAudioObjectPropertyScopeOutput,
          element: element
        )
      else { continue }
      try setScalarProperty(
        objectID: deviceID,
        selector: kAudioDevicePropertyMute,
        value: mute,
        scope: kAudioObjectPropertyScopeOutput,
        element: element
      )
    }
  }

  private func hasProperty(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement
  ) -> Bool {
    var address = address(selector: selector, scope: scope, element: element)
    return AudioObjectHasProperty(objectID, &address)
  }

  private func isSettable(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope,
    element: AudioObjectPropertyElement
  ) throws -> Bool {
    var address = address(selector: selector, scope: scope, element: element)
    var settable: DarwinBoolean = false
    try check(
      AudioObjectIsPropertySettable(objectID, &address, &settable),
      operation: "check writable audio property"
    )
    return settable.boolValue
  }

  private func scalarProperty<T: BitwiseCopyable>(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement? = nil
  ) throws -> T {
    var address = address(
      selector: selector,
      scope: scope,
      element: element ?? masterElement
    )
    let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { pointer.deallocate() }
    var size = UInt32(MemoryLayout<T>.size)
    try check(
      AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer),
      operation: "read scalar audio property"
    )
    return pointer.pointee
  }

  private func setScalarProperty<T: BitwiseCopyable>(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    value: T,
    scope: AudioObjectPropertyScope,
    element: AudioObjectPropertyElement
  ) throws {
    var address = address(selector: selector, scope: scope, element: element)
    var mutableValue = value
    try check(
      AudioObjectSetPropertyData(
        objectID,
        &address,
        0,
        nil,
        UInt32(MemoryLayout<T>.size),
        &mutableValue
      ),
      operation: "set scalar audio property"
    )
  }

  private func stringProperty(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector
  ) throws -> String? {
    var address = address(
      selector: selector,
      scope: kAudioObjectPropertyScopeGlobal,
      element: masterElement
    )
    guard AudioObjectHasProperty(objectID, &address) else {
      return nil
    }
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try check(
      AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value),
      operation: "read string audio property"
    )
    return value?.takeRetainedValue() as String?
  }

  private func address(
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope,
    element: AudioObjectPropertyElement
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
  }

  private func check(_ status: OSStatus, operation: String) throws {
    guard status == noErr else {
      throw AudioControllerError.coreAudio(operation: operation, status: status)
    }
  }
}
