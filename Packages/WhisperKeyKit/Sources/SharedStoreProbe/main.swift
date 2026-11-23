import ClipboardHistoryStore
import Foundation
import HistoryStore
import RecordingRecovery
import UsageStatsStore

// Appends entries to a shared store file through the real store, one at a time, so a test
// can run two copies at once and count what survived. Test-only; the app never runs it.
//
//   SharedStoreProbe <usage|history|clipboard> <file> <count> <tag>
//
// Two more modes stand in for the other app around a recovery file (#233):
//
//   SharedStoreProbe recording <folder> <tenths> <recording id>   a live recording: writes
//       that many tenths of a second to its recovery file, then holds it until killed
//   SharedStoreProbe recover <folder> <cap> <history file>        the recovery at launch

let arguments = CommandLine.arguments
guard arguments.count == 5, let count = Int(arguments[3]) else {
    FileHandle.standardError.write(Data("usage: SharedStoreProbe <usage|history|clipboard> <file> <count> <tag>\n".utf8))
    exit(2)
}
let url = URL(fileURLWithPath: arguments[2])
let tag = arguments[4]

switch arguments[1] {
case "usage":
    let store = UsageStatsStore(url: url)
    for i in 0..<count {
        store.record(providerID: tag, modelID: "probe-\(i)", wordCount: i, audioDurationSeconds: 1,
                     estimatedPriceAtTime: nil, currency: nil)
    }
case "history":
    let store = HistoryStore(url: url, maxEntries: HistoryStore.allowedMaxRange.upperBound)
    for i in 0..<count {
        _ = store.append(text: "\(tag)-\(i)", providerID: tag, language: nil)
    }
case "clipboard":
    let store = ClipboardHistoryStore(url: url, maxEntries: ClipboardHistoryStore.allowedMaxRange.upperBound)
    for i in 0..<count {
        store.record(text: "\(tag)-\(i)", origin: .otherApplication)
    }
case "recording":
    guard let recordingID = UUID(uuidString: tag) else { exit(2) }
    let file = RecoveryFolder(directory: url).makeFile(RecoveryHeader(
        recordingID: recordingID,
        startedAt: Date(timeIntervalSince1970: 1_790_000_000),
        sampleRate: 16_000,
        channelCount: 1,
        providerID: "openai",
        modelID: "gpt-transcribe",
        language: "en"
    ))
    for i in 0..<count {
        file.append(Data(repeating: UInt8(truncatingIfNeeded: i + 1), count: 3_200))
    }
    file.drain()
    print("holding")
    fflush(stdout)
    sleep(60)
case "recover":
    let store = HistoryStore(url: URL(fileURLWithPath: tag), maxEntries: count)
    let report = RecoveryFolder(directory: url).recover(into: store)
    print("recovered \(report.recovered.count)")
default:
    FileHandle.standardError.write(Data("unknown store \(arguments[1])\n".utf8))
    exit(2)
}
