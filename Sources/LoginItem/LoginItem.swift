import Foundation

/// Abstraction over `SMAppService.mainApp` to keep the toggle UI testable
/// without invoking the real ServiceManagement framework, which is gated by
/// code signing and refuses to register from a Swift PM unit-test bundle.
public protocol LoginItemService: Sendable {
    var isEnabled: Bool { get }
    func register() throws
    func unregister() throws
}

public enum LoginItemError: Error, Equatable {
    case registerFailed(message: String)
    case unregisterFailed(message: String)
}

public final class LoginItemController: @unchecked Sendable {
    private let service: LoginItemService
    private let lock = NSLock()
    private var cachedEnabled: Bool

    public init(service: LoginItemService) {
        self.service = service
        self.cachedEnabled = service.isEnabled
    }

    public var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        cachedEnabled = service.isEnabled
        return cachedEnabled
    }

    public func setEnabled(_ enabled: Bool) -> Result<Bool, LoginItemError> {
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lock.lock(); cachedEnabled = service.isEnabled; lock.unlock()
            return .failure(enabled ? .registerFailed(message: message) : .unregisterFailed(message: message))
        }
        lock.lock(); cachedEnabled = service.isEnabled; lock.unlock()
        return .success(cachedEnabled)
    }
}
