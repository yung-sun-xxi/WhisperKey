import CoreAudio
import Foundation

/// One entry of Core Audio's process list.
///
/// `isRunningOutput` means "has an open output stream", not "is making sound": a paused
/// Chromium helper keeps it up for about 10 s and Apple Music for minutes (#196).
public struct AudioProcess: Equatable, Sendable {
    public let bundleID: String?
    public let pid: pid_t
    public let isRunningOutput: Bool

    public init(bundleID: String?, pid: pid_t, isRunningOutput: Bool) {
        self.bundleID = bundleID
        self.pid = pid
        self.isRunningOutput = isRunningOutput
    }
}

/// Which processes Core Audio knows about, and which of them run output.
///
/// The whole list is returned, not only the processes running output: the end of a
/// recording asks whether the paused process is still there (rule 3), and a player paused
/// for longer than a few seconds has dropped its output flag while keeping its entry.
public protocol AudioOutputProbing: Sendable {
    func audioProcesses() async -> [AudioProcess]
}

/// Core Audio's process objects (macOS 14.2+). Public API, no permission needed.
public struct SystemAudioOutputProbe: AudioOutputProbing {
    public init() {}

    public func audioProcesses() async -> [AudioProcess] {
        // HAL property reads talk to coreaudiod; keep them off the caller's actor.
        await Task.detached(priority: .userInitiated) {
            Self.snapshot()
        }.value
    }

    static func snapshot() -> [AudioProcess] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let stride = MemoryLayout<AudioObjectID>.stride
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / stride)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else {
            return []
        }
        return objects.prefix(Int(size) / stride).compactMap(process(for:))
    }

    private static func process(for object: AudioObjectID) -> AudioProcess? {
        guard let pid: pid_t = scalar(kAudioProcessPropertyPID, of: object) else { return nil }
        let running: UInt32 = scalar(kAudioProcessPropertyIsRunningOutput, of: object) ?? 0
        return AudioProcess(bundleID: bundleID(of: object), pid: pid, isRunningOutput: running != 0)
    }

    private static func scalar<T: FixedWidthInteger>(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func bundleID(of object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() as String?,
              !string.isEmpty
        else { return nil }
        return string
    }
}
