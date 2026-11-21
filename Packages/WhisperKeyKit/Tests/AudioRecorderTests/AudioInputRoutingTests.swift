import CoreAudio
import XCTest
@testable import AudioRecorder

/// The devices of the owner's MacBook Air, as CoreAudio listed them, plus
/// synthetic ones for cases that Mac has no hardware for.
final class AudioInputRoutingTests: XCTestCase {
    // MARK: Real devices

    private static let builtInMic = device(
        101, "MacBook Air Microphone", uid: "BuiltInMicrophoneDevice", model: "Digital Mic",
        transport: kAudioDeviceTransportTypeBuiltIn, inputs: 1, outputs: 0
    )
    private static let builtInSpeakers = device(
        94, "MacBook Air Speakers", uid: "BuiltInSpeakerDevice", model: "Speaker",
        transport: kAudioDeviceTransportTypeBuiltIn, inputs: 0, outputs: 1
    )
    private static let auraSpeaker = device(
        140, "HK Aura Studio 3", uid: "D8-37-3B-51-2B-97:output", model: "ffffffff ffffffff",
        transport: kAudioDeviceTransportTypeBluetooth, inputs: 0, outputs: 1
    )
    private static let g733Output = device(
        116, "G733 Gaming Headset",
        uid: "LogiGamingAudio:Logitech:G733 Gaming Headset:0000000000000000:1",
        model: "G733 Gaming Headset:046D:0AFE",
        transport: kAudioDeviceTransportTypeUSB, inputs: 0, outputs: 1
    )
    private static let g733Input = device(
        121, "G733 Gaming Headset",
        uid: "LogiGamingAudio:Logitech:G733 Gaming Headset:0000000000000000:2",
        model: "G733 Gaming Headset:046D:0AFE",
        transport: kAudioDeviceTransportTypeUSB, inputs: 1, outputs: 0
    )
    private static let iPhoneMic = device(
        146, "iPhone mic", uid: "75045DA7-A5E8-4EF2-97B1-23AC00000003", model: "iPhone Mic",
        transport: kAudioDeviceTransportTypeContinuityCaptureWired, inputs: 1, outputs: 0
    )
    private static let teams = device(
        76, "Microsoft Teams Audio", uid: "MSLoopbackDriverDevice_UID", model: "MSLoopbackDriverDevice_ModelUID",
        transport: kAudioDeviceTransportTypeVirtual, inputs: 1, outputs: 1
    )
    private static let voicemod = device(
        86, "Voicemod Microphone", uid: "VoicemodAudioDeviceBoxDeviceUID", model: "VoicemodAudioDeviceBoxModelUID",
        transport: kAudioDeviceTransportTypeVirtual, inputs: 1, outputs: 1
    )
    private static let display = device(
        125, "BK550Y", uid: "BK550Y-display-audio", model: "BK550Y:display",
        transport: kAudioDeviceTransportTypeDisplayPort, inputs: 0, outputs: 1
    )

    private static let realDevices = [
        builtInMic, builtInSpeakers, auraSpeaker, g733Output, g733Input,
        iPhoneMic, teams, voicemod, display,
    ]

    // MARK: Synthetic devices

    private static let headsetOutput = device(
        200, "Headset", uid: "44-1B-88-F2-0F-0E:output", model: "Headset Model",
        transport: kAudioDeviceTransportTypeBluetooth, inputs: 0, outputs: 1
    )
    // A different model UID on each half: the pair must match on the UID stem
    // alone, not fall through to the same-model rule.
    private static let headsetInput = device(
        201, "Headset", uid: "44-1B-88-F2-0F-0E:input", model: "Headset Model Input",
        transport: kAudioDeviceTransportTypeBluetooth, inputs: 1, outputs: 0
    )
    private static let aggregate = device(
        210, "Aggregate", uid: "aggregate-uid", model: "aggregate-model",
        transport: kAudioDeviceTransportTypeAggregate, inputs: 1, outputs: 1
    )
    private static let usbInterface = device(
        220, "USB Interface", uid: "usb-interface", model: "Interface:1234",
        transport: kAudioDeviceTransportTypeUSB, inputs: 1, outputs: 1
    )

    // MARK: The owner's table

    func testEachRealOutputRoutesToTheExpectedInput() {
        let cases: [(output: AudioDeviceDescriptor, expected: AudioDeviceDescriptor, rule: AudioInputRoute.Rule)] = [
            (Self.builtInSpeakers, Self.builtInMic, .builtInMicrophone),
            (Self.auraSpeaker, Self.builtInMic, .builtInMicrophone),
            (Self.g733Output, Self.g733Input, .sameModel),
            (Self.teams, Self.builtInMic, .builtInMicrophone),
            (Self.voicemod, Self.builtInMic, .builtInMicrophone),
            (Self.display, Self.builtInMic, .builtInMicrophone),
        ]
        for testCase in cases {
            let route = AudioInputRouting.route(for: list(Self.realDevices, output: testCase.output, input: Self.iPhoneMic))
            XCTAssertEqual(route.input?.id, testCase.expected.id, "output \(testCase.output.name ?? "")")
            XCTAssertEqual(route.rule, testCase.rule, "output \(testCase.output.name ?? "")")
            XCTAssertEqual(route.output?.id, testCase.output.id)
        }
    }

    func testVirtualOutputUsesTheBuiltInMicNotItsOwnInput() {
        for virtualOutput in [Self.teams, Self.voicemod, Self.aggregate] {
            let route = AudioInputRouting.route(for: list(
                Self.realDevices + [Self.aggregate],
                output: virtualOutput,
                input: virtualOutput
            ))
            XCTAssertEqual(route.input?.id, Self.builtInMic.id, "output \(virtualOutput.name ?? "")")
        }
    }

    func testBluetoothHeadsetRoutesToItsInputHalf() {
        let route = AudioInputRouting.route(for: list(
            Self.realDevices + [Self.headsetOutput, Self.headsetInput],
            output: Self.headsetOutput,
            input: Self.builtInMic
        ))
        XCTAssertEqual(route.input?.id, Self.headsetInput.id)
        XCTAssertEqual(route.rule, .bluetoothPair)
    }

    func testBluetoothPairNeedsTheInputHalfToHaveInputStreams() {
        let silentInput = Self.device(
            201, "Headset", uid: "44-1B-88-F2-0F-0E:input", model: "Other Model",
            transport: kAudioDeviceTransportTypeBluetooth, inputs: 0, outputs: 0
        )
        let route = AudioInputRouting.route(for: list(
            Self.realDevices + [Self.headsetOutput, silentInput],
            output: Self.headsetOutput,
            input: Self.iPhoneMic
        ))
        XCTAssertEqual(route.input?.id, Self.builtInMic.id)
    }

    func testABluetoothSpeakerDoesNotBorrowAnotherHeadsetsMic() {
        let route = AudioInputRouting.route(for: list(
            Self.realDevices + [Self.headsetOutput, Self.headsetInput],
            output: Self.auraSpeaker,
            input: Self.iPhoneMic
        ))
        XCTAssertEqual(route.input?.id, Self.builtInMic.id)
    }

    func testAnOutputWithItsOwnInputRecordsFromItself() {
        let route = AudioInputRouting.route(for: list(
            Self.realDevices + [Self.usbInterface],
            output: Self.usbInterface,
            input: Self.builtInMic
        ))
        XCTAssertEqual(route.input?.id, Self.usbInterface.id)
        XCTAssertEqual(route.rule, .outputHasInput)
    }

    func testSameModelPrefersTheLongestCommonUIDPrefix() {
        // A second G733 of the same model, another serial. The input whose UID
        // shares more of the output's UID is the one in the same headset.
        let otherHeadsetInput = Self.device(
            131, "G733 Gaming Headset",
            uid: "LogiGamingAudio:Logitech:G733 Gaming Headset:1111111111111111:2",
            model: "G733 Gaming Headset:046D:0AFE",
            transport: kAudioDeviceTransportTypeUSB, inputs: 1, outputs: 0
        )
        for devices in [
            [otherHeadsetInput] + Self.realDevices,
            Self.realDevices + [otherHeadsetInput],
        ] {
            let route = AudioInputRouting.route(for: list(devices, output: Self.g733Output, input: Self.builtInMic))
            XCTAssertEqual(route.input?.id, Self.g733Input.id)
        }
    }

    func testSameModelNeedsTheSameTransport() {
        let bluetoothTwin = Self.device(
            132, "G733 Gaming Headset", uid: "G733-bluetooth:input",
            model: "G733 Gaming Headset:046D:0AFE",
            transport: kAudioDeviceTransportTypeBluetooth, inputs: 1, outputs: 0
        )
        let devices = Self.realDevices.filter { $0.id != Self.g733Input.id } + [bluetoothTwin]
        let route = AudioInputRouting.route(for: list(devices, output: Self.g733Output, input: Self.iPhoneMic))
        XCTAssertEqual(route.input?.id, Self.builtInMic.id)
    }

    func testAnEmptyModelUIDMatchesNothing() {
        let output = Self.device(
            300, "Speaker", uid: "speaker", model: "",
            transport: kAudioDeviceTransportTypeUSB, inputs: 0, outputs: 1
        )
        let input = Self.device(
            301, "Mic", uid: "mic", model: "",
            transport: kAudioDeviceTransportTypeUSB, inputs: 1, outputs: 0
        )
        let route = AudioInputRouting.route(for: list(Self.realDevices + [output, input], output: output, input: Self.iPhoneMic))
        XCTAssertEqual(route.input?.id, Self.builtInMic.id)
    }

    func testAMacWithoutABuiltInMicFallsBackToTheSystemDefaultInput() {
        let devices = Self.realDevices.filter { $0.id != Self.builtInMic.id }
        let route = AudioInputRouting.route(for: list(devices, output: Self.builtInSpeakers, input: Self.iPhoneMic))
        XCTAssertEqual(route.input?.id, Self.iPhoneMic.id)
        XCTAssertEqual(route.rule, .systemDefaultInput)
    }

    func testAnUnknownOutputUsesTheBuiltInMic() {
        let route = AudioInputRouting.route(for: AudioDeviceList(
            devices: Self.realDevices,
            defaultOutputID: nil,
            defaultInputID: Self.iPhoneMic.id
        ))
        XCTAssertEqual(route.input?.id, Self.builtInMic.id)
        XCTAssertNil(route.output)
    }

    func testNoDevicesAtAllGiveNoInput() {
        let route = AudioInputRouting.route(for: AudioDeviceList(devices: [], defaultOutputID: nil, defaultInputID: nil))
        XCTAssertNil(route.input)
        XCTAssertEqual(route.rule, .none)
    }

    // MARK: Prewarm

    func testABluetoothInputIsNotPrewarmed() {
        XCTAssertFalse(AudioInputRouting.allowsPrewarm(input: Self.headsetInput))
        let lowEnergy = Self.device(
            202, "LE", uid: "le:input", model: "le",
            transport: kAudioDeviceTransportTypeBluetoothLE, inputs: 1, outputs: 0
        )
        XCTAssertFalse(AudioInputRouting.allowsPrewarm(input: lowEnergy))
    }

    func testWiredAndBuiltInInputsArePrewarmed() {
        XCTAssertTrue(AudioInputRouting.allowsPrewarm(input: Self.builtInMic))
        XCTAssertTrue(AudioInputRouting.allowsPrewarm(input: Self.g733Input))
        XCTAssertTrue(AudioInputRouting.allowsPrewarm(input: nil))
    }

    // MARK: Helpers

    private static func device(
        _ id: AudioObjectID,
        _ name: String,
        uid: String,
        model: String,
        transport: UInt32,
        inputs: Int,
        outputs: Int
    ) -> AudioDeviceDescriptor {
        AudioDeviceDescriptor(
            id: id,
            name: name,
            uid: uid,
            modelUID: model,
            transportType: transport,
            inputStreamCount: inputs,
            outputStreamCount: outputs
        )
    }

    private func list(
        _ devices: [AudioDeviceDescriptor],
        output: AudioDeviceDescriptor,
        input: AudioDeviceDescriptor
    ) -> AudioDeviceList {
        AudioDeviceList(devices: devices, defaultOutputID: output.id, defaultInputID: input.id)
    }
}
