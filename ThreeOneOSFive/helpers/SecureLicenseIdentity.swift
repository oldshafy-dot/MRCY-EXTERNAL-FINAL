import Foundation
import Security

enum VaultBox {
    private static func label(_ masked: [UInt8]) -> String {
        String(decoding: masked.map { $0 ^ 0x5A }, as: UTF8.self)
    }

    private static let currentService = label([
        0x2C, 0x37, 0x74, 0x39, 0x35, 0x28, 0x3F, 0x74, 0x38, 0x35, 0x22, 0x74, 0x69,
    ])
    private static let legacyService = label([
        0x39, 0x35, 0x37, 0x74, 0x2C, 0x33, 0x2E, 0x3B, 0x37, 0x35, 0x3E, 0x29, 0x74,
        0x36, 0x33, 0x39, 0x3F, 0x34, 0x29, 0x33, 0x34, 0x3D, 0x74, 0x2C, 0x68,
    ])

    static func read(account: String) throws -> Data? {
        if let data = try read(account: account, service: currentService) {
            return data
        }
        guard let legacy = try read(account: account, service: legacyService) else {
            return nil
        }
        try? write(legacy, account: account)
        return legacy
    }

    static func write(_ data: Data, account: String) throws {
        try write(data, account: account, service: currentService)
    }

    static func delete(account: String) {
        delete(account: account, service: currentService)
        delete(account: account, service: legacyService)
    }

    private static func read(account: String, service: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw LicenseClientError.keychain
        }
        return data
    }

    private static func write(_ data: Data, account: String, service: String) throws {
        let lookup: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(
            lookup as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var addition = lookup
            addition[kSecValueData] = data
            addition[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(addition as CFDictionary, nil) == errSecSuccess else {
                throw LicenseClientError.keychain
            }
        } else if updateStatus != errSecSuccess {
            throw LicenseClientError.keychain
        }
    }

    private static func delete(account: String, service: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

final class DeviceStamp {
    private static let identityLock = NSRecursiveLock()
    private static func label(_ masked: [UInt8]) -> String {
        String(decoding: masked.map { $0 ^ 0x5A }, as: UTF8.self)
    }

    private let installationAccount = label([0x39, 0x33, 0x3E, 0x74, 0x2C, 0x69])
    private let legacyInstallationAccount = label([
        0x33, 0x34, 0x29, 0x2E, 0x3B, 0x36, 0x36, 0x3B, 0x2E, 0x33, 0x35, 0x34, 0x77, 0x33, 0x3E,
    ])
    private let currentKeyTag = Data(label([0x2C, 0x37, 0x74, 0x39, 0x35, 0x28, 0x3F, 0x74, 0x3F, 0x31, 0x74, 0x69]).utf8)
    private let legacyKeyTag = Data(label([
        0x39, 0x35, 0x37, 0x74, 0x2C, 0x33, 0x2E, 0x3B, 0x37, 0x35, 0x3E, 0x29, 0x74,
        0x36, 0x33, 0x39, 0x3F, 0x34, 0x29, 0x33, 0x34, 0x3D, 0x74, 0x2C, 0x68, 0x74,
        0x3E, 0x3F, 0x2C, 0x33, 0x39, 0x3F, 0x77, 0x31, 0x3F, 0x23, 0x74, 0x2C, 0x6B,
    ]).utf8)

    func installationID() throws -> String {
        Self.identityLock.lock()
        defer { Self.identityLock.unlock() }
        return try Self.resolveInstallationID(
            current: { try VaultBox.read(account: self.installationAccount) },
            legacy: { try VaultBox.read(account: self.legacyInstallationAccount) },
            hasRegistration: { try self.hasSavedRegistration() },
            save: { try VaultBox.write($0, account: self.installationAccount) }
        )
    }

    // Migration must preserve the exact registered UUID, including its casing.
    // A damaged or inaccessible record must never become a new installation.
    static func resolveInstallationID(
        current: () throws -> Data?,
        legacy: () throws -> Data?,
        hasRegistration: () throws -> Bool,
        save: (Data) throws -> Void
    ) throws -> String {
        func decode(_ data: Data) throws -> String {
            guard let value = String(data: data, encoding: .utf8),
                  UUID(uuidString: value) != nil else {
                throw LicenseClientError.identityUnavailable
            }
            return value
        }
        if let data = try current() { return try decode(data) }
        if let data = try legacy() {
            let value = try decode(data)
            // A failed copy does not destroy the still-usable legacy identity.
            try? save(data)
            return value
        }
        guard try !hasRegistration() else { throw LicenseClientError.identityUnavailable }
        let value = UUID().uuidString.lowercased()
        try save(Data(value.utf8))
        return value
    }

    private func hasSavedRegistration() throws -> Bool {
        for account in ["tok.v3", "enr.v3", "session-credentials", "pending-activation"] {
            if try VaultBox.read(account: account) != nil { return true }
        }
        return false
    }

    func publicKeyBase64() throws -> String {
        let privateKey = try loadOrCreatePrivateKey()
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let representation = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
              representation.count == 65,
              representation.first == 0x04 else {
            throw LicenseClientError.identityUnavailable
        }
        return representation.base64EncodedString()
    }

    func sign(base64Challenge: String) throws -> String {
        guard let challenge = Self.decodeBase64(base64Challenge),
              !challenge.isEmpty,
              challenge.count <= 4_096 else {
            throw LicenseClientError.invalidChallenge
        }
        return try sign(message: challenge)
    }

    func sign(message: Data) throws -> String {
        guard !message.isEmpty, message.count <= 8_192 else {
            throw LicenseClientError.invalidChallenge
        }
        let privateKey = try loadOrCreatePrivateKey()
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            message as CFData,
            &error
        ) as Data? else {
            throw LicenseClientError.identityUnavailable
        }
        return signature.base64EncodedString()
    }

    private func loadOrCreatePrivateKey() throws -> SecKey {
        Self.identityLock.lock()
        defer { Self.identityLock.unlock() }
        if let existing = try loadPrivateKey(tag: currentKeyTag) { return existing }
        if let existing = try loadPrivateKey(tag: legacyKeyTag) { return existing }
        // Tokens/enrollment already belong to a registered public key. Silently
        // creating a replacement would strand that registration on the server.
        guard try !hasSavedRegistration() else { throw LicenseClientError.identityUnavailable }
        if let enclaveKey = createSecureEnclaveKey() { return enclaveKey }
        if let racedKey = try loadPrivateKey(tag: currentKeyTag) { return racedKey }
        if let softwareKey = createSoftwareKey() { return softwareKey }
        if let racedKey = try loadPrivateKey(tag: currentKeyTag) { return racedKey }
        throw LicenseClientError.identityUnavailable
    }

    private func loadPrivateKey(tag: Data) throws -> SecKey? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: tag,
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let key = result else {
            throw LicenseClientError.keychain
        }
        return (key as! SecKey)
    }

    private func createSecureEnclaveKey() -> SecKey? {
#if targetEnvironment(simulator)
        return nil
#else
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            [.privateKeyUsage],
            &accessError
        ) else { return nil }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecAttrTokenID: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrApplicationTag: currentKeyTag,
                kSecAttrAccessControl: access
            ]
        ]
        return SecKeyCreateRandomKey(attributes as CFDictionary, nil)
#endif
    }

    private func createSoftwareKey() -> SecKey? {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrApplicationTag: currentKeyTag,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
        ]
        return SecKeyCreateRandomKey(attributes as CFDictionary, nil)
    }

    private static func decodeBase64(_ value: String) -> Data? {
        if let data = Data(base64Encoded: value) { return data }
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = normalized.count % 4
        if padding != 0 {
            normalized += String(repeating: "=", count: 4 - padding)
        }
        return Data(base64Encoded: normalized)
    }
}
