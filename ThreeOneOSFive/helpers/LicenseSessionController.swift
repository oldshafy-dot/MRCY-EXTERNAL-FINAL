import Combine
import CryptoKit
import Foundation
import UIKit

enum LicenseGateState: Equatable {
    case loading
    case unconfigured(String)
    case signedOut
    case authenticated
    case blocked(String)
}

@MainActor
final class LicenseSessionController: ObservableObject {
    @Published private(set) var state: LicenseGateState = .loading
    @Published private(set) var profile: LicenseProfile?
    @Published private(set) var isWorking = false
    @Published private(set) var workspaceUnlocked = false
    @Published private(set) var authorityRevision = 0
    @Published var errorMessage: String?

    var hasLiveAuthority: Bool {
        _ = authorityRevision
        return workspaceUnlocked && RuntimePermit.isFresh()
    }

    private let identity = DeviceStamp()
    private var configuration: LicenseClientConfiguration?
    private var api: AccessChannel?
    private var credentials: LicenseCredentials?
    private var pendingActivation: PendingActivation?
    private var started = false
    private var validationTask: Task<Void, Never>?
    private var pulseTask: Task<Void, Never>?
    private var sessionGeneration = 0

    private let credentialsAccount = "tok.v3"
    private let pendingAccount = "enr.v3"
    private let legacyCredentialsAccount = "session-credentials"
    private let legacyPendingAccount = "pending-activation"

    func startIfNeeded() async {
        guard !started else { return }
        started = true
        state = .loading

        do {
            let configuration = try LicenseClientConfiguration.load()
            self.configuration = configuration
            api = AccessChannel(configuration: configuration, identity: identity)
            _ = try identity.installationID()
            _ = try identity.publicKeyBase64()

            if let pending: PendingActivation = try loadSecureValue(account: pendingAccount) {
                pendingActivation = pending
                await pollActivation()
                if case .loading = state {
                    state = .signedOut
                }
                return
            }
            guard let stored: LicenseCredentials = try loadSecureValue(
                account: credentialsAccount
            ) else {
                state = .signedOut
                return
            }
            credentials = stored
            profile = stored.profile
            await validateStoredSession()
        } catch let error as LicenseClientError {
            if case .unconfigured(let message) = error {
                state = .unconfigured(message)
            } else {
                state = .blocked(error.localizedDescription)
            }
        } catch {
            state = .blocked(error.localizedDescription)
        }
    }

    func loginNotice() async -> (message: String, url: URL)? {
        let fallbackMessage = "Stay connected and get the latest updates, news, and announcements right on your bot!"
        guard let fallbackURL = URL(string: "https://t.me/roboiosbot") else { return nil }
        for _ in 0..<40 where api == nil {
            if case .loading = state {
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            break
        }
        guard let api, let notice = await api.loginNotice() else {
            return (fallbackMessage, fallbackURL)
        }
        guard notice.enabled else { return nil }
        let message = notice.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty,
              message.count <= 500,
              let url = URL(string: notice.url),
              Self.allowedBotURL(url) else {
            return (fallbackMessage, fallbackURL)
        }
        return (message, url)
    }

    private static func allowedBotURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let host = url.host?.lowercased(),
              host == "t.me" || host == "telegram.me" else {
            return false
        }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return !path.isEmpty && path.count <= 80 && !path.contains("..")
    }

    func beginActivation(licenseKey: String) async {
        guard !isWorking, let api else { return }
        let key = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 512 else {
            errorMessage = "Invalid License"
            return
        }

        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let installationID = try identity.installationID()
            let request = ActivationStartRequest(
                licenseKey: key,
                deviceModel: Self.hardwareModel(),
                systemVersion: UIDevice.current.systemVersion,
                systemBuild: AppInfo.osBuild,
                appVersion: Bundle.main.clientAppVersion,
                appBuild: Bundle.main.clientAppBuild,
                installationID: installationID,
                deviceHwid: DeviceHWID.value,
                publicKey: try identity.publicKeyBase64()
            )
            let pending = try await api.startActivation(request)
            guard !pending.activationID.isEmpty,
                  !pending.pollToken.isEmpty,
                  !pending.challengeID.isEmpty else {
                throw LicenseClientError.invalidResponse
            }
            _ = try identity.sign(base64Challenge: pending.challenge)
            try saveSecureValue(pending, account: pendingAccount)
            pendingActivation = pending
            await completePendingActivation()
        } catch {
            errorMessage = Self.friendlyLicenseMessage(error.localizedDescription)
        }
    }

    func sceneBecameActive() async {
        switch state {
        case .signedOut:
            if pendingActivation != nil {
                await pollActivation()
            }
        case .authenticated, .blocked(_):
            if credentials != nil {
                await renewAuthorityIfNeeded()
            }
        default:
            break
        }
    }

    func pollActivation() async {
        guard !isWorking,
              pendingActivation != nil else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        await completePendingActivation()
    }

    private func completePendingActivation() async {
        guard let api,
              let pending = pendingActivation else { return }

        do {
            let request = ActivationStatusRequest(
                activationID: pending.activationID,
                pollToken: pending.pollToken,
                installationID: try identity.installationID(),
                challengeID: pending.challengeID,
                proofSignature: try identity.sign(base64Challenge: pending.challenge)
            )
            let response = try await api.activationStatus(request)
            switch response.status.lowercased() {
            case "active", "activated", "complete":
                guard let newCredentials = response.credentials else {
                    throw LicenseClientError.invalidResponse
                }
                try await finishAuthorization(credentials: newCredentials)
            default:
                abandonPendingActivation(
                    message: "Activation did not complete. Enter your license key to try again."
                )
            }
        } catch LicenseClientError.unauthorized,
                LicenseClientError.invalidChallenge,
                LicenseClientError.invalidResponse {
            if credentials != nil {
                state = .authenticated
                errorMessage = "Finishing activation. Keep the app open."
                startPulse()
                return
            }
            abandonPendingActivation(message: "Could not confirm activation. Enter your license key to try again.")
        } catch {
            if credentials != nil {
                state = .authenticated
                startPulse()
                return
            }
            errorMessage = error.localizedDescription
            state = .signedOut
        }
    }

    func cancelEnrollment() {
        abandonPendingActivation(message: nil)
    }

    private func abandonPendingActivation(message: String?) {
        VaultBox.delete(account: pendingAccount)
        VaultBox.delete(account: legacyPendingAccount)
        pendingActivation = nil
        state = .signedOut
        errorMessage = message
    }

    func retrySession() async {
        guard credentials != nil else {
            // A previous Keychain read may have failed while locked. Retry
            // loading the saved session instead of starting a new one.
            started = false
            await startIfNeeded()
            return
        }
        await validateStoredSession()
    }

    func logout() {
        sessionGeneration += 1
        validationTask?.cancel()
        validationTask = nil
        pulseTask?.cancel()
        pulseTask = nil
        RuntimePermit.clear()
        workspaceUnlocked = false
        authorityRevision += 1
        VaultBox.delete(account: credentialsAccount)
        VaultBox.delete(account: legacyCredentialsAccount)
        VaultBox.delete(account: pendingAccount)
        VaultBox.delete(account: legacyPendingAccount)
        credentials = nil
        pendingActivation = nil
        profile = nil
        errorMessage = nil
        state = .signedOut
    }

    func authorizedAccessToken() async throws -> String {
        if !hasLiveAuthority || Self.tokenNeedsRefresh(credentials?.accessExpiresAt ?? "") {
            try await requireOperationLease()
        }
        guard hasLiveAuthority,
              state == .authenticated,
              let token = credentials?.accessToken,
              !Self.tokenNeedsRefresh(credentials?.accessExpiresAt ?? "") else {
            throw LicenseClientError.unauthorized
        }
        return token
    }

    func requireOperationLease() async throws {
        guard credentials != nil else {
            throw LicenseClientError.unauthorized
        }
        if Self.tokenNeedsRefresh(credentials?.accessExpiresAt ?? "") {
            await validateStoredSession()
        } else {
            try await attachLease()
        }
        guard hasLiveAuthority else {
            throw LicenseClientError.unauthorized
        }
    }

    func renewAuthorityIfNeeded() async {
        guard credentials != nil else { return }
        switch state {
        case .authenticated, .blocked(_):
            break
        default:
            return
        }
        do {
            try await requireOperationLease()
        } catch LicenseClientError.unauthorized {
            logout()
            errorMessage = LicenseClientError.unauthorized.localizedDescription
        } catch {
            if !RuntimePermit.isFresh() {
                workspaceUnlocked = false
                authorityRevision += 1
                errorMessage = error.localizedDescription
            }
        }
    }

    func fetchLatestManifest() async throws -> SignedManifestEnvelope? {
        guard let api else {
            throw LicenseClientError.unconfigured("Unavailable.")
        }
        let token = try await authorizedAccessToken()
        return try await api.latestManifest(
            accessToken: token,
            appVersion: Bundle.main.clientAppVersion,
            appBuild: Bundle.main.clientAppBuild
        )
    }

    func downloadContentPackage(at url: URL) async throws -> Data {
        guard let api else {
            throw LicenseClientError.unconfigured("Unavailable.")
        }
        let token = try await authorizedAccessToken()
        return try await api.downloadPackage(
            at: url,
            accessToken: token,
            maximumBytes: 8 * 1_024 * 1_024
        )
    }

    var manifestPublicKey: Data? {
        configuration?.manifestPublicKey
    }

    var serverBaseURL: URL? {
        configuration?.serverBaseURL
    }

    private func validateStoredSession() async {
        if let validationTask {
            await validationTask.value
            return
        }
        let task = Task { @MainActor in
            await self.performStoredSessionValidation()
        }
        validationTask = task
        await task.value
        validationTask = nil
    }

    private func performStoredSessionValidation() async {
        guard let api, let current = credentials else { return }
        let generation = sessionGeneration
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            let validated = try await prove(
                credential: current.accessToken,
                type: "access",
                api: api,
                refresh: false
            )
            guard generation == sessionGeneration else { return }
            try await finishAuthorization(credentials: validated)
        } catch LicenseClientError.unauthorized {
            guard generation == sessionGeneration else { return }
            do {
                let refreshed = try await prove(
                    credential: current.refreshToken,
                    type: "refresh",
                    api: api,
                    refresh: true
                )
                guard generation == sessionGeneration else { return }
                try await finishAuthorization(credentials: refreshed)
            } catch LicenseClientError.unauthorized {
                guard generation == sessionGeneration else { return }
                logout()
                errorMessage = LicenseClientError.unauthorized.localizedDescription
            } catch {
                guard generation == sessionGeneration else { return }
                state = .blocked(error.localizedDescription)
            }
        } catch {
            guard generation == sessionGeneration else { return }
            state = .blocked(error.localizedDescription)
        }
    }

    private func prove(
        credential: String,
        type: String,
        api: AccessChannel,
        refresh: Bool
    ) async throws -> LicenseCredentials {
        let installationID = try identity.installationID()
        let challenge = try await api.proofChallenge(
            credential: credential,
            type: type,
            installationID: installationID
        )
        guard !challenge.challengeID.isEmpty else {
            throw LicenseClientError.invalidChallenge
        }
        let request = ProofRequest(
            installationID: installationID,
            challengeID: challenge.challengeID,
            proofSignature: try identity.sign(base64Challenge: challenge.challenge)
        )
        if refresh {
            return try await api.refreshSession(refreshToken: credential, request: request)
        }
        return try await api.validateSession(accessToken: credential, request: request)
    }

    private func finishAuthorization(credentials: LicenseCredentials) async throws {
        guard !credentials.accessToken.isEmpty,
              credentials.accessToken.utf8.count <= 8_192,
              !credentials.refreshToken.isEmpty,
              credentials.refreshToken.utf8.count <= 8_192,
              !credentials.profile.licenseID.isEmpty,
              credentials.profile.licenseID.utf8.count <= 512,
              (credentials.profile.maskedKey?.utf8.count ?? 0) <= 512,
              credentials.profile.expiresAt.utf8.count <= 128,
              credentials.profile.registeredDevice.utf8.count <= 256,
              (credentials.profile.udid?.utf8.count ?? 0) <= 512 else {
            throw LicenseClientError.invalidResponse
        }
        try saveSecureValue(credentials, account: credentialsAccount)
        VaultBox.delete(account: pendingAccount)
        VaultBox.delete(account: legacyPendingAccount)
        self.credentials = credentials
        profile = credentials.profile
        pendingActivation = nil
        state = .authenticated
        do {
            try await attachLease()
            errorMessage = nil
        } catch {
            errorMessage = "Finishing activation. Keep the app open."
        }
        startPulse()
    }

    private func attachLease() async throws {
        guard let api, let current = credentials else {
            throw LicenseClientError.unauthorized
        }
        let lease = try await api.issueLease(accessToken: current.accessToken)
        guard !lease.lease.isEmpty,
              lease.lease.utf8.count <= 256,
              let until = Self.parseDate(lease.expiresAt),
              until.timeIntervalSinceNow > 15 else {
            throw LicenseClientError.unauthorized
        }
        let capped = min(until, Date().addingTimeInterval(90))
        let host = configuration?.serverBaseURL.host ?? ""
        workspaceUnlocked = RuntimePermit.bind(
            token: current.accessToken,
            licenseID: current.profile.licenseID,
            installationID: try identity.installationID(),
            host: host,
            lease: lease.lease,
            until: capped
        )
        authorityRevision += 1
        guard workspaceUnlocked else {
            throw LicenseClientError.unauthorized
        }
    }

    private func startPulse() {
        pulseTask?.cancel()
        let generation = sessionGeneration
        pulseTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 40_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.pulseIfNeeded(generation: generation)
            }
        }
    }

    private func pulseIfNeeded(generation: Int) async {
        guard generation == sessionGeneration,
              credentials != nil,
              {
                  if case .authenticated = state { return true }
                  if case .blocked = state { return true }
                  return false
              }() else { return }
        await renewAuthorityIfNeeded()
    }

    func authorizeWrite(packageID: UUID, packageData: Data, apply: Bool) async throws {
        let generation = sessionGeneration
        try await requireOperationLease()
        guard let api else { throw LicenseClientError.unauthorized }
        let token = try await authorizedAccessToken()
        guard generation == sessionGeneration else { throw LicenseClientError.unauthorized }
        let requestID = UUID().uuidString.lowercased()
        let startedAt = ContinuousClock.now
        let digest = CatalogTrust.sha256Hex(packageData)
        let envelope = try await api.issueWritePermit(
            accessToken: token,
            request: WritePermitRequest(
                requestID: requestID,
                packageID: packageID.uuidString.lowercased(),
                sha256: digest,
                action: apply ? "apply" : "restore",
                appVersion: Bundle.main.clientAppVersion,
                appBuild: Bundle.main.clientAppBuild
            )
        )
        try Task.checkCancellation()
        guard generation == sessionGeneration,
              startedAt.duration(to: .now) < .seconds(25) else {
            throw LicenseClientError.unauthorized
        }
        try verifyWritePermit(
            envelope,
            requestID: requestID,
            packageID: packageID,
            sha256: digest,
            apply: apply
        )
        guard hasLiveAuthority else {
            throw LicenseClientError.unauthorized
        }
    }

    private func verifyWritePermit(
        _ envelope: SignedWritePermit,
        requestID: String,
        packageID: UUID,
        sha256: String,
        apply: Bool
    ) throws {
        guard let publicKey = configuration?.manifestPublicKey,
              let permitData = Data(base64Encoded: envelope.permitBase64),
              permitData.count <= 8_192,
              let signature = Data(base64Encoded: envelope.signature),
              signature.count == 64 else {
            throw LicenseClientError.unauthorized
        }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        guard key.isValidSignature(signature, for: permitData),
              let permit = try? JSONDecoder().decode(WritePermit.self, from: permitData) else {
            throw LicenseClientError.unauthorized
        }
        let expires = Self.parseDate(permit.expiresAt)
        guard permit.scope == "write",
              permit.requestID == requestID,
              permit.packageID == packageID.uuidString.lowercased(),
              permit.sha256 == sha256,
              permit.action == (apply ? "apply" : "restore"),
              permit.installationID == (try identity.installationID()),
              permit.appVersion == Bundle.main.clientAppVersion,
              permit.appBuild == Bundle.main.clientAppBuild,
              let expires,
              expires.timeIntervalSinceNow > 1,
              expires.timeIntervalSinceNow < 180 else {
            throw LicenseClientError.unauthorized
        }
    }

    private func saveSecureValue<Value: Encodable>(
        _ value: Value,
        account: String
    ) throws {
        let plain = try JSONEncoder().encode(value)
        let packed = try RuntimePermit.wrap(
            plain,
            installationID: try identity.installationID(),
            publicKey: try identity.publicKeyBase64()
        )
        try VaultBox.write(packed, account: account)
    }

    private func loadSecureValue<Value: Decodable>(account: String) throws -> Value? {
        if let value: Value = try decodeSecureValue(account: account) {
            return value
        }
        if account == credentialsAccount {
            return try decodeSecureValue(account: legacyCredentialsAccount)
        }
        if account == pendingAccount {
            return try decodeSecureValue(account: legacyPendingAccount)
        }
        return nil
    }

    private func decodeSecureValue<Value: Decodable>(account: String) throws -> Value? {
        guard let data = try VaultBox.read(account: account) else { return nil }
        do {
            let plain = try RuntimePermit.unwrap(
                data,
                installationID: try identity.installationID(),
                publicKey: try identity.publicKeyBase64()
            )
            return try JSONDecoder().decode(Value.self, from: plain)
        } catch {
            // Temporary Keychain/identity failures must not erase a pending activation.
            // Keep the saved bytes for retry; only explicit logout removes them.
            throw LicenseClientError.keychain
        }
    }

    private static func hardwareModel() -> String {
        var info = utsname()
        uname(&info)
        let bytes = withUnsafeBytes(of: &info.machine) { rawBuffer in
            rawBuffer.prefix { $0 != 0 }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func tokenNeedsRefresh(_ value: String) -> Bool {
        guard let date = parseDate(value) else { return true }
        return date.timeIntervalSinceNow < 30
    }

    private static func friendlyLicenseMessage(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if text.isEmpty
            || lower.contains("too small")
            || lower.contains("too big")
            || lower.contains("expected")
            || lower.contains("invalid string")
            || lower.contains("invalid type")
            || lower.contains("required")
            || lower.contains("invalid request")
            || lower.contains("enter a valid")
            || lower.contains("invalid license") {
            return "Invalid License"
        }
        return text
    }
}
