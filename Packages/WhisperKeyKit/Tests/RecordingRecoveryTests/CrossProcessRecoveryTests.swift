import XCTest
@testable import HistoryStore
@testable import RecordingRecovery

/// A real second process stands in for the other app: it holds its recording's file open
/// and is then killed, or it recovers the same leftover at the same time.
final class CrossProcessRecoveryTests: RecoveryTestCase {
    /// The probe is built next to the test bundle because the test target depends on it.
    private func probe(_ arguments: [String], output: Pipe? = nil) throws -> Process {
        let url = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("SharedStoreProbe")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path), "SharedStoreProbe not found at \(url.path)")
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        process.standardOutput = output ?? FileHandle.nullDevice
        return process
    }

    func testALiveProcessOwnsItsFileAndSIGKILLReleasesIt() throws {
        let id = UUID()
        let output = Pipe()
        let process = try probe(["recording", folder.directory.path, "20", id.uuidString], output: output)
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        XCTAssertTrue(waitUntil(20) { exists(folder.url(for: id)) && isLocked(folder.url(for: id)) })
        XCTAssertTrue(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).contains("holding"))

        let history = makeHistory()
        XCTAssertEqual(folder.recover(into: history), RecoveryReport(ownedByLiveProcess: 1))
        XCTAssertEqual(history.entries, [])
        XCTAssertEqual(folder.recover(into: makeHistory(cap: 0)), RecoveryReport(ownedByLiveProcess: 1))
        XCTAssertTrue(exists(folder.url(for: id)))

        XCTAssertTrue(process.isRunning)
        kill(process.processIdentifier, SIGKILL)
        XCTAssertTrue(waitUntil(20) { !process.isRunning })
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)

        XCTAssertEqual(folder.recover(into: history).recovered, [id])
        let entry = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(entry.audioDurationSeconds ?? 0, 2, accuracy: 0.001, "everything written before the kill")
        var expected = Data()
        for tenth in 1...20 { expected.append(Data(repeating: UInt8(tenth), count: 3_200)) }
        XCTAssertEqual(try samples(of: entry, in: history), expected)
        XCTAssertEqual(recoveryFiles, [])
    }

    func testTwoProcessesRecoveringAtOnceMakeOneRowPerFile() throws {
        for round in 0..<5 {
            let headers = (0..<8).map { makeHeader(startedAt: Date(timeIntervalSince1970: Double(1_000 * (round + 1) + $0))) }
            for header in headers { _ = try leaveFile(header, pcm: pcm(1)) }
            let processes = try (0..<2).map { _ in try probe(["recover", folder.directory.path, "1000", historyURL.path]) }
            for process in processes { try process.run() }
            XCTAssertTrue(waitUntil(30) { !processes.contains(where: \.isRunning) })
            for process in processes where process.isRunning { process.terminate() }
            let rows = rowsOnDisk().map(\.id)
            XCTAssertEqual(rows.count, 8 * (round + 1))
            XCTAssertEqual(Set(rows).count, rows.count)
            XCTAssertTrue(Set(headers.map(\.recordingID)).isSubset(of: rows))
            XCTAssertEqual(recoveryFiles, [])
        }
    }
}
