import ClipboardHistoryStore
import Foundation
import HistoryStore
import UsageStatsStore

// Appends entries to a shared store file through the real store, one at a time, so a test
// can run two copies at once and count what survived. Test-only; the app never runs it.
//
//   SharedStoreProbe <usage|history|clipboard> <file> <count> <tag>

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
default:
    FileHandle.standardError.write(Data("unknown store \(arguments[1])\n".utf8))
    exit(2)
}
