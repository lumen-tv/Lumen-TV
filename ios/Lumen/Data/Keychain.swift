import Foundation
import Security

/// Logins and playlist links live in the iOS Keychain (encrypted), not in the app's files. One
/// item per playlist, keyed by its id. They sync through iCloud Keychain (end-to-end encrypted,
/// only the user's own devices can read them), so a playlist added on the iPhone also works on
/// the iPad. Items saved before sync are found too (`SynchronizableAny`) and moved up on save.
enum Keychain {
    private static let service = "com.hayat.lumen.playlist"

    /// Mac: the same iCloud-synced keychain as iPhone/iPad (the "data protection" keychain,
    /// shared through the keychain group in Mac/Lumen.entitlements) when the build has iCloud.
    /// Without it, the Mac's login keychain, which can't sync.
    #if os(macOS) && !LUMEN_ICLOUD
    private static let syncs = false
    #else
    private static let syncs = true
    #endif

    private static func platform(_ query: [String: Any]) -> [String: Any] {
        var query = query
        #if os(macOS)
        if syncs { query[kSecUseDataProtectionKeychain as String] = true }
        #endif
        if !syncs { query.removeValue(forKey: kSecAttrSynchronizable as String) }
        return query
    }

    static func save(_ data: Data, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var any = query
        any[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        SecItemDelete(platform(any) as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrSynchronizable as String] = kCFBooleanTrue
        // Readable after the first unlock since the device started. (Not "ThisDeviceOnly":
        // those can't sync.)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(platform(item) as CFDictionary, nil)
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
        guard SecItemCopyMatching(platform(query) as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(platform(query) as CFDictionary)
    }
}
