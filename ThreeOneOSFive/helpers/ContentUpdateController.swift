import Combine
import CryptoKit
import Foundation

struct ContentFunctionMetadata: Codable, Equatable {
    let name: String
    let description: String
    let icon: String?
    let game: String?
    let sort: Int?

    init(
        name: String,
        description: String,
        icon: String? = nil,
        game: String? = nil,
        sort: Int? = nil
    ) {
        self.name = name
        self.description = description
        self.icon = icon
        self.game = game
        self.sort = sort
    }

    var gameSlug: String {
        let raw = (game ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        if raw.isEmpty || raw == "free-fire" || raw == "freefire" {
            return "free-fire"
        }
        if raw == "free-fire-max" || raw == "max" || raw == "freefiremax" {
            return "free-fire-max"
        }
        return raw
    }
}

enum ContentFunctionMetadataStore {
    private static let storageKey = "vita.content.function-metadata.v1"

    static func metadata(for packageID: UUID) -> ContentFunctionMetadata? {
        records()[packageID.uuidString]
    }

    static func save(_ metadata: ContentFunctionMetadata, for packageID: UUID) {
        var values = records()
        values[packageID.uuidString] = metadata
        guard let data = try? JSONEncoder().encode(values) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func isManaged(_ packageID: UUID) -> Bool {
        records()[packageID.uuidString] != nil
    }

    static func remove(_ packageID: UUID) {
        var values = records()
        values.removeValue(forKey: packageID.uuidString)
        if values.isEmpty {
            UserDefaults.standard.removeObject(forKey: storageKey)
        } else if let data = try? JSONEncoder().encode(values) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private static func records() -> [String: ContentFunctionMetadata] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let values = try? JSONDecoder().decode(
                [String: ContentFunctionMetadata].self,
                from: data
              ) else {
            return [:]
        }
        return values
    }
}

@MainActor
final class ContentUpdateController: ObservableObject {
    @Published var requiredRelease: ContentReleaseManifest? = nil
    @Published private(set) var isChecking = false
    @Published private(set) var isInstalling = false
    @Published var errorMessage: String?
    @Published private(set) var lastInstalledVersion: String?
    @Published private(set) var games: [ContentGameDescriptor]
    @Published private(set) var hasVerifiedPolicy = false
    @Published private(set) var integrityCompromised = false

    private static let pendingRequiredKey = "vita.content.pending-required.v1"
    private static let gamesKey = "robo.content.games.v1"
    private var lastCheckAt: Date?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.pendingRequiredKey) {
            requiredRelease = try? JSONDecoder().decode(
                ContentReleaseManifest.self,
                from: data
            )
        }
        if let data = UserDefaults.standard.data(forKey: Self.gamesKey),
           let saved = try? JSONDecoder().decode([ContentGameDescriptor].self, from: data),
           !saved.isEmpty {
            games = saved
        } else {
            games = ContentGameDescriptor.defaults
        }
    }

    func checkForUpdates(
        session: LicenseSessionController,
        store: PatchProjectStore
    ) async {
        guard !isChecking, !isInstalling else { return }
        if let lastCheckAt, Date().timeIntervalSince(lastCheckAt) < 5 { return }
        lastCheckAt = Date()
        isChecking = true
        defer { isChecking = false }

        do {
            try await session.requireOperationLease()
            guard let envelope = try await session.fetchLatestManifest() else {
                clearLocalFunctions(store)
                setRequiredRelease(nil)
                hasVerifiedPolicy = true
                return
            }
            if let remoteGames = envelope.games, !remoteGames.isEmpty {
                saveGames(remoteGames)
            }
            let manifest = try verify(
                envelope: envelope,
                publicKey: session.manifestPublicKey
            )
            guard !isInstalled(manifest) else {
                if requiredRelease?.releaseID == manifest.releaseID {
                    setRequiredRelease(nil)
                }
                hasVerifiedPolicy = true
                lastInstalledVersion = manifest.version
                store.reload()
                return
            }
            if manifest.required {
                setRequiredRelease(manifest)
            } else {
                try await install(manifest, session: session, store: store)
            }
            CatalogTrust.reconcileLocalCatalog()
            hasVerifiedPolicy = true
        } catch let error as LicenseClientError {
            hasVerifiedPolicy = false
            lastCheckAt = nil
            switch error {
            case .manifestInvalid:
                integrityCompromised = true
                errorMessage = error.localizedDescription
                RuntimeGuard.rejectTamper()
            default:
                errorMessage = error.localizedDescription
            }
        } catch {
            hasVerifiedPolicy = false
            lastCheckAt = nil
            errorMessage = error.localizedDescription
        }
    }

    private func saveGames(_ values: [ContentGameDescriptor]) {
        let cleaned = values.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.bundleID.isEmpty }
        guard !cleaned.isEmpty else { return }
        games = cleaned
        if let data = try? JSONEncoder().encode(cleaned) {
            UserDefaults.standard.set(data, forKey: Self.gamesKey)
        }
    }

    private func clearLocalFunctions(_ store: PatchProjectStore) {
        let items = (try? PatchProjectLibrary.loadAvailable()) ?? []
        for item in items where DevicePatchService.latestReceipt(projectID: item.id) == nil {
            try? PatchProjectLibrary.delete(item)
            ContentFunctionMetadataStore.remove(item.id)
        }
        store.reload()
    }

    func installRequired(
        session: LicenseSessionController,
        store: PatchProjectStore
    ) async {
        guard let release = requiredRelease else { return }
        do {
            try await install(release, session: session, store: store)
            setRequiredRelease(nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func install(
        _ manifest: ContentReleaseManifest,
        session: LicenseSessionController,
        store: PatchProjectStore
    ) async throws {
        guard !isInstalling else { return }
        isInstalling = true
        errorMessage = nil
        defer { isInstalling = false }

        try await session.requireOperationLease()
        guard let baseURL = session.serverBaseURL else {
            throw LicenseClientError.unconfigured("Unavailable.")
        }

        var verifiedPackages: [(Data, ContentPackageDescriptor, UUID)] = []
        for package in manifest.packages {
            guard let packageURL = URL(string: package.url, relativeTo: baseURL)?.absoluteURL else {
                throw LicenseClientError.packageInvalid(package.fileName)
            }
            let data = try await session.downloadContentPackage(at: packageURL)
            guard package.size.map({ $0 == data.count }) ?? true,
                  Self.sha256Hex(data) == package.sha256.lowercased() else {
                throw LicenseClientError.packageInvalid(package.fileName)
            }
            do {
                _ = try PatchPackageCodec.inspect(data)
                let decoded = try PatchPackageCodec.decode(data, password: nil)
                verifiedPackages.append((data, package, decoded.project.id))
            } catch {
                throw LicenseClientError.packageInvalid(package.fileName)
            }
        }

        let incomingPackageIDs = Set(verifiedPackages.map { $0.2 })
        guard incomingPackageIDs.count == verifiedPackages.count else {
            throw LicenseClientError.packageInvalid("Duplicate function IDs in this release")
        }
        let previousItems = try PatchProjectLibrary.loadAvailable()

        for (data, package, packageID) in verifiedPackages {
            do {
                try PatchProjectLibrary.installVerifiedContentPackage(data)
                if let name = package.name?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ), !name.isEmpty {
                    ContentFunctionMetadataStore.save(
                        ContentFunctionMetadata(
                            name: name,
                            description: package.description?
                                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                            icon: package.icon?.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ),
                            game: package.game?.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ),
                            sort: package.sort
                        ),
                        for: packageID
                    )
                }
            } catch {
                throw LicenseClientError.packageInvalid(package.fileName)
            }
        }
        // A marker alone must never make a partial installation look complete.
        guard hasAllPackages(manifest) else {
            throw LicenseClientError.packageInvalid("The update is incomplete. Please retry.")
        }
        try markInstalled(manifest)
        // Remove retired functions only after every incoming file is installed.
        // Keep active functions and their restore backups.
        for item in previousItems
        where ContentFunctionMetadataStore.isManaged(item.id)
            && !incomingPackageIDs.contains(item.id)
            && DevicePatchService.latestReceipt(projectID: item.id) == nil {
            do {
                try PatchProjectLibrary.delete(item)
                ContentFunctionMetadataStore.remove(item.id)
            } catch {
                log("vita: retired function cleanup deferred")
            }
        }
        lastInstalledVersion = manifest.version
        store.reload()
    }

    private func verify(
        envelope: SignedManifestEnvelope,
        publicKey: Data?
    ) throws -> ContentReleaseManifest {
        guard let publicKey,
              let manifestData = Data(base64Encoded: envelope.manifestBase64),
              manifestData.count <= 1_048_576,
              let signature = Self.decodeBase64(envelope.signature),
              signature.count == 64 else {
            throw LicenseClientError.invalidResponse
        }
        let key: Curve25519.Signing.PublicKey
        do {
            key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        } catch {
            throw LicenseClientError.invalidResponse
        }
        guard key.isValidSignature(signature, for: manifestData) else {
            throw LicenseClientError.manifestInvalid
        }
        guard let manifest = try? JSONDecoder().decode(
            ContentReleaseManifest.self,
            from: manifestData
        ) else {
            throw LicenseClientError.manifestInvalid
        }
        try validate(manifest)
        return manifest
    }

    private func validate(_ manifest: ContentReleaseManifest) throws {
        guard manifest.product == "vita-mod-vip",
              !manifest.releaseID.isEmpty,
              manifest.releaseID.utf8.count <= 128,
              !manifest.releaseID.unicodeScalars.contains(
                where: CharacterSet.controlCharacters.contains
              ),
              !manifest.version.isEmpty,
              manifest.version.utf8.count <= 64,
              (manifest.name?.utf8.count ?? 0) <= 120,
              (manifest.description?.utf8.count ?? 0) <= 1_000,
              (1...24).contains(manifest.packages.count) else {
            throw LicenseClientError.manifestInvalid
        }

        var identifiers = Set<String>()
        for package in manifest.packages {
            let fileName = package.fileName
            guard !package.identifier.isEmpty,
                  identifiers.insert(package.identifier).inserted,
                  CatalogTrust.isOpaqueCatalogName(fileName),
                  package.sha256.count == 64,
                  package.sha256.unicodeScalars.allSatisfy(Self.isHex),
                  (package.name?.utf8.count ?? 0) <= 120,
                  (package.description?.utf8.count ?? 0) <= 500,
                  (package.icon?.utf8.count ?? 0) <= 32,
                  package.size.map({
                      $0 > 0 && $0 <= 32 * 1_024 * 1_024
                  }) ?? true,
                  !package.url.isEmpty else {
                throw LicenseClientError.manifestInvalid
            }
        }
    }

    private func isInstalled(_ manifest: ContentReleaseManifest) -> Bool {
        guard let url = try? markerURL(for: manifest.releaseID) else { return false }
        return FileManager.default.fileExists(atPath: url.path) && hasAllPackages(manifest)
    }

    private func hasAllPackages(_ manifest: ContentReleaseManifest) -> Bool {
        PatchProjectLibrary.containsCompleteRelease(
            expectedHashes: manifest.packages.map(\.sha256)
        )
    }

    private func markInstalled(_ manifest: ContentReleaseManifest) throws {
        let marker = try markerURL(for: manifest.releaseID)
        let record = try JSONEncoder().encode(manifest)
        try record.write(to: marker, options: [.atomic, .completeFileProtection])
    }

    private func setRequiredRelease(_ release: ContentReleaseManifest?) {
        requiredRelease = release
        if let release, let data = try? JSONEncoder().encode(release) {
            UserDefaults.standard.set(data, forKey: Self.pendingRequiredKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.pendingRequiredKey)
        }
    }

    private func markerURL(for releaseID: String) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("VitaMods", isDirectory: true)
            .appendingPathComponent("ContentReleases", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let digest = Self.sha256Hex(Data(releaseID.utf8))
        return directory.appendingPathComponent(digest).appendingPathExtension("json")
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isHex(_ scalar: UnicodeScalar) -> Bool {
        (48...57).contains(scalar.value)
            || (65...70).contains(scalar.value)
            || (97...102).contains(scalar.value)
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
