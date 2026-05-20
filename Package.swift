// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WhisperKeyKit",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "WhisperKeyKit", targets: ["WhisperKeyKit"]),
        .library(name: "HotkeyEngine", targets: ["HotkeyEngine"]),
        .library(name: "AudioRecorder", targets: ["AudioRecorder"]),
        .library(name: "AudioEncoder", targets: ["AudioEncoder"]),
        .library(name: "TranscriptionProvider", targets: ["TranscriptionProvider"]),
        .library(name: "PasteEngine", targets: ["PasteEngine"]),
        .library(name: "HistoryStore", targets: ["HistoryStore"]),
        .library(name: "KeychainStore", targets: ["KeychainStore"]),
        .library(name: "SettingsStore", targets: ["SettingsStore"]),
        .library(name: "UsageStatsStore", targets: ["UsageStatsStore"]),
        .library(name: "ErrorToast", targets: ["ErrorToast"]),
        .library(name: "LoginItem", targets: ["LoginItem"]),
        .library(name: "SingleInstance", targets: ["SingleInstance"]),
    ],
    targets: [
        .target(name: "HotkeyEngine"),
        .target(name: "AudioRecorder"),
        .target(name: "AudioEncoder", dependencies: ["AudioRecorder"]),
        .target(name: "TranscriptionProvider", dependencies: ["AudioEncoder"]),
        .target(name: "PasteEngine"),
        .target(name: "HistoryStore"),
        .target(name: "KeychainStore"),
        .target(name: "SettingsStore", dependencies: ["HotkeyEngine", "KeychainStore", "TranscriptionProvider", "UsageStatsStore"]),
        .target(name: "UsageStatsStore"),
        .target(name: "ErrorToast", dependencies: ["TranscriptionProvider"]),
        .target(name: "LoginItem"),
        .target(name: "SingleInstance"),
        .target(
            name: "WhisperKeyKit",
            dependencies: [
                "HotkeyEngine",
                "AudioRecorder",
                "AudioEncoder",
                "TranscriptionProvider",
                "PasteEngine",
                "HistoryStore",
                "KeychainStore",
                "SettingsStore",
                "UsageStatsStore",
                "ErrorToast",
                "LoginItem",
                "SingleInstance",
            ]
        ),

        .testTarget(name: "HotkeyEngineTests", dependencies: ["HotkeyEngine"]),
        .testTarget(name: "AudioRecorderTests", dependencies: ["AudioRecorder"]),
        .testTarget(name: "AudioEncoderTests", dependencies: ["AudioEncoder"]),
        .testTarget(name: "TranscriptionProviderTests", dependencies: ["TranscriptionProvider"]),
        .testTarget(name: "PasteEngineTests", dependencies: ["PasteEngine"]),
        .testTarget(name: "HistoryStoreTests", dependencies: ["HistoryStore"]),
        .testTarget(name: "KeychainStoreTests", dependencies: ["KeychainStore"]),
        .testTarget(name: "SettingsStoreTests", dependencies: ["SettingsStore"]),
        .testTarget(name: "UsageStatsStoreTests", dependencies: ["UsageStatsStore", "TranscriptionProvider", "HistoryStore"]),
        .testTarget(name: "ErrorToastTests", dependencies: ["ErrorToast", "TranscriptionProvider"]),
        .testTarget(name: "LoginItemTests", dependencies: ["LoginItem"]),
        .testTarget(name: "SingleInstanceTests", dependencies: ["SingleInstance"]),
    ]
)
