import XCTest
@testable import KeychainStore

final class KeychainStoreTests: XCTestCase {
    private var store: KeychainStore!
    private var service: String!

    override func setUp() {
        super.setUp()
        store = KeychainStore()
        service = "WhisperKey.tests.\(UUID().uuidString)"
    }

    override func tearDown() {
        try? store.delete(service: service, account: "primary")
        try? store.delete(service: service, account: "secondary")
        super.tearDown()
    }

    func testReadReturnsNilWhenAbsent() throws {
        XCTAssertNil(try store.read(service: service, account: "primary"))
    }

    func testWriteThenReadRoundTrip() throws {
        try store.write("sk-abc", service: service, account: "primary")
        XCTAssertEqual(try store.read(service: service, account: "primary"), "sk-abc")
    }

    func testWriteOverwritesExisting() throws {
        try store.write("first", service: service, account: "primary")
        try store.write("second", service: service, account: "primary")
        XCTAssertEqual(try store.read(service: service, account: "primary"), "second")
    }

    func testDeleteRemovesEntry() throws {
        try store.write("sk-abc", service: service, account: "primary")
        try store.delete(service: service, account: "primary")
        XCTAssertNil(try store.read(service: service, account: "primary"))
    }

    func testDeleteMissingIsNoOp() throws {
        XCTAssertNoThrow(try store.delete(service: service, account: "primary"))
    }

    func testWriteIsScopedByAccount() throws {
        try store.write("alpha", service: service, account: "primary")
        try store.write("beta", service: service, account: "secondary")
        XCTAssertEqual(try store.read(service: service, account: "primary"), "alpha")
        XCTAssertEqual(try store.read(service: service, account: "secondary"), "beta")
    }
}

final class InMemoryKeychainTests: XCTestCase {
    func testRoundTrip() throws {
        let keychain = InMemoryKeychain()
        try keychain.write("v", service: "s", account: "a")
        XCTAssertEqual(try keychain.read(service: "s", account: "a"), "v")
        try keychain.delete(service: "s", account: "a")
        XCTAssertNil(try keychain.read(service: "s", account: "a"))
    }

    func testIsolationByServiceAndAccount() throws {
        let keychain = InMemoryKeychain()
        try keychain.write("a", service: "s1", account: "u")
        try keychain.write("b", service: "s2", account: "u")
        try keychain.write("c", service: "s1", account: "v")
        XCTAssertEqual(try keychain.read(service: "s1", account: "u"), "a")
        XCTAssertEqual(try keychain.read(service: "s2", account: "u"), "b")
        XCTAssertEqual(try keychain.read(service: "s1", account: "v"), "c")
    }
}
