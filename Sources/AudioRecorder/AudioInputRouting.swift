import Foundation
import os
@preconcurrency import CoreAudio

private let routingLog = Logger(subsystem: "WhisperKey", category: "AudioRecorder")

/// One CoreAudio device, as far as choosing a recording input goes.
struct AudioDeviceDescriptor: Equatable, Sendable {
    let id: AudioObjectID
    let name: String?
    let uid: String?
    let modelUID: String?
    let transportType: UInt32
    let inputStreamCount: Int
    let outputStreamCount: Int

    var hasInput: Bool { inputStreamCount > 0 }

    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    var isBuiltIn: Bool { transportType == kAudioDeviceTransportTypeBuiltIn }

    /// A virtual device (Teams, Voicemod, a loopback driver) or an aggregate
    /// one: its own input is never a microphone the user is wearing.
    var isVirtualOrAggregate: Bool {
        transportType == kAudioDeviceTransportTypeVirtual
            || transportType == kAudioDeviceTransportTypeAggregate
            || transportType == kAudioDeviceTransportTypeAutoAggregate
    }

    var inputSnapshot: AudioInputDeviceSnapshot {
        AudioInputDeviceSnapshot(objectID: id, name: name, uid: uid)
    }

    var logDescription: String {
        "id=\(id) name=\(name ?? "nil") uid=\(uid ?? "nil") transport=\(fourCharacterCode(transportType)) in=\(inputStreamCount) out=\(outputStreamCount)"
    }
}

/// Every audio device and the system defaults, read at one moment.
struct AudioDeviceList: Equatable, Sendable {
    let devices: [AudioDeviceDescriptor]
    let defaultOutputID: AudioObjectID?
    let defaultInputID: AudioObjectID?

    func device(id: AudioObjectID?) -> AudioDeviceDescriptor? {
        guard let id else { return nil }
        return devices.first { $0.id == id }
    }
}

/// The input WhisperKey records from, derived from the default output.
struct AudioInputRoute: Equatable, Sendable {
    enum Rule: String, Sendable {
        /// The output device has a microphone of its own.
        case outputHasInput
        /// A Bluetooth output `<stem>:output` paired with `<stem>:input`.
        case bluetoothPair
        /// A USB-style device exposing its output and its mic as two devices
        /// with one transport and one model UID.
        case sameModel
        case builtInMicrophone
        case systemDefaultInput
        case none
    }

    let output: AudioDeviceDescriptor?
    let input: AudioDeviceDescriptor?
    let rule: Rule

    var logDescription: String {
        "rule=\(rule.rawValue) output=[\(output?.logDescription ?? "nil")] input=[\(input?.logDescription ?? "nil")]"
    }
}

/// The input follows the system default output: a headset records from its
/// own mic, a plain speaker from the built-in one. Pure: no CoreAudio here.
enum AudioInputRouting {
    static let bluetoothOutputSuffix = ":output"
    static let bluetoothInputSuffix = ":input"

    /// In order:
    /// 1. a virtual or aggregate output → the built-in mic;
    /// 2. an output with input streams of its own → that device;
    /// 3. a Bluetooth output `<stem>:output` → the device `<stem>:input`;
    /// 4. a device with the output's transport and non-empty model UID (USB
    ///    headsets list output and mic as two devices), preferring the
    ///    longest UID prefix shared with the output;
    /// 5. the built-in mic;
    /// 6. with no built-in mic, the system default input.
    /// Every candidate input must have input streams.
    static func route(for list: AudioDeviceList) -> AudioInputRoute {
        let output = list.device(id: list.defaultOutputID)
        if let output, !output.isVirtualOrAggregate {
            if let input = matchingInput(for: output, in: list.devices) {
                return AudioInputRoute(output: output, input: input.device, rule: input.rule)
            }
        }
        if let builtIn = list.devices.first(where: { $0.isBuiltIn && $0.hasInput }) {
            return AudioInputRoute(output: output, input: builtIn, rule: .builtInMicrophone)
        }
        if let fallback = list.device(id: list.defaultInputID) {
            return AudioInputRoute(output: output, input: fallback, rule: .systemDefaultInput)
        }
        return AudioInputRoute(output: output, input: nil, rule: .none)
    }

    /// A prepared engine bound to a Bluetooth mic may switch the headset to
    /// its HFP profile before anything is recorded, which degrades its
    /// playback. Such an engine is built when the capture starts instead.
    static func allowsPrewarm(input: AudioDeviceDescriptor?) -> Bool {
        !(input?.isBluetooth ?? false)
    }

    private static func matchingInput(
        for output: AudioDeviceDescriptor,
        in devices: [AudioDeviceDescriptor]
    ) -> (device: AudioDeviceDescriptor, rule: AudioInputRoute.Rule)? {
        if output.hasInput {
            return (output, .outputHasInput)
        }
        if output.isBluetooth, let uid = output.uid, uid.hasSuffix(bluetoothOutputSuffix) {
            let inputUID = String(uid.dropLast(bluetoothOutputSuffix.count)) + bluetoothInputSuffix
            if let input = devices.first(where: { $0.uid == inputUID && $0.hasInput }) {
                return (input, .bluetoothPair)
            }
        }
        if let model = output.modelUID, !model.isEmpty {
            let candidates = devices.filter {
                $0.id != output.id
                    && $0.hasInput
                    && $0.transportType == output.transportType
                    && $0.modelUID == model
            }
            let outputUID = output.uid ?? ""
            // `max(by:)` keeps the last of equal elements; the first listed
            // wins a tie instead, so the choice does not flip between reads.
            var best: (device: AudioDeviceDescriptor, prefix: Int)?
            for candidate in candidates {
                let prefix = commonPrefixLength(outputUID, candidate.uid ?? "")
                if best == nil || prefix > best!.prefix {
                    best = (candidate, prefix)
                }
            }
            if let best {
                return (best.device, .sameModel)
            }
        }
        return nil
    }

    private static func commonPrefixLength(_ lhs: String, _ rhs: String) -> Int {
        zip(lhs, rhs).prefix { $0 == $1 }.count
    }
}

// MARK: - Reading the device list from CoreAudio

extension AudioDeviceList {
    /// Reads every device. CoreAudio IPC: call it on an engine host's queue,
    /// never on the recorder actor.
    static func current() -> AudioDeviceList? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size)
        guard status == noErr else {
            routingLog.error("deviceList: devices size status=\(status, privacy: .public)")
            return nil
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        status = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids)
        guard status == noErr else {
            routingLog.error("deviceList: devices status=\(status, privacy: .public)")
            return nil
        }
        let devices = ids.map { id in
            AudioDeviceDescriptor(
                id: id,
                name: stringProperty(kAudioObjectPropertyName, objectID: id),
                uid: stringProperty(kAudioDevicePropertyDeviceUID, objectID: id),
                modelUID: stringProperty(kAudioDevicePropertyModelUID, objectID: id),
                transportType: uint32Property(kAudioDevicePropertyTransportType, objectID: id) ?? 0,
                inputStreamCount: streamCount(objectID: id, scope: kAudioDevicePropertyScopeInput),
                outputStreamCount: streamCount(objectID: id, scope: kAudioDevicePropertyScopeOutput)
            )
        }
        return AudioDeviceList(
            devices: devices,
            defaultOutputID: defaultDevice(kAudioHardwarePropertyDefaultOutputDevice),
            defaultInputID: defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        )
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        guard
            let id = uint32Property(selector, objectID: AudioObjectID(kAudioObjectSystemObject)),
            id != kAudioObjectUnknown
        else {
            return nil
        }
        return id
    }

    private static func uint32Property(_ selector: AudioObjectPropertySelector, objectID: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func streamCount(objectID: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
        guard status == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }
}

func fourCharacterCode(_ value: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
    guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return String(value) }
    return String(decoding: bytes, as: UTF8.self)
}

// MARK: - Noticing a change of the default output

/// Tells the recorder that the system default output changed. The handler is
/// called on a queue of the observer's own, never on the recorder actor.
protocol AudioRouteChangeObserving: AnyObject, Sendable {
    /// Starts delivering changes to `handler`. A later call replaces it.
    func start(_ handler: @escaping @Sendable () -> Void)
    func stop()
}

/// Never reports a change. The default for tests that do not exercise one.
final class NoAudioRouteChangeObserver: AudioRouteChangeObserving {
    func start(_ handler: @escaping @Sendable () -> Void) {}
    func stop() {}
}

/// A CoreAudio property listener on `kAudioHardwarePropertyDefaultOutputDevice`.
///
/// Registration is CoreAudio IPC, so it runs on the observer's own queue; the
/// listener block runs there too and only forwards the event.
final class DefaultOutputDeviceObserver: AudioRouteChangeObserving, @unchecked Sendable {
    private let queue = DispatchQueue(label: "WhisperKey.AudioRecorder.defaultOutputObserver", qos: .userInitiated)
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?
    // Touched only from `queue`.
    private var listener: AudioObjectPropertyListenerBlock?

    private static var address: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    func start(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
        queue.async { [self] in
            guard listener == nil else { return }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.deliver()
            }
            var address = Self.address
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                block
            )
            if status == noErr {
                listener = block
            } else {
                routingLog.error("defaultOutputObserver: AudioObjectAddPropertyListenerBlock failed status=\(status, privacy: .public)")
            }
        }
    }

    func stop() {
        lock.lock()
        handler = nil
        lock.unlock()
        queue.async { [self] in
            guard let block = listener else { return }
            listener = nil
            var address = Self.address
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                block
            )
        }
    }

    private func deliver() {
        lock.lock()
        let handler = handler
        lock.unlock()
        routingLog.notice("defaultOutputObserver: the default output device changed")
        handler?()
    }
}
