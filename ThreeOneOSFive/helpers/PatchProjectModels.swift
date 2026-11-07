import Foundation

struct PatchRule: Codable, Identifiable, Hashable {
    var id: UUID
    var bundleID: String
    var relativePath: String
    var replacementFilename: String
    var replacementData: Data
    var containerKind: String?
    var operation: String?

    init(
        id: UUID = UUID(),
        bundleID: String,
        relativePath: String,
        replacementFilename: String,
        replacementData: Data,
        containerKind: String? = nil,
        operation: String? = nil
    ) {
        self.id = id
        self.bundleID = bundleID
        self.relativePath = relativePath
        self.replacementFilename = replacementFilename
        self.replacementData = replacementData
        self.containerKind = containerKind
        self.operation = operation
    }

    var resolvedContainerKind: String {
        containerKind ?? "application"
    }

    var resolvedOperation: String {
        operation ?? "replace"
    }

    var writesFilePayload: Bool {
        ["replace", "merge_json", "merge_plist"].contains(resolvedOperation)
    }

    var appliesToApplicationContainer: Bool {
        resolvedContainerKind == "application" && writesFilePayload
    }

    /// A zero-byte file is a valid replacement; the filename records that the
    /// user explicitly supplied a payload for this path-only draft rule.
    var hasReplacement: Bool {
        !replacementFilename.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case bundleID
        case relativePath
        case replacementFilename
        case replacementData
        case containerKind
        case operation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        replacementFilename = try container.decodeIfPresent(String.self, forKey: .replacementFilename) ?? ""
        replacementData = try container.decodeIfPresent(Data.self, forKey: .replacementData) ?? Data()
        containerKind = try container.decodeIfPresent(String.self, forKey: .containerKind)
        operation = try container.decodeIfPresent(String.self, forKey: .operation)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(bundleID, forKey: .bundleID)
        try container.encode(relativePath, forKey: .relativePath)
        try container.encode(replacementFilename, forKey: .replacementFilename)
        try container.encode(replacementData, forKey: .replacementData)
        try container.encodeIfPresent(containerKind, forKey: .containerKind)
        try container.encodeIfPresent(operation, forKey: .operation)
    }
}

struct PatchDirectory: Codable, Identifiable, Hashable {
    var id: UUID
    var bundleID: String
    var relativePath: String
    var containerKind: String?

    init(
        id: UUID = UUID(),
        bundleID: String,
        relativePath: String,
        containerKind: String? = nil
    ) {
        self.id = id
        self.bundleID = bundleID
        self.relativePath = relativePath
        self.containerKind = containerKind
    }

    var resolvedContainerKind: String {
        containerKind ?? "application"
    }
}

struct PatchContainerTarget: Hashable {
    var identifier: String
    var kind: String
}

struct PatchProject: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var author: String
    var isPrivate: Bool
    var createdAt: Date
    var updatedAt: Date
    var bundleIdentifiers: [String]
    var directories: [PatchDirectory]
    var rules: [PatchRule]
    var settingsDefaults: [String: String] = [:]

    init(
        id: UUID = UUID(),
        name: String,
        author: String = "",
        isPrivate: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        bundleIdentifiers: [String] = [],
        directories: [PatchDirectory] = [],
        rules: [PatchRule]
    ) {
        self.id = id
        self.name = name
        self.author = author
        self.isPrivate = isPrivate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.bundleIdentifiers = bundleIdentifiers
        self.directories = directories
        self.rules = rules
    }

    var allBundleIdentifiers: [String] {
        var seen = Set<String>()
        return (bundleIdentifiers + directories.map(\.bundleID) + rules.map(\.bundleID))
            .filter { seen.insert($0).inserted }
    }

    var containerTargets: [PatchContainerTarget] {
        var seen = Set<PatchContainerTarget>()
        var result: [PatchContainerTarget] = []
        func add(_ identifier: String, _ kind: String) {
            let target = PatchContainerTarget(identifier: identifier, kind: kind)
            if seen.insert(target).inserted {
                result.append(target)
            }
        }
        for directory in directories {
            add(directory.bundleID, directory.resolvedContainerKind)
        }
        for rule in rules where rule.writesFilePayload {
            add(rule.bundleID, rule.resolvedContainerKind)
        }
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case author
        case isPrivate
        case createdAt
        case updatedAt
        case bundleIdentifiers
        case directories
        case rules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        author = try container.decodeIfPresent(String.self, forKey: .author) ?? ""
        isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        bundleIdentifiers = try container.decodeIfPresent(
            [String].self,
            forKey: .bundleIdentifiers
        ) ?? []
        directories = try container.decodeIfPresent(
            [PatchDirectory].self,
            forKey: .directories
        ) ?? []
        rules = try container.decodeIfPresent([PatchRule].self, forKey: .rules) ?? []
        settingsDefaults = [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(author, forKey: .author)
        try container.encode(isPrivate, forKey: .isPrivate)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(bundleIdentifiers, forKey: .bundleIdentifiers)
        try container.encode(directories, forKey: .directories)
        try container.encode(rules, forKey: .rules)
    }
}

enum PatchProjectAccessPolicy {
    static func canInspectContents(
        project: PatchProject,
        isAuthorCopy: Bool
    ) -> Bool {
        !project.isPrivate || isAuthorCopy
    }

    static func shouldMaterializeWorkspace(
        project: PatchProject,
        isAuthorCopy: Bool
    ) -> Bool {
        _ = project
        _ = isAuthorCopy
        return false
    }
}

struct PatchPackageSummary: Equatable, Identifiable {
    var id: UUID { packageID }
    let packageID: UUID
    let schemaVersion: Int
    let isPasswordProtected: Bool
    let keyFingerprint: Data
}

struct PatchPackageOrigin: Codable, Equatable, Hashable {
    let repositoryName: String
    let repositoryURL: URL
    let packageIdentifier: String
}

struct EncodedPatchPackage {
    let data: Data
    let contentKey: Data
}

struct DecodedPatchPackage {
    let project: PatchProject
    let contentKey: Data
}

enum PatchPackageError: Error, Equatable {
    case unsupportedFormat
    case unsupportedVersion
    case invalidPasswordOrCorruptedPackage
    case invalidBundleIdentifier
    case unsafeTargetPath
    case sizeLimitExceeded
    case duplicateTarget
    case invalidProject
    case keychainFailed
    case targetAppUnavailable(String)
    case symbolicLinkUnsupported
    case targetOccupied(String)
    case projectAlreadyApplied
    case restoreTargetsChanged([String])
    case activePatchCannotBeDeleted
    case privatePatchRequiresPassword
    case privateOperationFailed
    case applyFailed
    case restoreFailed
    case resetFailed
    case recoveryRequired
    case invalidImportLink
    case remoteImportFailed
}

extension PatchPackageError: LocalizedError {
    var localizationKey: String {
        switch self {
        case .unsupportedFormat: return "patch.error.unsupported_format"
        case .unsupportedVersion: return "patch.error.unsupported_version"
        case .invalidPasswordOrCorruptedPackage: return "patch.error.password_or_corrupt"
        case .invalidBundleIdentifier: return "patch.error.invalid_bundle"
        case .unsafeTargetPath: return "patch.error.unsafe_path"
        case .sizeLimitExceeded: return "patch.error.size_limit"
        case .duplicateTarget: return "patch.error.duplicate_target"
        case .invalidProject: return "patch.error.invalid_project"
        case .keychainFailed: return "patch.error.keychain"
        case .targetAppUnavailable: return "patch.error.app_unavailable"
        case .targetOccupied: return "patch.error.target_occupied"
        case .projectAlreadyApplied: return "patch.error.already_applied"
        case .restoreTargetsChanged: return "patch.error.restore_targets_changed"
        case .activePatchCannotBeDeleted: return "patch.error.active_delete"
        case .symbolicLinkUnsupported: return "patch.error.symlink"
        case .privatePatchRequiresPassword: return "patch.error.private_password"
        case .privateOperationFailed: return "patch.error.private_operation"
        case .applyFailed: return "patch.error.apply"
        case .restoreFailed: return "patch.error.restore"
        case .resetFailed: return "patch.error.reset"
        case .recoveryRequired: return "patch.error.recovery_required"
        case .invalidImportLink: return "patch.error.invalid_import_link"
        case .remoteImportFailed: return "patch.error.remote_import"
        }
    }

    var errorDescription: String? {
        if self == .recoveryRequired {
            return "Recovery could not finish. Your backups were kept. Do not delete the app or its data. Retry Restore when file access is available."
        }
        let message = String(localized: String.LocalizationValue(localizationKey))
        if let localizationArgument {
            return String(format: message, localizationArgument)
        }
        return message
    }

    var localizationArgument: String? {
        switch self {
        case .targetOccupied(let bundleID):
            return bundleID
        case .restoreTargetsChanged(let paths):
            return paths.joined(separator: "\n")
        default:
            return nil
        }
    }
}

enum PatchPackageLimits {
    static let maximumPathBytes = 4_096
    static let maximumAuthorBytes = 160
    static let maximumPasswordBytes = 1_024
    static let maximumPackageBytes = 128 * 1_024 * 1_024
    static let minimumKDFIterations = 100_000
    static let defaultKDFIterations = 250_000
    static let maximumKDFIterations = 1_000_000
}

enum PatchPathValidator {
    private static let applicationRoot = "/private/var/mobile/Containers/Data/Application"

    static func canonicalBundleIdentifier(_ rawValue: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= 255,
              UUID(uuidString: value) == nil,
              !value.contains("/"),
              !value.contains("\\"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw PatchPackageError.invalidBundleIdentifier
        }

        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2 else {
            throw PatchPackageError.invalidBundleIdentifier
        }

        for component in components {
            guard !component.isEmpty,
                  component.unicodeScalars.allSatisfy({ scalar in
                      let value = scalar.value
                      return (48...57).contains(value)
                          || (65...90).contains(value)
                          || (97...122).contains(value)
                          || value == 45
                          || value == 95
                  }),
                  component.first != "-",
                  component.last != "-"
            else {
                throw PatchPackageError.invalidBundleIdentifier
            }
        }
        return value
    }

    static func canonicalRelativePath(_ rawValue: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= PatchPackageLimits.maximumPathBytes,
              !value.hasPrefix("/"),
              !value.contains("\\"),
              !value.contains("//"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw PatchPackageError.unsafeTargetPath
        }

        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw PatchPackageError.unsafeTargetPath
        }
        return components.joined(separator: "/")
    }

    static func resolveTargetURL(
        bundleID: String,
        relativePath: String,
        containerRoot: URL
    ) throws -> URL {
        _ = try canonicalBundleIdentifier(bundleID)
        let path = try canonicalRelativePath(relativePath)
        let root = canonicalFileURL(containerRoot)

        guard root.deletingLastPathComponent().path == applicationRoot,
              UUID(uuidString: root.lastPathComponent) != nil
        else {
            throw PatchPackageError.unsafeTargetPath
        }

        return try resolveContainedTargetURL(relativePath: path, containerRoot: root)
    }

    static func resolveContainedTargetURL(relativePath: String, containerRoot: URL) throws -> URL {
        let path = try canonicalRelativePath(relativePath)
        let root = canonicalFileURL(containerRoot)
        let target = root.appendingPathComponent(path, isDirectory: false).standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else {
            throw PatchPackageError.unsafeTargetPath
        }
        return target
    }

    static func canonicalFileURL(_ url: URL) -> URL {
        var path = url.standardizedFileURL.path
        if path == "/var" || path.hasPrefix("/var/") {
            path = "/private" + path
        }
        return URL(fileURLWithPath: path, isDirectory: url.hasDirectoryPath).standardizedFileURL
    }
}
