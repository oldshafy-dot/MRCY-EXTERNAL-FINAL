import CryptoKit
import Foundation

enum RuntimeMaterial {
    static func reveal() throws -> (url: URL, key: Data, response: Data, pins: [Data]) {
        let wire = restore(RuntimeBlob.w0 + RuntimeBlob.w1)
        let mark = restore(RuntimeBlob.m)
        let response = restore(RuntimeBlob.r)
        let pinBlob = restore(RuntimeBlob.p)
        guard
            let text = String(data: wire, encoding: .utf8),
            !text.isEmpty,
            let url = URL(string: text),
            isSecure(url),
            url.host != nil,
            url.user == nil,
            url.password == nil,
            url.query == nil,
            url.fragment == nil
        else {
            throw LicenseClientError.unconfigured("Unavailable.")
        }
        guard mark.count == 32,
              response.count >= 300,
              response.count <= 800,
              pinBlob.count >= 32,
              pinBlob.count % 32 == 0,
              pinBlob.count <= 256 else {
            throw LicenseClientError.unconfigured("Unavailable.")
        }
        let pins = stride(from: 0, to: pinBlob.count, by: 32).map {
            pinBlob.subdata(in: $0..<($0 + 32))
        }
        return (url, mark, response, pins)
    }

    static func wrapKey() throws -> Data {
        let response = restore(RuntimeBlob.r)
        guard response.count >= 300, response.count <= 800 else {
            throw LicenseClientError.unconfigured("Unavailable.")
        }
        var hasher = SHA256()
        hasher.update(data: response)
        hasher.update(data: Data([
            0x2C, 0x3C, 0x34, 0x22, 0x74, 0x37, 0x3B, 0x29, 0x2E, 0x3F, 0x28, 0x74, 0x68,
        ].map { $0 ^ 0x5A }))
        return Data(hasher.finalize())
    }

    private static func restore(_ packed: [UInt8]) -> Data {
        let salt = RuntimeBlob.s
        guard !salt.isEmpty, !packed.isEmpty else { return Data() }
        var output = [UInt8](repeating: 0, count: packed.count)
        salt.withUnsafeBufferPointer { saltBuffer in
            packed.withUnsafeBufferPointer { inputBuffer in
                output.withUnsafeMutableBufferPointer { outputBuffer in
                    gx_unfold(
                        saltBuffer.baseAddress,
                        saltBuffer.count,
                        inputBuffer.baseAddress,
                        outputBuffer.baseAddress,
                        packed.count
                    )
                }
            }
        }
        return Data(output)
    }

    private static func isSecure(_ url: URL) -> Bool {
        let scheme = Array((url.scheme ?? "").utf8)
        return scheme.count == 5
            && scheme[0] == 104
            && scheme[1] == 116
            && scheme[2] == 116
            && scheme[3] == 112
            && scheme[4] == 115
    }
}
