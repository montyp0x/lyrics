import Foundation
import Security

enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "com.ramych.lyrics"

    static func data(for account: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func set(_ data: Data?, for account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard let data else { return }
        var item = query
        item[kSecValueData] = data
        // Token refreshes happen while the phone is locked, so the item must stay readable after first unlock.
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}
