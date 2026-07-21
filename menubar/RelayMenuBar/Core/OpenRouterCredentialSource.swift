import Foundation

enum OpenRouterCredentialSource: Equatable {
    case keychain
    case environment
    case missing

    static func resolve(
        keychainValue: String?,
        environment: [String: String]
    ) -> Self {
        if normalized(keychainValue) != nil {
            return .keychain
        }
        if environmentValue(in: environment) != nil {
            return .environment
        }
        return .missing
    }

    static func environmentValue(in environment: [String: String]) -> String? {
        normalized(environment["OPENROUTER_API_KEY"])
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
