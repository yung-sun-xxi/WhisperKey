import XCTest
@testable import LoginItem

final class LoginItemTests: XCTestCase {

    final class FakeService: LoginItemService, @unchecked Sendable {
        var enabled = false
        var failOnRegister: Error?
        var failOnUnregister: Error?
        var registerCallCount = 0
        var unregisterCallCount = 0

        var isEnabled: Bool { enabled }

        func register() throws {
            registerCallCount += 1
            if let error = failOnRegister { throw error }
            enabled = true
        }

        func unregister() throws {
            unregisterCallCount += 1
            if let error = failOnUnregister { throw error }
            enabled = false
        }
    }

    struct StubError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func testEnableSucceeds() {
        let service = FakeService()
        let controller = LoginItemController(service: service)
        let result = controller.setEnabled(true)
        XCTAssertEqual(try? result.get(), true)
        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertTrue(controller.isEnabled)
    }

    func testDisableSucceeds() {
        let service = FakeService()
        service.enabled = true
        let controller = LoginItemController(service: service)
        let result = controller.setEnabled(false)
        XCTAssertEqual(try? result.get(), false)
        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertFalse(controller.isEnabled)
    }

    func testRegisterFailureSurfacesErrorAndRevertsCachedState() {
        let service = FakeService()
        service.failOnRegister = StubError(message: "Operation not permitted")
        let controller = LoginItemController(service: service)

        let result = controller.setEnabled(true)
        switch result {
        case .success:
            XCTFail("expected failure")
        case .failure(let error):
            XCTAssertEqual(error, .registerFailed(message: "Operation not permitted"))
        }
        XCTAssertFalse(controller.isEnabled, "reverts to underlying service state on failure")
    }

    func testUnregisterFailureSurfacesError() {
        let service = FakeService()
        service.enabled = true
        service.failOnUnregister = StubError(message: "service not found")
        let controller = LoginItemController(service: service)

        let result = controller.setEnabled(false)
        switch result {
        case .success:
            XCTFail("expected failure")
        case .failure(let error):
            XCTAssertEqual(error, .unregisterFailed(message: "service not found"))
        }
        XCTAssertTrue(controller.isEnabled, "stays enabled when unregister fails")
    }
}
