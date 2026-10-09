import Foundation
import Security

/// Gemini API key storage: a Keychain generic password, never Config or
/// UserDefaults. `GEMINI_API_KEY` in the environment is the fallback when the
/// Keychain item is missing or blank (tests, `open --env`). The value is never
/// logged.
public enum GeminiAPIKeyStore {
    public static let service = Constants.isDevBuild ? "io.binarygap.whisper-native.dev.gemini" : "io.binarygap.whisper-native.gemini"
    public static let account = "api-key"
    public static let environmentVariable = "GEMINI_API_KEY"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Keychain value, nil when absent or unreadable.
    public static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                AppLogger.shared.log(.warning, "Gemini API key Keychain read failed: OSStatus \(status)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Stores the key (trimmed); a blank key deletes the item.
    public static func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let status = SecItemDelete(baseQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                AppLogger.shared.log(.error, "Gemini API key Keychain delete failed: OSStatus \(status)")
                throw AppError.keychainFailed(status)
            }
            return
        }
        let data = Data(trimmed.utf8)
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            AppLogger.shared.log(.error, "Gemini API key Keychain update failed: OSStatus \(updateStatus)")
            throw AppError.keychainFailed(updateStatus)
        }
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            AppLogger.shared.log(.error, "Gemini API key Keychain add failed: OSStatus \(addStatus)")
            throw AppError.keychainFailed(addStatus)
        }
    }

    /// Non-blank `GEMINI_API_KEY` from the environment, if any.
    public static var environmentKey: String? {
        nonBlank(ProcessInfo.processInfo.environment[environmentVariable])
    }

    /// Key the backend uses: Keychain first, then the environment fallback.
    public static var resolvedKey: String? {
        nonBlank(load()) ?? environmentKey
    }

    public static var hasKey: Bool { resolvedKey != nil }

    private static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
