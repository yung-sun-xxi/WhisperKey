import AudioRecorder
import XCTest
@testable import RecordingRecovery

/// The file of a recording that is still running.
final class RecoveryFileTests: RecoveryTestCase {
    private func mode(_ url: URL) -> Int {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return -1 }
        return Int(info.st_mode & 0o777)
    }

    func testEveryChunkIsReadableInOrderWhileTheRecordingRuns() throws {
        let header = makeHeader()
        let file = folder.makeFile(header)
        var expected = Data()
        for index in 0..<50 {
            let chunk = pcm(0.1, seed: index * 17)
            expected.append(chunk)
            file.append(chunk)
        }
        file.drain()
        let read = try XCTUnwrap(RecoveryFileFormat.decode(Data(contentsOf: folder.url(for: header.recordingID))))
        XCTAssertEqual(read.header, header)
        XCTAssertEqual(read.audio.samples, expected)
    }

    func testTheFolderAndTheFileAreTheOwnersOnly() throws {
        let header = makeHeader()
        let file = folder.makeFile(header)
        file.drain()
        XCTAssertEqual(mode(folder.directory), 0o700)
        XCTAssertEqual(mode(folder.url(for: header.recordingID)), 0o600)
    }

    func testAnExistingFolderIsMadeTheOwnersOnly() throws {
        try FileManager.default.createDirectory(at: folder.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        folder.makeFile(makeHeader()).drain()
        XCTAssertEqual(mode(folder.directory), 0o700)
    }

    func testTheFileIsNotInTheFolderTheOrphanSweepCleans() {
        let standard = RecoveryFolder.defaultDirectory()
        XCTAssertEqual(standard.lastPathComponent, "RecordingRecovery")
        XCTAssertEqual(standard.deletingLastPathComponent().lastPathComponent, "WhisperKey")
        let file = folder.makeFile(makeHeader())
        file.drain()
        let history = makeHistory()
        XCTAssertNotEqual(history.audioDirectoryURL, folder.directory)
        XCTAssertEqual(recoveryFiles.count, 1, "opening the history sweeps its audio folder only")
    }

    func testTheFileIsLockedWhileItRecordsAndUnlockedOnceKept() {
        let header = makeHeader()
        let url = folder.url(for: header.recordingID)
        let file = folder.makeFile(header)
        file.drain()
        XCTAssertTrue(isLocked(url))
        file.append(pcm(0.5))
        file.keep()
        XCTAssertTrue(waitUntil { !isLocked(url) })
        XCTAssertEqual(try? Data(contentsOf: url).count, RecoveryFileFormat.encode(header).count + 16_000, "keep writes what was queued first")
    }

    /// A raw `posix_spawn` closes nothing by itself, so only O_CLOEXEC keeps the lock here.
    func testAChildProcessDoesNotInheritTheLock() throws {
        let header = makeHeader()
        let file = folder.makeFile(header)
        file.drain()
        XCTAssertTrue(isLocked(folder.url(for: header.recordingID)))

        var child: pid_t = 0
        var arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("30"), nil]
        XCTAssertEqual(posix_spawn(&child, "/bin/sleep", nil, nil, &arguments, environ), 0)
        defer { kill(child, SIGKILL); var status: Int32 = 0; waitpid(child, &status, 0); arguments.forEach { free($0) } }

        file.keep()
        file.drain()
        XCTAssertEqual(kill(child, 0), 0, "the child is alive")
        XCTAssertFalse(isLocked(folder.url(for: header.recordingID)), "the child does not hold the recording's lock")
    }

    func testDiscardRemovesTheFileBeforeItReturns() {
        let header = makeHeader()
        let url = folder.url(for: header.recordingID)
        let file = folder.makeFile(header)
        file.append(pcm(1))
        file.drain()
        XCTAssertTrue(exists(url))
        file.discard()
        XCTAssertFalse(exists(url), "an exit right after must not depend on a queued deletion")
        file.append(pcm(1))
        file.drain()
        XCTAssertFalse(exists(url), "nothing brings it back")
    }

    func testDiscardBeforeTheFileWasOpenedLeavesNone() {
        for _ in 0..<200 {
            let file = folder.makeFile(makeHeader())
            file.discard()
            file.drain()
        }
        XCTAssertEqual(recoveryFiles, [])
        let control = folder.makeFile(makeHeader())
        control.drain()
        XCTAssertEqual(recoveryFiles.count, 1, "the control")
    }

    // MARK: - A disk that fails

    func testAFolderThatCannotBeCreatedNeverReachesTheCaller() throws {
        try Data("not a folder".utf8).write(to: folder.directory)
        let file = folder.makeFile(makeHeader())
        for _ in 0..<20 { file.append(pcm(0.1)) }
        file.drain()
        file.keep()
        file.discard()
        XCTAssertEqual(try Data(contentsOf: folder.directory), Data("not a folder".utf8))
    }

    func testAFullDiskKeepsWhatWasWrittenAndStopsWriting() throws {
        let written = Box(0)
        let attempts = Box(0)
        let room = RecoveryFileFormat.encode(makeHeader()).count + 20_001
        let io = RecoveryFileIO(
            write: { descriptor, bytes in
                attempts.update { $0 += 1 }
                let left = room - written.value
                guard left > 0 else { errno = ENOSPC; return -1 }
                let count = Darwin.write(descriptor, bytes.baseAddress, min(left, bytes.count))
                written.update { $0 += max(count, 0) }
                return count
            },
            syncToDevice: { fsync($0) == 0 }
        )
        let header = makeHeader()
        try FileManager.default.createDirectory(at: folder.directory, withIntermediateDirectories: true)
        let file = RecoveryFile(url: folder.url(for: header.recordingID), header: header, io: io)
        let audio = pcm(5)
        for start in stride(from: 0, to: audio.count, by: 3_200) {
            file.append(audio.subdata(in: start..<start + 3_200))
        }
        file.drain()
        let attemptsWhenFull = attempts.value
        file.append(pcm(1))
        file.drain()
        XCTAssertEqual(attempts.value, attemptsWhenFull, "it gives up after the first failure")
        XCTAssertTrue(isLocked(folder.url(for: header.recordingID)), "a full disk does not release a live recording's file")

        let read = try XCTUnwrap(RecoveryFileFormat.decode(Data(contentsOf: folder.url(for: header.recordingID))))
        XCTAssertEqual(read.audio.samples, audio.prefix(20_000), "what fitted is kept, the torn sample is not")
    }

    func testAnInterruptedOrPartialWriteIsFinished() throws {
        let calls = Box(0)
        let io = RecoveryFileIO(
            write: { descriptor, bytes in
                calls.update { $0 += 1 }
                if calls.value % 3 == 0 { errno = EINTR; return -1 }
                return Darwin.write(descriptor, bytes.baseAddress, min(bytes.count, 1_000))
            },
            syncToDevice: { _ in true }
        )
        let header = makeHeader()
        try FileManager.default.createDirectory(at: folder.directory, withIntermediateDirectories: true)
        let file = RecoveryFile(url: folder.url(for: header.recordingID), header: header, io: io)
        let audio = pcm(1)
        file.append(audio)
        file.drain()
        let read = try XCTUnwrap(RecoveryFileFormat.decode(Data(contentsOf: folder.url(for: header.recordingID))))
        XCTAssertEqual(read.audio.samples, audio)
    }

    /// The capture queue calls `append`; a disk that hangs must cost it nothing.
    func testAppendReturnsAtOnceWhileTheDiskHangs() throws {
        let hang = DispatchSemaphore(value: 0)
        let reached = DispatchSemaphore(value: 0)
        let io = RecoveryFileIO(
            write: { _, bytes in reached.signal(); hang.wait(); hang.signal(); return bytes.count },
            syncToDevice: { _ in true }
        )
        let header = makeHeader()
        try FileManager.default.createDirectory(at: folder.directory, withIntermediateDirectories: true)
        let file = RecoveryFile(url: folder.url(for: header.recordingID), header: header, io: io)
        XCTAssertEqual(reached.wait(timeout: .now() + 5), .success, "the disk is hanging")
        let start = Date()
        for _ in 0..<600 { file.append(pcm(0.02)) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        file.discard()
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "nor does a discard wait for the hung write")
        hang.signal()
        file.drain()
        XCTAssertEqual(recoveryFiles, [])
    }

    func testTheFileIsSyncedToTheDeviceOncePerInterval() throws {
        func syncs(interval: TimeInterval, chunks: Int, pause: TimeInterval) throws -> Int {
            let syncs = Box(0)
            let io = RecoveryFileIO(
                write: { Darwin.write($0, $1.baseAddress, $1.count) },
                syncToDevice: { _ in syncs.update { $0 += 1 }; return true }
            )
            let header = makeHeader()
            try FileManager.default.createDirectory(at: folder.directory, withIntermediateDirectories: true)
            let file = RecoveryFile(url: folder.url(for: header.recordingID), header: header, io: io, syncInterval: interval)
            for _ in 0..<chunks {
                file.append(pcm(0.01))
                file.drain()
                Thread.sleep(forTimeInterval: pause)
            }
            return syncs.value
        }
        XCTAssertEqual(try syncs(interval: 3_600, chunks: 50, pause: 0), 0, "not once per chunk")
        XCTAssertGreaterThanOrEqual(try syncs(interval: 0.1, chunks: 5, pause: 0.15), 4, "every chunk that comes an interval later")
    }

    func testAFailedSyncKeepsTheFile() throws {
        let io = RecoveryFileIO(
            write: { Darwin.write($0, $1.baseAddress, $1.count) },
            syncToDevice: { _ in errno = EIO; return false }
        )
        let header = makeHeader()
        try FileManager.default.createDirectory(at: folder.directory, withIntermediateDirectories: true)
        let file = RecoveryFile(url: folder.url(for: header.recordingID), header: header, io: io, syncInterval: 0)
        file.append(pcm(1))
        file.append(pcm(1))
        file.drain()
        let read = try XCTUnwrap(RecoveryFileFormat.decode(Data(contentsOf: folder.url(for: header.recordingID))))
        XCTAssertEqual(read.audio.samples, pcm(1), "written, then the sync failed, then nothing more")
    }
}
