import Foundation
import Security

public enum KeychainError: Error, Equatable, Sendable {
    case unexpectedStatus(OSStatus)
    case dataEncodingFailed
}

public protocol KeychainStorage: Sendable {
    func read(service: String, account: String) throws -> String?
    func write(_ value: String, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

public struct KeychainStore: KeychainStorage {
    public init() {}

    public func read(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecItemNotFound:
            return nil
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                throw KeychainError.dataEncodingFailed
            }
            return value
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func write(_ value: String, service: String, account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.dataEncodingFailed
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateAttrs: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    public func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

public final class InMemoryKeychain: KeychainStorage, @unchecked Sendable {
    private struct Key: Hashable { let service: String; let account: String }
    private var storage: [Key: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func read(service: String, account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[Key(service: service, account: account)]
    }

    public func write(_ value: String, service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[Key(service: service, account: account)] = value
    }

    public func delete(service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: Key(service: service, account: account))
    }
}
