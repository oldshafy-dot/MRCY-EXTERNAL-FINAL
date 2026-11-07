import CryptoKit
import Foundation

enum RuntimePermit {
    private static let lock = NSLock()
    private static var stamp: UInt64 = 0
    private static var leaseUntil: Date?

    @discardableResult
    static func bind(
        token: String,
        licenseID: String,
        installationID: String,
        host: String,
        lease: String,
        until: Date
    ) -> Bool {
        guard until.timeIntervalSinceNow > 5,
              !lease.isEmpty,
              lease.utf8.count <= 256 else {
            return false
        }
        let next = mix(
            token: token,
            licenseID: licenseID,
            installationID: installationID,
            host: host,
            lease: lease
        )
        guard next != 0 else { return false }
        lock.lock()
        stamp = next
        leaseUntil = until
        lock.unlock()
        gx_gate_bind(next)
        return gx_gate_ok(next) != 0
    }

    static func clear() {
        lock.lock()
        stamp = 0
        leaseUntil = nil
        lock.unlock()
        gx_gate_clear()
    }

    static func isFresh() -> Bool {
        lock.lock()
        let current = stamp
        let leaseUntil = leaseUntil
        lock.unlock()
        guard current != 0, gx_gate_ok(current) != 0 else { return false }
        guard let leaseUntil, Date() < leaseUntil else { return false }
        return true
    }

    static func assertReady() throws {
        guard isFresh() else { throw LicenseClientError.unauthorized }
    }

    static func wrap(_ data: Data, installationID: String, publicKey: String) throws -> Data {
        let box = try AES.GCM.seal(data, using: wrapKey(installationID: installationID, publicKey: publicKey))
        guard let combined = box.combined else { throw LicenseClientError.keychain }
        var payload = Data([0x47, 0x58, 0x01])
        payload.append(combined)
        return payload
    }

    static func unwrap(_ data: Data, installationID: String, publicKey: String) throws -> Data {
        guard data.count > 3, data[0] == 0x47, data[1] == 0x58, data[2] == 0x01 else {
            return data
        }
        let box = try AES.GCM.SealedBox(combined: data.dropFirst(3))
        return try AES.GCM.open(
            box,
            using: wrapKey(installationID: installationID, publicKey: publicKey)
        )
    }

    private static func mix(
        token: String,
        licenseID: String,
        installationID: String,
        host: String,
        lease: String
    ) -> UInt64 {
        var hasher = SHA256()
        hasher.update(data: Data(token.utf8))
        hasher.update(data: Data(licenseID.utf8))
        hasher.update(data: Data(installationID.utf8))
        hasher.update(data: Data(host.lowercased().utf8))
        hasher.update(data: Data(lease.utf8))
        hasher.update(data: Data([
            0x91, 0x2C, 0x7A, 0xE4, 0x10, 0xB8, 0x5D, 0x63,
            0xF1, 0x0A, 0x44, 0xC9, 0x37, 0xDE, 0x88, 0x16
        ]))
        let digest = hasher.finalize()
        return digest.withUnsafeBytes { raw in
            raw.load(as: UInt64.self).bigEndian
        }
    }

    private static func wrapKey(installationID: String, publicKey: String) -> SymmetricKey {
        var hasher = SHA256()
        hasher.update(data: Data(installationID.utf8))
        hasher.update(data: Data(publicKey.utf8))
        hasher.update(data: Data([
            0x4E, 0x19, 0xA2, 0x70, 0xC3, 0x5B, 0x08, 0xD6,
            0xE1, 0x2F, 0x94, 0x7C, 0x51, 0xB0, 0x3A, 0x66
        ]))
        return SymmetricKey(data: Data(hasher.finalize()))
    }
}
