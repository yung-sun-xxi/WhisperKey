import XCTest

/// Proof that the lock holds between processes, not only between two instances in one.
///
/// `SharedStoreProbe` appends through the real store, one entry per call, the way the
/// release and the dev app each would. Two copies run at once on one file; every entry from
/// both must be there at the end.
final class CrossProcessTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WhisperKey-CrossProcessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    /// The probe is built next to the test bundle because the test target depends on it.
    private func probeURL() throws -> URL {
        let url = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("SharedStoreProbe")
        // A failure, not a skip: a missing probe must not quietly turn the proof off.
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path), "SharedStoreProbe not found at \(url.path)")
        return url
    }

    /// Runs two probes at once and returns the file's decoded JSON array.
    private func runTwoProbes(store: String, fileName: String, perProbe: Int) throws -> [[String: Any]] {
        let probe = try probeURL()
        let file = tempDir.appendingPathComponent(fileName)
        let processes = ["one", "two"].map { tag -> Process in
            let process = Process()
            process.executableURL = probe
            process.arguments = [store, file.path, String(perProbe), tag]
            return process
        }
        for process in processes { try process.run() }

        // Bounded wait: 60 s for both.
        let deadline = Date().addingTimeInterval(60)
        while processes.contains(where: \.isRunning), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        for process in processes where process.isRunning { process.terminate() }
        for process in processes {
            XCTAssertFalse(process.isRunning, "probe did not finish in 60 s")
            XCTAssertEqual(process.terminationStatus, 0)
        }

        let data = try Data(contentsOf: file)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    func testTwoProcessesAppendingUsageLoseNothing() throws {
        let entries = try runTwoProbes(store: "usage", fileName: "usage-stats.json", perProbe: 100)
        XCTAssertEqual(entries.count, 200)
        XCTAssertEqual(entries.filter { $0["providerID"] as? String == "one" }.count, 100)
        XCTAssertEqual(entries.filter { $0["providerID"] as? String == "two" }.count, 100)
    }

    func testTwoProcessesAppendingHistoryLoseNothing() throws {
        let entries = try runTwoProbes(store: "history", fileName: "history.json", perProbe: 100)
        XCTAssertEqual(entries.count, 200)
        XCTAssertEqual(entries.filter { $0["provider"] as? String == "one" }.count, 100)
        XCTAssertEqual(entries.filter { $0["provider"] as? String == "two" }.count, 100)
    }

    func testTwoProcessesRecordingClipboardLoseNothing() throws {
        let entries = try runTwoProbes(store: "clipboard", fileName: "clipboard-history.json", perProbe: 100)
        XCTAssertEqual(entries.count, 200)
        XCTAssertEqual(entries.filter { ($0["text"] as? String)?.hasPrefix("one-") == true }.count, 100)
        XCTAssertEqual(entries.filter { ($0["text"] as? String)?.hasPrefix("two-") == true }.count, 100)
    }
}
