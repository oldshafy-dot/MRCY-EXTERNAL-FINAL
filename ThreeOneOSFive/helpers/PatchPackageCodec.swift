import CryptoKit
import Foundation
import Security

enum PatchPackageCodec {
    static let latestSchemaVersion = 1
    private static let packVersion: UInt32 = 1
    private static let magic = Data([0xC3, 0x1E, 0x9A, 0x47, 0xB2, 0x08, 0x6D, 0xF1])
    private static let bannedMasks: [[UInt8]] = [
        [0x69, 0x6B, 0x6A, 0x6F, 0x0A, 0x1B, 0x0E, 0x19, 0x12],
        [0x0C, 0x13, 0x0E, 0x1B, 0x0A, 0x1B, 0x0E, 0x19, 0x12],
        [0x1D, 0x15, 0x10, 0x15, 0x0A, 0x1B, 0x0E, 0x19, 0x12],
        [0x0C, 0x13, 0x0E, 0x1B, 0x0A, 0x1C, 0x6A, 0x6B],
        [0x1D, 0x15, 0x10, 0x15, 0x0A, 0x1C, 0x6A, 0x6B]
    ]
    private static let kinds = ["application", "appGroup", "systemAppGroup"]
    private static let operations = ["replace", "merge_json", "merge_plist"]

    static func encodeNew(
        project: PatchProject,
        password: String?,
        kdfIterations: Int = PatchPackageLimits.defaultKDFIterations
    ) throws -> EncodedPatchPackage {
        _ = password
        _ = kdfIterations
        try validate(project)
        let inner = try encodeInner(project)
        let salt = try randomData(count: 16)
        let nonce = try randomData(count: 12)
        let key = try fileKey(salt: salt)
        var aad = Data()
        aad.append(magic)
        aad.append(contentsOf: u32(packVersion))
        aad.append(contentsOf: u32(0))
        aad.append(salt)
        let sealed = try AES.GCM.seal(
            inner,
            using: SymmetricKey(data: key),
            nonce: try AES.GCM.Nonce(data: nonce),
            authenticating: aad
        )
        var packed = Data()
        packed.append(magic)
        packed.append(contentsOf: u32(packVersion))
        packed.append(contentsOf: u32(0))
        packed.append(salt)
        packed.append(nonce)
        packed.append(sealed.ciphertext)
        packed.append(sealed.tag)
        return EncodedPatchPackage(data: packed, contentKey: key)
    }

    static func inspect(_ data: Data) throws -> PatchPackageSummary {
        let decoded = try decode(data, password: nil)
        return PatchPackageSummary(
            packageID: decoded.project.id,
            schemaVersion: latestSchemaVersion,
            isPasswordProtected: false,
            keyFingerprint: Data(SHA256.hash(data: decoded.contentKey))
        )
    }

    static func decode(_ data: Data, password: String?) throws -> DecodedPatchPackage {
        _ = password
        return try openPack(data)
    }

    static func decode(_ data: Data, contentKey: Data) throws -> DecodedPatchPackage {
        _ = contentKey
        return try openPack(data)
    }

    static func update(
        _ originalData: Data,
        project: PatchProject,
        contentKey: Data,
        schemaVersion requestedSchemaVersion: Int? = nil
    ) throws -> Data {
        _ = contentKey
        _ = requestedSchemaVersion
        let existing = try openPack(originalData)
        guard existing.project.id == project.id else {
            throw PatchPackageError.invalidPasswordOrCorruptedPackage
        }
        return try encodeNew(project: project, password: nil).data
    }

    static func validate(_ project: PatchProject) throws {
        let name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = project.author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name.utf8.count <= 120,
              author == project.author,
              author.utf8.count <= PatchPackageLimits.maximumAuthorBytes,
              !author.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !project.allBundleIdentifiers.isEmpty else {
            throw PatchPackageError.invalidProject
        }
        var bundles = Set<String>()
        for suppliedBundleID in project.bundleIdentifiers {
            let bundleID = try PatchPathValidator.canonicalBundleIdentifier(suppliedBundleID)
            guard bundleID == suppliedBundleID,
                  bundles.insert(bundleID).inserted else {
                throw PatchPackageError.invalidProject
            }
        }
        var targets = Set<String>()
        var ruleIDs = Set<UUID>()
        var directoryIDs = Set<UUID>()
        var directoryTargets = Set<String>()
        for directory in project.directories {
            let bundleID = try PatchPathValidator.canonicalBundleIdentifier(directory.bundleID)
            let relativePath = try PatchPathValidator.canonicalRelativePath(directory.relativePath)
            guard bundleID == directory.bundleID,
                  relativePath == directory.relativePath,
                  directoryIDs.insert(directory.id).inserted else {
                throw PatchPackageError.invalidProject
            }
            if !bundles.isEmpty,
               directory.resolvedContainerKind == "application",
               !bundles.contains(bundleID) {
                throw PatchPackageError.invalidProject
            }
            let targetKey = directory.resolvedContainerKind + "\0" + bundleID + "\0" + relativePath
            guard directoryTargets.insert(targetKey).inserted else {
                throw PatchPackageError.duplicateTarget
            }
        }
        for rule in project.rules {
            let bundleID = try PatchPathValidator.canonicalBundleIdentifier(rule.bundleID)
            let relativePath = try PatchPathValidator.canonicalRelativePath(rule.relativePath)
            guard bundleID == rule.bundleID,
                  relativePath == rule.relativePath,
                  ruleIDs.insert(rule.id).inserted
            else {
                throw PatchPackageError.invalidProject
            }
            if !bundles.isEmpty,
               rule.resolvedContainerKind == "application",
               !bundles.contains(bundleID) {
                throw PatchPackageError.invalidProject
            }
            guard rule.writesFilePayload else { continue }
            guard !rule.replacementFilename.isEmpty,
                  rule.replacementFilename.utf8.count <= 255,
                  !rule.replacementFilename.contains("/"),
                  !rule.replacementFilename.contains("\\"),
                  !rule.replacementFilename.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else {
                throw PatchPackageError.invalidProject
            }
            let targetKey = rule.resolvedContainerKind + "\0" + bundleID + "\0" + relativePath
            guard targets.insert(targetKey).inserted,
                  !directoryTargets.contains(targetKey) else {
                throw PatchPackageError.duplicateTarget
            }
        }
    }

    static func opaqueFilename(for packageID: UUID) -> String {
        let digest = SHA256.hash(
            data: Data([
                0x2C, 0x3C, 0x34, 0x22, 0x74, 0x34, 0x3B, 0x37, 0x3F, 0x74, 0x68,
            ].map { $0 ^ 0x5A }) + Data(packageID.uuidString.lowercased().utf8)
        )
        return digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    private static func openPack(_ data: Data) throws -> DecodedPatchPackage {
        try rejectForeignMarkers(data)
        guard data.count <= PatchPackageLimits.maximumPackageBytes else {
            throw PatchPackageError.sizeLimitExceeded
        }
        guard data.count > magic.count + 4 + 4 + 16 + 12 + 16,
              data.prefix(magic.count) == magic else {
            throw PatchPackageError.unsupportedFormat
        }
        let version = u32(data, offset: magic.count)
        let flags = u32(data, offset: magic.count + 4)
        guard version == packVersion, flags == 0 else {
            throw PatchPackageError.unsupportedVersion
        }
        let saltStart = magic.count + 8
        let salt = data.subdata(in: saltStart..<(saltStart + 16))
        let nonce = data.subdata(in: (saltStart + 16)..<(saltStart + 28))
        let tag = data.suffix(16)
        let ciphertext = data.subdata(in: (saltStart + 28)..<(data.count - 16))
        var aad = Data()
        aad.append(magic)
        aad.append(contentsOf: self.u32(version))
        aad.append(contentsOf: self.u32(flags))
        aad.append(salt)
        let key = try fileKey(salt: salt)
        let box = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: nonce),
            ciphertext: ciphertext,
            tag: tag
        )
        let inner = try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
        let project = try decodeInner(inner)
        try validate(project)
        return DecodedPatchPackage(project: project, contentKey: key)
    }

    private static func encodeInner(_ project: PatchProject) throws -> Data {
        var out = Data()
        out.append(contentsOf: u32(1))
        out.append(uuidData(project.id))
        try out.append(string: project.name)
        try out.append(string: project.author)
        out.append(project.isPrivate ? 1 : 0)
        out.append(contentsOf: u64(UInt64(max(0, project.createdAt.timeIntervalSince1970 * 1000))))
        out.append(contentsOf: u64(UInt64(max(0, project.updatedAt.timeIntervalSince1970 * 1000))))
        out.append(contentsOf: u16(UInt16(project.bundleIdentifiers.count)))
        for bundle in project.bundleIdentifiers {
            try out.append(string: bundle)
        }
        out.append(contentsOf: u16(UInt16(project.directories.count)))
        for directory in project.directories {
            out.append(uuidData(directory.id))
            try out.append(string: directory.bundleID)
            try out.append(string: directory.relativePath)
            out.append(UInt8(kindCode(directory.resolvedContainerKind)))
        }
        out.append(contentsOf: u16(UInt16(project.rules.count)))
        for rule in project.rules {
            out.append(uuidData(rule.id))
            try out.append(string: rule.bundleID)
            try out.append(string: rule.relativePath)
            try out.append(string: rule.replacementFilename)
            out.append(UInt8(kindCode(rule.resolvedContainerKind)))
            out.append(UInt8(operationCode(rule.resolvedOperation)))
            out.append(contentsOf: u32(UInt32(rule.replacementData.count)))
            out.append(rule.replacementData)
        }
        let settings = project.settingsDefaults.sorted { $0.key < $1.key }
        out.append(contentsOf: u16(UInt16(settings.count)))
        for (key, value) in settings {
            try out.append(string: key)
            try out.append(string: value)
        }
        return out
    }

    private static func decodeInner(_ data: Data) throws -> PatchProject {
        var reader = PackReader(data)
        guard try reader.u32() == 1 else { throw PatchPackageError.invalidProject }
        let id = try reader.uuid()
        let name = try reader.string()
        let author = try reader.string()
        let isPrivate = try reader.u8() == 1
        let createdAt = Date(timeIntervalSince1970: Double(try reader.u64()) / 1000)
        let updatedAt = Date(timeIntervalSince1970: Double(try reader.u64()) / 1000)
        let bundleCount = Int(try reader.u16())
        let bundleIdentifiers = try (0..<bundleCount).map { _ in try reader.string() }
        let directoryCount = Int(try reader.u16())
        let directories = try (0..<directoryCount).map { _ in
            PatchDirectory(
                id: try reader.uuid(),
                bundleID: try reader.string(),
                relativePath: try reader.string(),
                containerKind: kindName(Int(try reader.u8()))
            )
        }
        let ruleCount = Int(try reader.u16())
        let rules = try (0..<ruleCount).map { _ -> PatchRule in
            let ruleID = try reader.uuid()
            let bundleID = try reader.string()
            let relativePath = try reader.string()
            let filename = try reader.string()
            let kind = kindName(Int(try reader.u8()))
            let operation = operationName(Int(try reader.u8()))
            let payload = try reader.bytes(Int(try reader.u32()))
            return PatchRule(
                id: ruleID,
                bundleID: bundleID,
                relativePath: relativePath,
                replacementFilename: filename,
                replacementData: payload,
                containerKind: kind,
                operation: operation
            )
        }
        let settingCount = Int(try reader.u16())
        var settings: [String: String] = [:]
        for _ in 0..<settingCount {
            settings[try reader.string()] = try reader.string()
        }
        guard reader.remaining == 0 else { throw PatchPackageError.invalidProject }
        var project = PatchProject(
            id: id,
            name: name,
            author: author,
            isPrivate: isPrivate,
            createdAt: createdAt,
            updatedAt: updatedAt,
            bundleIdentifiers: bundleIdentifiers,
            directories: directories,
            rules: rules
        )
        project.settingsDefaults = settings
        return project
    }

    private static func fileKey(salt: Data) throws -> Data {
        let master = try RuntimeMaterial.wrapKey()
        var hasher = SHA256()
        hasher.update(data: master)
        hasher.update(data: salt)
        hasher.update(data: Data([
            0x2C, 0x3C, 0x34, 0x22, 0x74, 0x3C, 0x33, 0x36, 0x3F, 0x74, 0x68,
        ].map { $0 ^ 0x5A }))
        return Data(hasher.finalize())
    }

    private static func rejectForeignMarkers(_ data: Data) throws {
        for mask in bannedMasks {
            let marker = Data(mask.map { $0 ^ 0x5A })
            if data.starts(with: marker) {
                throw PatchPackageError.unsupportedFormat
            }
        }
    }

    private static func kindCode(_ value: String) -> Int {
        kinds.firstIndex(of: value) ?? 0
    }

    private static func kindName(_ value: Int) -> String {
        kinds.indices.contains(value) ? kinds[value] : "application"
    }

    private static func operationCode(_ value: String) -> Int {
        operations.firstIndex(of: value) ?? 0
    }

    private static func operationName(_ value: Int) -> String {
        operations.indices.contains(value) ? operations[value] : "replace"
    }

    private static func uuidData(_ uuid: UUID) -> Data {
        withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }

    private static func randomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw PatchPackageError.invalidProject }
        return data
    }

    private static func u16(_ value: UInt16) -> [UInt8] {
        let le = value.littleEndian
        return [UInt8(le & 0xff), UInt8((le >> 8) & 0xff)]
    }

    private static func u32(_ value: UInt32) -> [UInt8] {
        let le = value.littleEndian
        return [
            UInt8(le & 0xff),
            UInt8((le >> 8) & 0xff),
            UInt8((le >> 16) & 0xff),
            UInt8((le >> 24) & 0xff)
        ]
    }

    private static func u64(_ value: UInt64) -> [UInt8] {
        var le = value.littleEndian
        return withUnsafeBytes(of: &le) { Array($0) }
    }

    private static func u32(_ data: Data, offset: Int) -> UInt32 {
        let bytes = [UInt8](data.subdata(in: offset..<(offset + 4)))
        return UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
    }
}

private extension Data {
    mutating func append(string: String) throws {
        let bytes = Data(string.utf8)
        guard bytes.count <= 65_535 else { throw PatchPackageError.invalidProject }
        append(contentsOf: [
            UInt8(bytes.count & 0xff),
            UInt8((bytes.count >> 8) & 0xff)
        ])
        append(bytes)
    }
}

private struct PackReader {
    let data: Data
    var offset = 0

    var remaining: Int { data.count - offset }

    init(_ data: Data) {
        self.data = data
    }

    mutating func u8() throws -> UInt8 {
        try take(1)[0]
    }

    mutating func u16() throws -> UInt16 {
        let bytes = try take(2)
        return UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
    }

    mutating func u32() throws -> UInt32 {
        let bytes = try take(4)
        return UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
    }

    mutating func u64() throws -> UInt64 {
        let bytes = try take(8)
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(bytes[index]) << (8 * index)
        }
        return value
    }

    mutating func uuid() throws -> UUID {
        let bytes = try take(16)
        return bytes.withUnsafeBytes { pointer in
            UUID(uuid: pointer.load(as: uuid_t.self))
        }
    }

    mutating func string() throws -> String {
        let count = Int(try u16())
        guard let value = String(data: try bytes(count), encoding: .utf8) else {
            throw PatchPackageError.invalidProject
        }
        return value
    }

    mutating func bytes(_ count: Int) throws -> Data {
        Data(try take(count))
    }

    private mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, offset + count <= data.count else {
            throw PatchPackageError.invalidProject
        }
        let slice = [UInt8](data[offset..<(offset + count)])
        offset += count
        return slice
    }
}
