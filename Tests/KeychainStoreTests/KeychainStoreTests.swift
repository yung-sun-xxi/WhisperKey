import XCTest
@testable import KeychainStore

// The real `KeychainStore` is intentionally not unit-tested here: an
// unsigned `swift test` binary cannot access the user's keychain and
// SecItemAdd returns errSecMissingEntitlement (-25308) under CI. The
// PRD lists `KeychainStore` as out-of-scope for unit tests; integration
// happens via manual smoke through the Settings popover.

final class InMemoryKeychainTests: XCTestCase {
    func testReadReturnsNilWhenAbsent() throws {
        let keychain = InMemoryKeychain()
        XCTAssertNil(try keychain.read(service: "s", account: "a"))
    }

    func testWriteThenReadRoundTrip() throws {
        let keychain = InMemoryKeychain()
        try keychain.write("sk-abc", service: "s", account: "a")
        XCTAssertEqual(try keychain.read(service: "s", account: "a"), "sk-abc")
    }

    func testWriteOverwritesExisting() throws {
        let keychain = InMemoryKeychain()
        try keychain.write("first", service: "s", account: "a")
        try keychain.write("second", service: "s", account: "a")
        XCTAssertEqual(try keychain.read(service: "s", account: "a"), "second")
    }

    func testDeleteRemovesEntry() throws {
        let keychain = InMemoryKeychain()
        try keychain.write("sk-abc", service: "s", account: "a")
        try keychain.delete(service: "s", account: "a")
        XCTAssertNil(try keychain.read(service: "s", account: "a"))
    }

    func testDeleteMissingIsNoOp() throws {
        let keychain = InMemoryKeychain()
        XCTAssertNoThrow(try keychain.delete(service: "s", account: "a"))
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
