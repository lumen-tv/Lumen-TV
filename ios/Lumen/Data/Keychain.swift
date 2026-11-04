import Foundation
import Security

/// Logins and playlist links live in the iOS Keychain (encrypted), not in the app's files. One
/// item per playlist, keyed by its id. They sync through iCloud Keychain (end-to-end encrypted,
/// only the user's own devices can read them), so a playlist added on the iPhone also works on
/// the iPad. Items saved before sync are found too (`SynchronizableAny`) and moved up on save.
enum Keychain {
    private static let service = "com.hayat.lumen.playlist"

    static func save(_ data: Data, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var any = query
        any[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        SecItemDelete(any as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrSynchronizable as String] = kCFBooleanTrue
        // Readable after the first unlock since the device started. (Not "ThisDeviceOnly":
        // those can't sync.)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    static func load(_ account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
