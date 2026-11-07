import CryptoKit
import Foundation
import Security

struct RuntimeBox {
    private let aesKey: SymmetricKey
    private let wrappedKey: Data

    static func make(publicKey: Data) throws -> RuntimeBox {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw LicenseClientError.invalidResponse }
        let raw = Data(bytes)
        return RuntimeBox(
            aesKey: SymmetricKey(data: raw),
            wrappedKey: try rsaEncrypt(raw, publicKey: publicKey)
        )
    }

    func packedRequest(plain: Data) throws -> Data {
        let sealed = try encrypt(plain)
        return try JSONSerialization.data(
            withJSONObject: [
                "v": 1,
                "k": wrappedKey.base64EncodedString(),
                "n": sealed.nonce.base64EncodedString(),
                "p": sealed.payload.base64EncodedString()
            ],
            options: []
        )
    }

    func headerValue() -> String {
        wrappedKey.base64EncodedString()
    }

    func unpack(_ data: Data, publicKey: Data) throws -> Data {
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["v"] as? Int == 1,
            let nonceB64 = object["n"] as? String,
            let payloadB64 = object["p"] as? String,
            let signatureB64 = object["s"] as? String,
            let nonce = Data(base64Encoded: nonceB64),
            let payload = Data(base64Encoded: payloadB64),
            let signature = Data(base64Encoded: signatureB64),
            nonce.count == 12,
            payload.count > 16
        else {
            throw LicenseClientError.invalidResponse
        }
        var message = Data([1])
        message.append(nonce)
        message.append(payload)
        guard rsaVerify(message, signature: signature, publicKey: publicKey) else {
            throw LicenseClientError.invalidResponse
        }
        return try decrypt(nonce: nonce, payload: payload)
    }

    private func encrypt(_ plain: Data) throws -> (nonce: Data, payload: Data) {
        let sealed = try AES.GCM.seal(plain, using: aesKey)
        let nonce = Data(sealed.nonce)
        var payload = Data(sealed.ciphertext)
        payload.append(sealed.tag)
        return (nonce, payload)
    }

    private func decrypt(nonce: Data, payload: Data) throws -> Data {
        let tag = payload.suffix(16)
        let ciphertext = payload.dropLast(16)
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonce),
            ciphertext: ciphertext,
            tag: tag
        )
        return try AES.GCM.open(box, using: aesKey)
    }
}

private func rsaEncrypt(_ data: Data, publicKey: Data) throws -> Data {
    let key = try rsaPublicKey(publicKey)
    var error: Unmanaged<CFError>?
    guard let encrypted = SecKeyCreateEncryptedData(
        key,
        .rsaEncryptionOAEPSHA256,
        data as CFData,
        &error
    ) as Data? else {
        throw LicenseClientError.invalidResponse
    }
    return encrypted
}

private func rsaVerify(_ message: Data, signature: Data, publicKey: Data) -> Bool {
    guard let key = try? rsaPublicKey(publicKey) else { return false }
    var error: Unmanaged<CFError>?
    return SecKeyVerifySignature(
        key,
        .rsaSignatureMessagePSSSHA256,
        message as CFData,
        signature as CFData,
        &error
    )
}

private func rsaPublicKey(_ spki: Data) throws -> SecKey {
    let attributes: [CFString: Any] = [
        kSecAttrKeyType: kSecAttrKeyTypeRSA,
        kSecAttrKeyClass: kSecAttrKeyClassPublic,
        kSecAttrKeySizeInBits: 3072
    ]
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateWithData(spki as CFData, attributes as CFDictionary, &error) else {
        throw LicenseClientError.unconfigured("Unavailable.")
    }
    return key
}
