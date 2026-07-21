import Foundation
import Security

protocol OpenRouterCredentialStoring {
    func read() throws -> String?
    func save(_ value: String) throws
    func delete() throws
}

enum OpenRouterCredentialStoreError: LocalizedError {
    case blankCredential
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .blankCredential:
            return "Enter an OpenRouter API key."
        case let .keychain(status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "Could not update the OpenRouter API key in Keychain: \(detail)"
        }
    }
}

final class KeychainOpenRouterCredentialStore: OpenRouterCredentialStoring {
    private let service: String
    private let account: String

    init(
        service: String = "dev.relay.menubar.openrouter",
        account: String = "OPENROUTER_API_KEY"
    ) {
        self.service = service
        self.account = account
    }

    func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw OpenRouterCredentialStoreError.keychain(status)
        }
        return value
    }

    func save(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenRouterCredentialStoreError.blankCredential
        }

        try delete()
        var item = baseQuery
        item[kSecValueData as String] = Data(trimmed.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw OpenRouterCredentialStoreError.keychain(status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OpenRouterCredentialStoreError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

extension Notification.Name {
    static let relaySettingsDidChange = Notification.Name("dev.relay.menubar.settingsDidChange")
}
