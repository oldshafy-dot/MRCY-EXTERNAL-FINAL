import Foundation
import Security
import UIKit

enum DeviceHWID {
    private static let udKey = "vita.device.hwid"
    private static let kcService = "vita.device.hwid"
    private static let kcAccount = "device_hwid"

    static var value: String {
        if let stored = readKeychain(), !stored.isEmpty {
            persist(stored)
            return stored
        }
        if let stored = UserDefaults.standard.string(forKey: udKey), !stored.isEmpty {
            persist(stored)
            return stored
        }
        let generated = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        persist(generated)
        return generated
    }

    private static func persist(_ value: String) {
        UserDefaults.standard.set(value, forKey: udKey)
        writeKeychain(value)
    }

    private static func writeKeychain(_ value: String) {
        let payload = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kcService,
            kSecAttrAccount as String: kcAccount,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = payload
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func readKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kcService,
            kSecAttrAccount as String: kcAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
