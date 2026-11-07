import Foundation

struct LicenseClientConfiguration {
    let serverBaseURL: URL
    let manifestPublicKey: Data
    let responsePublicKey: Data
    let tlsPins: [Data]

    static func load(bundle: Bundle = .main) throws -> LicenseClientConfiguration {
        _ = bundle
        let material = try RuntimeMaterial.reveal()
        return LicenseClientConfiguration(
            serverBaseURL: material.url,
            manifestPublicKey: material.key,
            responsePublicKey: material.response,
            tlsPins: material.pins
        )
    }
}

struct OperationLease: Decodable {
    let lease: String
    let expiresAt: String

    private enum CodingKeys: String, CodingKey {
        case lease
        case expiresAt = "expires_at"
    }
}

struct WritePermitRequest: Encodable {
    let requestID: String
    let packageID: String
    let sha256: String
    let action: String
    let appVersion: String
    let appBuild: String

    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case packageID = "package_id"
        case sha256
        case action
        case appVersion = "app_version"
        case appBuild = "app_build"
    }
}

struct SignedWritePermit: Decodable {
    let permitBase64: String
    let signature: String

    private enum CodingKeys: String, CodingKey {
        case permitBase64 = "permit_base64"
        case signature
    }
}

struct WritePermit: Decodable {
    let scope: String
    let requestID: String
    let packageID: String
    let sha256: String
    let action: String
    let installationID: String
    let expiresAt: String
    let appVersion: String
    let appBuild: String

    private enum CodingKeys: String, CodingKey {
        case scope
        case requestID = "request_id"
        case packageID = "package_id"
        case sha256
        case action
        case installationID = "installation_id"
        case expiresAt = "expires_at"
        case appVersion = "app_version"
        case appBuild = "app_build"
    }
}

struct LicenseProfile: Codable, Equatable {
    let licenseID: String
    let maskedKey: String?
    let expiresAt: String
    let registeredDevice: String
    let udid: String?

    private enum CodingKeys: String, CodingKey {
        case licenseID = "license_id"
        case maskedKey = "masked_key"
        case expiresAt = "expires_at"
        case registeredDevice = "registered_device"
        case udid
    }
}

struct LicenseCredentials: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let accessExpiresAt: String
    let profile: LicenseProfile

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case accessExpiresAt = "access_expires_at"
        case profile
    }
}

struct PendingActivation: Codable, Equatable {
    let activationID: String
    let pollToken: String
    let challengeID: String
    let challenge: String

    private enum CodingKeys: String, CodingKey {
        case activationID = "activation_id"
        case pollToken = "poll_token"
        case challengeID = "challenge_id"
        case challenge
    }
}

struct ActivationStartRequest: Encodable {
    let licenseKey: String
    let deviceModel: String
    let systemVersion: String
    let systemBuild: String
    let appVersion: String
    let appBuild: String
    let installationID: String
    let deviceHwid: String
    let publicKey: String
    let publicKeyFormat = "p256-x963-base64"

    private enum CodingKeys: String, CodingKey {
        case licenseKey = "license_key"
        case deviceModel = "device_model"
        case systemVersion = "system_version"
        case systemBuild = "system_build"
        case appVersion = "app_version"
        case appBuild = "app_build"
        case installationID = "installation_id"
        case deviceHwid = "device_hwid"
        case publicKey = "public_key"
        case publicKeyFormat = "public_key_format"
    }
}

struct ActivationStatusRequest: Encodable {
    let activationID: String
    let pollToken: String
    let installationID: String
    let challengeID: String
    let proofSignature: String
    let proofSignatureFormat = "ecdsa-p256-sha256-der-base64"

    private enum CodingKeys: String, CodingKey {
        case activationID = "activation_id"
        case pollToken = "poll_token"
        case installationID = "installation_id"
        case challengeID = "challenge_id"
        case proofSignature = "proof_signature"
        case proofSignatureFormat = "proof_signature_format"
    }
}

struct ActivationStatusResponse: Decodable {
    let status: String
    let challengeID: String?
    let challenge: String?
    let credentials: LicenseCredentials?

    private enum CodingKeys: String, CodingKey {
        case status
        case challengeID = "challenge_id"
        case challenge
        case credentials
    }
}

struct ProofChallenge: Decodable {
    let challengeID: String
    let challenge: String

    private enum CodingKeys: String, CodingKey {
        case challengeID = "challenge_id"
        case challenge
    }
}

struct ChallengeRequest: Encodable {
    let installationID: String
    let credentialType: String

    private enum CodingKeys: String, CodingKey {
        case installationID = "installation_id"
        case credentialType = "credential_type"
    }
}

struct ProofRequest: Encodable {
    let installationID: String
    let challengeID: String
    let proofSignature: String
    let proofSignatureFormat = "ecdsa-p256-sha256-der-base64"

    private enum CodingKeys: String, CodingKey {
        case installationID = "installation_id"
        case challengeID = "challenge_id"
        case proofSignature = "proof_signature"
        case proofSignatureFormat = "proof_signature_format"
    }
}

struct SignedManifestEnvelope: Decodable {
    let manifestBase64: String
    let signature: String
    let games: [ContentGameDescriptor]?

    private enum CodingKeys: String, CodingKey {
        case manifestBase64 = "manifest_base64"
        case signature
        case games
    }
}

struct ContentGameDescriptor: Codable, Identifiable, Equatable, Hashable {
    let name: String
    let bundleID: String
    let icon: String

    var id: String { bundleID }

    var slug: String {
        switch bundleID {
        case "com.dts.freefireth": return "free-fire"
        case "com.dts.freefiremax": return "free-fire-max"
        default: return bundleID
        }
    }

    static let defaults = [
        ContentGameDescriptor(name: "Free Fire", bundleID: "com.dts.freefireth", icon: ""),
        ContentGameDescriptor(name: "Free Fire MAX", bundleID: "com.dts.freefiremax", icon: ""),
        ContentGameDescriptor(name: "Free Fire India", bundleID: "com.dts.freefireindia", icon: ""),
        ContentGameDescriptor(name: "PUBG Mobile", bundleID: "com.tencent.ig", icon: ""),
        ContentGameDescriptor(name: "PUBG Mobile India", bundleID: "com.pubg.imobile", icon: ""),
    ]

    private enum CodingKeys: String, CodingKey {
        case name
        case bundleID = "bundleId"
        case icon
    }
}

struct ContentReleaseManifest: Codable, Identifiable, Equatable {
    let product: String
    let releaseID: String
    let version: String
    let name: String?
    let description: String?
    let required: Bool
    let packages: [ContentPackageDescriptor]

    var id: String { releaseID }

    private enum CodingKeys: String, CodingKey {
        case product
        case releaseID = "release_id"
        case version
        case name
        case description
        case required
        case packages
    }
}

struct ContentPackageDescriptor: Codable, Equatable {
    let identifier: String
    let fileName: String
    let name: String?
    let description: String?
    let icon: String?
    let game: String?
    let sort: Int?
    let url: String
    let sha256: String
    let size: Int?

    private enum CodingKeys: String, CodingKey {
        case identifier
        case fileName = "file_name"
        case name
        case description
        case icon
        case game
        case sort
        case url
        case sha256
        case size
    }
}

enum LicenseClientError: LocalizedError, Equatable {
    case unconfigured(String)
    case invalidResponse
    case unauthorized
    case server(String)
    case transport(String)
    case keychain
    case identityUnavailable
    case invalidChallenge
    case activationPending
    case manifestInvalid
    case packageInvalid(String)

    var errorDescription: String? {
        switch self {
        case .unconfigured(let message): return message
        case .invalidResponse: return "The licensing server returned an invalid response."
        case .unauthorized: return "This license session is no longer authorized."
        case .server(let message): return message
        case .transport(let message): return "Could not reach the licensing server: \(message)"
        case .keychain: return "Secure storage is unavailable."
        case .identityUnavailable: return "Your saved device identity is unavailable. Unlock this device and retry. If you changed signing certificates, use the original signing identity or contact support."
        case .invalidChallenge: return "The server proof challenge was invalid."
        case .activationPending: return "Activation did not complete. Try again."
        case .manifestInvalid: return "The content update signature is invalid."
        case .packageInvalid: return "The downloaded package is invalid."
        }
    }
}

extension Bundle {
    var clientAppVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var clientAppBuild: String {
        object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}

extension LicenseProfile {
    var expiryText: String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let precise = parser.date(from: expiresAt)
        parser.formatOptions = [.withInternetDateTime]
        guard let date = precise ?? parser.date(from: expiresAt) else { return expiresAt }
        return date.formatted(date: .long, time: .shortened)
    }
}
