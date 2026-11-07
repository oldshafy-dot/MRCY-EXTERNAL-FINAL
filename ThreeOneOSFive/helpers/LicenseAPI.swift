import CryptoKit
import Foundation
import Security

private final class LicenseRedirectDelegate: NSObject, URLSessionTaskDelegate {
    private let allowedScheme: String
    private let allowedHost: String
    private let allowedPort: Int?
    private let pins: [Data]

    init(baseURL: URL, pins: [Data]) {
        allowedScheme = baseURL.scheme?.lowercased() ?? ""
        allowedHost = baseURL.host?.lowercased() ?? ""
        allowedPort = baseURL.port
        self.pins = pins
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(isAllowed(request.url) ? request : nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              hostAllowed(challenge.protectionSpace.host) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let policy = SecPolicyCreateSSL(true, allowedHost as CFString)
        SecTrustSetPolicies(trust, policy)
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error), pinned(trust) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    private func hostAllowed(_ host: String) -> Bool {
        host.caseInsensitiveCompare(allowedHost) == .orderedSame
    }

    private func pinned(_ trust: SecTrust) -> Bool {
        guard !pins.isEmpty else { return false }
        let chain: [SecCertificate]
        if let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate], !certificates.isEmpty {
            chain = certificates
        } else if SecTrustGetCertificateCount(trust) > 0, let leaf = SecTrustGetCertificateAtIndex(trust, 0) {
            chain = [leaf]
        } else {
            return false
        }
        return chain.contains { certificate in
            TLSPin.hashes(for: certificate).contains { pins.contains($0) }
        }
    }

    func isAllowed(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == allowedScheme
            && url.host?.lowercased() == allowedHost
            && url.port == allowedPort
    }
}

struct LoginNoticePayload: Decodable {
    let enabled: Bool
    let message: String
    let url: String
}

final class AccessChannel {
    private struct ServerError: Decodable {
        let message: String?
        let error: String?
    }

    private let configuration: LicenseClientConfiguration
    private let identity: DeviceStamp
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        configuration: LicenseClientConfiguration,
        identity: DeviceStamp
    ) {
        self.configuration = configuration
        self.identity = identity
    }

    func loginNotice() async -> LoginNoticePayload? {
        do {
            var request = URLRequest(url: try endpoint(path: "v1/robo/notice"))
            request.httpMethod = "GET"
            request.timeoutInterval = 12
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await perform(request)
            try validate(response: response, data: data)
            guard data.count <= 4_096 else { return nil }
            return try decoder.decode(LoginNoticePayload.self, from: data)
        } catch {
            return nil
        }
    }

    func startActivation(_ request: ActivationStartRequest) async throws -> PendingActivation {
        try await send(
            method: "POST",
            path: Self.route([
                0x2A, 0x6A, 0x7D, 0x28, 0x23, 0x0B, 0x1F, 0x1B, 0x05, 0x17,
                0x73, 0x7E, 0x66, 0x28, 0x4D, 0x41, 0x4D, 0x59, 0x56
            ]),
            body: request,
            bearer: nil
        )
    }

    func activationStatus(
        _ request: ActivationStatusRequest
    ) async throws -> ActivationStatusResponse {
        try await send(
            method: "POST",
            path: Self.route([
                0x2A, 0x6A, 0x7D, 0x28, 0x23, 0x0B, 0x1F, 0x1B, 0x05, 0x17,
                0x73, 0x7E, 0x66, 0x28, 0x4D, 0x41, 0x4D, 0x5F, 0x57, 0xAA
            ]),
            body: request,
            bearer: nil
        )
    }

    func proofChallenge(
        credential: String,
        type: String,
        installationID: String
    ) async throws -> ProofChallenge {
        try await send(
            method: "POST",
            path: Self.route([
                0x2A, 0x6A, 0x7D, 0x3A, 0x25, 0x0C, 0x05, 0x04, 0x0B, 0x0D,
                0x35, 0x72, 0x60, 0x66, 0x52, 0x59, 0x49, 0x45, 0x45, 0xBC
            ]),
            body: ChallengeRequest(
                installationID: installationID,
                credentialType: type
            ),
            bearer: credential
        )
    }

    func validateSession(
        accessToken: String,
        request: ProofRequest
    ) async throws -> LicenseCredentials {
        try await send(
            method: "POST",
            path: Self.route([
                0x2A, 0x6A, 0x7D, 0x3A, 0x25, 0x0C, 0x05, 0x04, 0x0B, 0x0D,
                0x35, 0x67, 0x69, 0x6B, 0x57, 0x51, 0x4D, 0x5F, 0x47
            ]),
            body: request,
            bearer: accessToken
        )
    }

    func refreshSession(
        refreshToken: String,
        request: ProofRequest
    ) async throws -> LicenseCredentials {
        try await send(
            method: "POST",
            path: Self.route([
                0x2A, 0x6A, 0x7D, 0x3A, 0x25, 0x0C, 0x05, 0x04, 0x0B, 0x0D,
                0x35, 0x63, 0x6D, 0x61, 0x4C, 0x50, 0x5F, 0x43
            ]),
            body: request,
            bearer: refreshToken
        )
    }

    func issueLease(accessToken: String) async throws -> OperationLease {
        try await send(
            method: "POST",
            path: Self.route([
                0x2A, 0x6A, 0x7D, 0x3A, 0x25, 0x0C, 0x05, 0x04, 0x0B, 0x0D,
                0x35, 0x7D, 0x6D, 0x66, 0x4D, 0x50
            ]),
            body: EmptyObject(),
            bearer: accessToken,
            signed: true
        )
    }

    func issueWritePermit(
        accessToken: String,
        request: WritePermitRequest
    ) async throws -> SignedWritePermit {
        try await send(
            method: "POST",
            path: Self.route([
                0x2A, 0x6A, 0x7D, 0x3A, 0x25, 0x0C, 0x05, 0x04, 0x0B, 0x0D,
                0x35, 0x61, 0x6D, 0x75, 0x53, 0x5C, 0x58
            ]),
            body: request,
            bearer: accessToken,
            signed: true,
            proofNonce: request.requestID,
            bindBody: true
        )
    }

    func latestManifest(
        accessToken: String,
        appVersion: String,
        appBuild: String
    ) async throws -> SignedManifestEnvelope? {
        var request = URLRequest(url: try endpoint(
            path: Self.route([
                0x2A, 0x6A, 0x7D, 0x2A, 0x2F, 0x11, 0x02, 0x08, 0x0A, 0x17,
                0x35, 0x7D, 0x69, 0x73, 0x5B, 0x46, 0x58
            ]),
            query: [
                URLQueryItem(name: "app_version", value: appVersion),
                URLQueryItem(name: "app_build", value: appBuild)
            ]
        ))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let box = try RuntimeBox.make(publicKey: configuration.responsePublicKey)
        request.setValue(box.headerValue(), forHTTPHeaderField: Self.wrapHeader)
        try addDeviceProof(to: &request)
        let (data, response) = try await perform(request)
        if (response as? HTTPURLResponse)?.statusCode == 204 { return nil }
        let inner = try box.unpack(data, publicKey: configuration.responsePublicKey)
        try validate(response: response, data: inner)
        if let flag = try? decoder.decode(AbsentFlag.self, from: inner), flag.absent {
            return nil
        }
        do {
            return try decoder.decode(SignedManifestEnvelope.self, from: inner)
        } catch {
            throw LicenseClientError.invalidResponse
        }
    }

    func downloadPackage(
        at url: URL,
        accessToken: String,
        maximumBytes: Int
    ) async throws -> Data {
        guard sameOrigin(url) else {
            throw LicenseClientError.packageInvalid(url.lastPathComponent)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 90
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let box = try RuntimeBox.make(publicKey: configuration.responsePublicKey)
        request.setValue(box.headerValue(), forHTTPHeaderField: Self.wrapHeader)
        try addDeviceProof(to: &request)

        let (data, response) = try await perform(request)
        guard data.count <= maximumBytes else {
            throw LicenseClientError.packageInvalid(url.lastPathComponent)
        }
        try validate(response: response, data: data)
        return data
    }

    private func send<Request: Encodable, Response: Decodable>(
        method: String,
        path: String,
        body: Request,
        bearer: String?,
        signed: Bool = false,
        proofNonce: String? = nil,
        bindBody: Bool = false
    ) async throws -> Response {
        var request = URLRequest(url: try endpoint(path: path))
        request.httpMethod = method
        request.timeoutInterval = 30
        let box = try RuntimeBox.make(publicKey: configuration.responsePublicKey)
        request.httpBody = try box.packedRequest(plain: encoder.encode(body))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        if signed {
            try addDeviceProof(to: &request, nonce: proofNonce, bindBody: bindBody)
        }
        return try await decode(request, box: box)
    }

    private func decode<Response: Decodable>(
        _ request: URLRequest,
        box: RuntimeBox
    ) async throws -> Response {
        let (data, response) = try await perform(request)
        let inner = try box.unpack(data, publicKey: configuration.responsePublicKey)
        try validate(response: response, data: inner)
        do {
            return try decoder.decode(Response.self, from: inner)
        } catch {
            throw LicenseClientError.invalidResponse
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var outgoing = request
        outgoing.setValue("mrcy", forHTTPHeaderField: "x-vita-product")
        let box = LicenseSessionBox(
            baseURL: configuration.serverBaseURL,
            pins: configuration.tlsPins
        )
        defer { box.session.finishTasksAndInvalidate() }
        do {
            let result: (Data, URLResponse) = try await withCheckedThrowingContinuation { continuation in
                let settled = OnceFlag()
                let task = box.session.dataTask(with: outgoing) { data, response, error in
                    settled.go {
                        if let error {
                            continuation.resume(throwing: error)
                            return
                        }
                        guard let data, let response else {
                            continuation.resume(throwing: URLError(.badServerResponse))
                            return
                        }
                        continuation.resume(returning: (data, response))
                    }
                }
                task.resume()
            }
            guard box.delegate.isAllowed(result.1.url) else {
                throw LicenseClientError.invalidResponse
            }
            return result
        } catch let error as LicenseClientError {
            throw error
        } catch {
            throw LicenseClientError.transport(error.localizedDescription)
        }
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LicenseClientError.invalidResponse
        }
        if http.statusCode == 401 {
            throw LicenseClientError.unauthorized
        }
        if http.statusCode == 403 {
            throw denial(from: data) ?? LicenseClientError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            let serverError = try? decoder.decode(ServerError.self, from: data)
            let message = serverError?.message
                ?? serverError?.error
                ?? "Server request failed (\(http.statusCode))."
            throw LicenseClientError.server(message)
        }
    }

    private func denial(from data: Data) -> LicenseClientError? {
        let serverError = try? decoder.decode(ServerError.self, from: data)
        let raw = (serverError?.error ?? serverError?.message ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if raw.contains("unknown build") {
            return .server("This app version is not allowed. Install the latest MRCY iOS.")
        }
        if raw.contains("unknown package") {
            return .server("This function is not available. Check for an update and try again.")
        }
        return nil
    }

    private func endpoint(
        path: String,
        query: [URLQueryItem] = []
    ) throws -> URL {
        guard var components = URLComponents(
            url: configuration.serverBaseURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw LicenseClientError.unconfigured("Unavailable.")
        }
        let prefix = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [prefix, suffix].filter { !$0.isEmpty }.joined(separator: "/")
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url, sameOrigin(url) else {
            throw LicenseClientError.unconfigured("Unavailable.")
        }
        return url
    }

    private func sameOrigin(_ url: URL) -> Bool {
        url.scheme?.lowercased() == configuration.serverBaseURL.scheme?.lowercased()
            && url.host?.lowercased() == configuration.serverBaseURL.host?.lowercased()
            && url.port == configuration.serverBaseURL.port
            && url.user == nil
            && url.password == nil
    }

    private func addDeviceProof(
        to request: inout URLRequest,
        nonce suppliedNonce: String? = nil,
        bindBody: Bool = false
    ) throws {
        guard let url = request.url,
              let method = request.httpMethod,
              let components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
              ) else {
            throw LicenseClientError.invalidResponse
        }
        let installationID = try identity.installationID()
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let nonce = suppliedNonce ?? UUID().uuidString.lowercased()
        let target = components.percentEncodedPath
            + (components.percentEncodedQuery.map { "?\($0)" } ?? "")
        var fields = [method.uppercased(), target, installationID, timestamp, nonce]
        if bindBody {
            guard let body = request.httpBody else { throw LicenseClientError.invalidResponse }
            fields.append("body-sha256")
            fields.append(CatalogTrust.sha256Hex(body))
        }
        let message = fields.joined(separator: "\n")
        let signature = try identity.sign(message: Data(message.utf8))
        request.setValue(
            installationID,
            forHTTPHeaderField: Self.route([
                0x04, 0x76, 0x06, 0x26, 0x2C, 0x1E, 0x5B, 0x24, 0x0A, 0x10,
                0x6E, 0x70, 0x64, 0x6B, 0x5F, 0x41, 0x45, 0x44, 0x4C, 0xF4,
                0x99, 0x8B
            ])
        )
        request.setValue(
            timestamp,
            forHTTPHeaderField: Self.route([
                0x04, 0x76, 0x06, 0x26, 0x2C, 0x1E, 0x5B, 0x39, 0x0D, 0x0E,
                0x7F, 0x62, 0x7C, 0x66, 0x53, 0x45
            ])
        )
        request.setValue(
            nonce,
            forHTTPHeaderField: Self.route([
                0x04, 0x76, 0x06, 0x26, 0x2C, 0x1E, 0x5B, 0x23, 0x0B, 0x0D,
                0x79, 0x74
            ])
        )
        request.setValue(
            signature,
            forHTTPHeaderField: Self.route([
                0x04, 0x76, 0x06, 0x26, 0x2C, 0x1E, 0x5B, 0x3D, 0x16, 0x0C,
                0x75, 0x77
            ])
        )
    }

    private static let wrapHeader = route([
        0x24, 0x76, 0x35, 0x31, 0x6D, 0x14
    ])

    private struct AbsentFlag: Decodable {
        let absent: Bool
    }

    private struct EmptyObject: Encodable {}

    private static func route(_ packed: [UInt8]) -> String {
        String(
            decoding: packed.enumerated().map { index, byte in
                byte ^ 0x5C ^ UInt8(truncatingIfNeeded: index &* 7)
            },
            as: UTF8.self
        )
    }
}

private final class OnceFlag {
    private let lock = NSLock()
    private var done = false

    func go(_ body: () -> Void) {
        lock.lock()
        if done {
            lock.unlock()
            return
        }
        done = true
        lock.unlock()
        body()
    }
}

private final class LicenseSessionBox {
    let delegate: LicenseRedirectDelegate
    let session: URLSession

    init(baseURL: URL, pins: [Data]) {
        let delegate = LicenseRedirectDelegate(baseURL: baseURL, pins: pins)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 120
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldUsePipelining = false
        self.delegate = delegate
        self.session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
    }
}

private enum TLSPin {
    static func hashes(for certificate: SecCertificate) -> [Data] {
        var values: [Data] = []
        let der = SecCertificateCopyData(certificate) as Data
        values.append(Data(SHA256.hash(data: der)))
        if let spki = publicKeySPKI(certificate) {
            values.append(Data(SHA256.hash(data: spki)))
        }
        if let spki = extractSPKI(der) {
            values.append(Data(SHA256.hash(data: spki)))
        }
        return values
    }

    static func publicKeySPKI(_ certificate: SecCertificate) -> Data? {
        guard let key = SecCertificateCopyKey(certificate),
              let raw = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              let attributes = SecKeyCopyAttributes(key) as? [String: Any],
              let type = attributes[kSecAttrKeyType as String] as? String else {
            return nil
        }
        if type == (kSecAttrKeyTypeECSECPrimeRandom as String) {
            return ecSPKI(raw)
        }
        if type == (kSecAttrKeyTypeRSA as String) {
            return rsaSPKI(raw)
        }
        return nil
    }

    private static func ecSPKI(_ point: Data) -> Data? {
        let header: [UInt8]
        switch point.count {
        case 65:
            header = [
                0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
                0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00
            ]
        case 97:
            header = [
                0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
                0x06, 0x05, 0x2B, 0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00
            ]
        default:
            return nil
        }
        var data = Data(header)
        data.append(point)
        return data
    }

    private static func rsaSPKI(_ pkcs1: Data) -> Data {
        let algorithm = Data([
            0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00
        ])
        var bitString = Data([0x03])
        bitString.append(derLength(pkcs1.count + 1))
        bitString.append(0x00)
        bitString.append(pkcs1)
        let body = algorithm + bitString
        var spki = Data([0x30])
        spki.append(derLength(body.count))
        spki.append(body)
        return spki
    }

    private static func derLength(_ value: Int) -> Data {
        if value < 0x80 {
            return Data([UInt8(value)])
        }
        var bytes: [UInt8] = []
        var current = value
        while current > 0 {
            bytes.insert(UInt8(current & 0xFF), at: 0)
            current >>= 8
        }
        return Data([UInt8(0x80 | bytes.count)] + bytes)
    }

    private static func extractSPKI(_ der: Data) -> Data? {
        guard let certificate = readTLV(der, 0), certificate.tag == 0x30,
              let tbs = readTLV(certificate.value, 0), tbs.tag == 0x30 else {
            return nil
        }
        var index = 0
        var fields: [(UInt8, Data)] = []
        while index < tbs.value.count {
            guard let field = readTLV(tbs.value, index) else { return nil }
            fields.append((field.tag, field.raw))
            index = field.end
        }
        let offset = fields.first?.0 == 0xA0 ? 1 : 0
        guard fields.count > offset + 5 else { return nil }
        return fields[offset + 5].1
    }

    private struct TLV {
        let tag: UInt8
        let raw: Data
        let value: Data
        let end: Int
    }

    private static func readTLV(_ data: Data, _ start: Int) -> TLV? {
        guard start >= 0, start < data.count else { return nil }
        let bytes = [UInt8](data)
        let tag = bytes[start]
        var index = start + 1
        guard index < bytes.count else { return nil }
        let first = bytes[index]
        index += 1
        let length: Int
        if first < 0x80 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7F)
            guard count > 0, count <= 4, index + count <= bytes.count else { return nil }
            var value = 0
            for _ in 0..<count {
                value = (value << 8) | Int(bytes[index])
                index += 1
            }
            length = value
        }
        let end = index + length
        guard end <= bytes.count else { return nil }
        return TLV(
            tag: tag,
            raw: Data(bytes[start..<end]),
            value: Data(bytes[index..<end]),
            end: end
        )
    }
}
