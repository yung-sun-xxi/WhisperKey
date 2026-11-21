import XCTest
@testable import SharedJSONFile

final class SharedJSONFileTests: XCTestCase {

    private struct Item: Codable, Equatable {
        let tag: String
        let n: Int
    }

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WhisperKey-SharedJSONFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    private func makeURL() -> URL {
        tempDir.appendingPathComponent("items.json")
    }

    private func makeFile(_ url: URL) -> SharedJSONFile<Item> {
        SharedJSONFile(url: url, encoder: JSONEncoder(), decoder: JSONDecoder())
    }

    private func onDisk(_ url: URL) throws -> [Item] {
        try JSONDecoder().decode([Item].self, from: Data(contentsOf: url))
    }

    private func inode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int)
    }

    // MARK: - Read, modify, write

    /// Regression proof of #140 at the helper level: an update applies to the file as it
    /// is now, not to what this instance read earlier.
    func testAnUpdateAppliesToTheFreshFileNotToThisInstancesCopy() throws {
        let url = makeURL()
        let first = makeFile(url)
        let second = makeFile(url)
        try first.load()
        try second.load()

        try first.update { $0.append(Item(tag: "first", n: 1)) }
        try second.update { $0.append(Item(tag: "second", n: 1)) }

        XCTAssertEqual(try onDisk(url).map(\.tag), ["first", "second"])
        XCTAssertEqual(second.contents.map(\.tag), ["first", "second"])
    }

    /// Two instances hammering one file from two threads at once. Without the lock, a
    /// read-modify-write from one lands between the other's read and write and erases it.
    func testConcurrentUpdatesFromTwoInstancesLoseNothing() throws {
        let url = makeURL()
        let perWriter = 300
        let files = [makeFile(url), makeFile(url)]
        let failures = NSCountedSet()

        DispatchQueue.concurrentPerform(iterations: 2) { writer in
            for n in 0..<perWriter {
                do {
                    try files[writer].update { $0.append(Item(tag: "w\(writer)", n: n)) }
                } catch {
                    failures.add("\(error)")
                }
            }
        }

        XCTAssertEqual(failures.count, 0, "\(failures)")
        let items = try onDisk(url)
        XCTAssertEqual(items.count, 2 * perWriter)
        XCTAssertEqual(items.filter { $0.tag == "w0" }.map(\.n), Array(0..<perWriter))
        XCTAssertEqual(items.filter { $0.tag == "w1" }.map(\.n), Array(0..<perWriter))
    }

    func testAnUnchangedResultIsNotWritten() throws {
        let url = makeURL()
        let file = makeFile(url)
        try file.update { $0.append(Item(tag: "a", n: 1)) }
        let before = try inode(url)

        let answer = try file.update { contents -> Int in contents.count }

        XCTAssertEqual(answer, 1)
        XCTAssertEqual(try inode(url), before, "a no-op update must not replace the file")
    }

    func testAThrowingTransformWritesNothing() throws {
        struct Refused: Error {}
        let url = makeURL()
        let file = makeFile(url)
        try file.update { $0.append(Item(tag: "kept", n: 1)) }

        XCTAssertThrowsError(try file.update { contents in
            contents.removeAll()
            throw Refused()
        })

        XCTAssertEqual(try onDisk(url).map(\.tag), ["kept"])
    }

    func testNoTemporaryFilesAreLeftBehind() throws {
        let url = makeURL()
        let file = makeFile(url)
        for n in 0..<3 { try file.update { $0.append(Item(tag: "a", n: n)) } }

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tempDir.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
    }

    // MARK: - Corrupt file

    /// A file that does not decode is renamed aside, never overwritten, and the operation
    /// carries on from empty.
    func testAnUpdateOverACorruptFileKeepsItAsideAndStartsFromEmpty() throws {
        let url = makeURL()
        let garbage = Data("[{\"tag\": \"half".utf8)
        try garbage.write(to: url)

        try makeFile(url).update { $0.append(Item(tag: "new", n: 1)) }

        let names = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        let kept = names.filter { $0.hasPrefix("items.json.corrupt-") }
        XCTAssertEqual(kept.count, 1, "\(names)")
        let keptName = try XCTUnwrap(kept.first)
        XCTAssertEqual(try Data(contentsOf: tempDir.appendingPathComponent(keptName)), garbage)
        // <name>.corrupt-<ISO 8601 basic timestamp>, e.g. items.json.corrupt-20261009T133502Z
        XCTAssertNotNil(keptName.range(of: #"^items\.json\.corrupt-\d{8}T\d{6}Z$"#, options: .regularExpression), keptName)
        XCTAssertEqual(try onDisk(url), [Item(tag: "new", n: 1)])
    }

    func testLoadingACorruptFileKeepsItAsideToo() throws {
        let url = makeURL()
        try Data("nonsense".utf8).write(to: url)

        XCTAssertEqual(try makeFile(url).load(), [])

        let names = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(names.filter { $0.hasPrefix("items.json.corrupt-") }.count, 1, "\(names)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testTwoCorruptFilesInOneSecondDoNotOverwriteEachOther() throws {
        let url = makeURL()
        try Data("first".utf8).write(to: url)
        try makeFile(url).load()
        try Data("second".utf8).write(to: url)
        try makeFile(url).load()

        let names = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        let kept = names.filter { $0.hasPrefix("items.json.corrupt-") }
        let contents = try Set(kept.map { String(decoding: try Data(contentsOf: tempDir.appendingPathComponent($0)), as: UTF8.self) })
        XCTAssertEqual(contents, ["first", "second"])
    }

    func testAnEmptyFileReadsAsEmptyAndIsNotKeptAside() throws {
        let url = makeURL()
        try Data().write(to: url)

        XCTAssertEqual(try makeFile(url).load(), [])
        let names = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertTrue(names.filter { $0.contains(".corrupt-") }.isEmpty, "\(names)")
    }

    // MARK: - Reload

    func testReloadIfChangedIgnoresOwnWritesAndReturnsAnotherInstancesWrites() throws {
        let url = makeURL()
        let mine = makeFile(url)
        let theirs = makeFile(url)
        try mine.load()

        try mine.update { $0.append(Item(tag: "mine", n: 1)) }
        XCTAssertNil(try mine.reloadIfChanged(), "its own write is not news")

        try theirs.update { $0.append(Item(tag: "theirs", n: 1)) }
        XCTAssertEqual(try mine.reloadIfChanged()?.map(\.tag), ["mine", "theirs"])
        XCTAssertNil(try mine.reloadIfChanged(), "nothing changed since the last reload")
    }

    /// A rewrite with identical contents changes the file but not what anyone shows, and
    /// must not make the caller republish.
    func testReloadIfChangedReturnsNilWhenTheContentsAreTheSame() throws {
        let url = makeURL()
        let mine = makeFile(url)
        try mine.update { $0.append(Item(tag: "a", n: 1)) }

        let data = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try data.write(to: url)

        XCTAssertNil(try mine.reloadIfChanged())
    }

    // MARK: - Directory watcher

    /// The watch is on the directory because an atomic replace gives the file a new
    /// inode: a watch on the file would hear the first write and nothing after it.
    func testTheWatcherHearsEveryAtomicReplaceNotOnlyTheFirst() throws {
        let url = makeURL()
        let writer = makeFile(url)
        var calls = 0
        let watcher = DirectoryWatcher(directory: tempDir) { calls += 1 }
        XCTAssertNotNil(watcher)

        try writer.update { $0.append(Item(tag: "a", n: 1)) }
        XCTAssertTrue(waitUntil { calls > 0 }, "first write not heard")

        let heard = calls
        try writer.update { $0.append(Item(tag: "a", n: 2)) }
        XCTAssertTrue(waitUntil { calls > heard }, "second write not heard")
        withExtendedLifetime(watcher) {}
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }
}
