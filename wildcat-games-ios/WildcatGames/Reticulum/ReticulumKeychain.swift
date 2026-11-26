import Foundation
import Security

/// This phone's Reticulum identity (its LXMF address comes from it): the 64-byte private key
/// (X25519 + Ed25519) that RNS generates, kept in the Keychain rather than in a file. Readable after
/// the first unlock (so a Bluetooth wake in the background can start Reticulum), this device only
/// (not in backups, not moved to a new phone).
///
/// RNS keeps other keys in the app's container: its transport identity and the LXMF ratchet keys
/// (forward secrecy), in Library/Application Support/Reticulum.
enum ReticulumKeychain {
    static let service = "com.thebench.wildcatgames.reticulum"
    static let identityAccount = "lxmf-identity"

    static func loadIdentity(service: String = service, account: String = identityAccount) -> Data? {
        var query = base(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data, data.count == 64 else { return nil }
        return data
    }

    @discardableResult
    static func saveIdentity(_ key: Data, service: String = service, account: String = identityAccount) -> Bool {
        guard key.count == 64 else { return false }
        let query = base(service: service, account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        return SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func deleteIdentity(service: String = service, account: String = identityAccount) -> Bool {
        let status = SecItemDelete(base(service: service, account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func base(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

extension Data {
    /// Lowercase hex.
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    /// From hex (even length, 0-9 a-f A-F only); nil otherwise.
    init?(hexString s: String) {
        let chars = Array(s.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 97...102: return c - 87
            case 65...70: return c - 55
            default: return nil
            }
        }
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        self = out
    }
}
