import Foundation
import LoginItem
import ServiceManagement
import os

final class SMAppServiceLoginItem: LoginItemService {
    private static let log = Logger(subsystem: "WhisperKey", category: "LoginItem")

    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func register() throws {
        do {
            try SMAppService.mainApp.register()
            Self.log.info("login item registered")
        } catch {
            Self.log.error("login item register failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    func unregister() throws {
        do {
            try SMAppService.mainApp.unregister()
            Self.log.info("login item unregistered")
        } catch {
            Self.log.error("login item unregister failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }
}
