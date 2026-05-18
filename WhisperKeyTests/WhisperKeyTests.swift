//
//  WhisperKeyTests.swift
//  WhisperKeyTests
//
//  Created by Александр Степаненков on 08/05/2026.
//

import Testing
@testable import WhisperKey

struct WhisperKeyTests {

    @MainActor
    @Test func recoverableErrorsDoNotBlockNextRecordingStart() {
        #expect(AppCoordinator.canStartRecording(from: .idle))
        #expect(AppCoordinator.canStartRecording(from: .error("Set the API key in Settings.")))
    }

    @MainActor
    @Test func activeAndPermissionStatesBlockRecordingStart() {
        #expect(!AppCoordinator.canStartRecording(from: .recording))
        #expect(!AppCoordinator.canStartRecording(from: .transcribing))
        #expect(!AppCoordinator.canStartRecording(from: .microphoneDenied))
        #expect(!AppCoordinator.canStartRecording(from: .accessibilityDenied))
    }

}
