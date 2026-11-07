import CryptoKit
import Foundation

// Compile the real library and codec with isolated storage, a test-only pack
// key, and a controlled trust list. No device, server or production keys.
enum RuntimeMaterial {
    static func wrapKey() throws -> Data { Data(repeating: 0x42, count: 32) }
}
enum CatalogTrust {
    static var allowed = Set<String>()
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func contains(_ data: Data, fileManager: FileManager = .default) -> Bool {
        allowed.contains(sha256Hex(data))
    }
}
enum PatchKeyStore {
    static func load(for summary: PatchPackageSummary) throws -> Data? { nil }
    static func delete(for summary: PatchPackageSummary) throws {}
}
enum PatchWorkspaceService {
    static func workspaceURL(projectID: UUID) -> URL { FileManager.default.temporaryDirectory }
    static func ensureWorkspace(for project: PatchProject, fileManager: FileManager = .default) throws -> URL {
        throw PatchPackageError.invalidProject
    }
    static func replaceWorkspace(with project: PatchProject, fileManager: FileManager = .default) throws -> URL {
        throw PatchPackageError.invalidProject
    }
    static func deleteWorkspace(projectID: UUID, fileManager: FileManager = .default) throws {}
    static func snapshot(baseProject: PatchProject, workspaceURL: URL, fileManager: FileManager = .default) throws -> PatchProject {
        throw PatchPackageError.invalidProject
    }
}
func log(_ message: String) {}

private final class CatalogFileManager: FileManager, @unchecked Sendable {
    let testRoot: URL
    init(root: URL) { testRoot = root; super.init() }
    override func url(for directory: FileManager.SearchPathDirectory,
                      in domain: FileManager.SearchPathDomainMask,
                      appropriateFor url: URL?, create shouldCreate: Bool) throws -> URL {
        guard directory == .applicationSupportDirectory else {
            return try super.url(for: directory, in: domain, appropriateFor: url, create: shouldCreate)
        }
        return testRoot
    }
}

private enum Failure: Error { case assertion(String) }
private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw Failure.assertion(message) }
}

@main
struct CatalogChecks {
    static func main() throws {
        // Users with 0, 1 or 2 previously trusted packages must all receive 3.
        for previouslyTrusted in 0...2 {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("vita-catalog-check-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let manager = CatalogFileManager(root: root)
            let projects = (0..<3).map { index in
                PatchProject(name: "Function \(index)", rules: [
                    PatchRule(bundleID: "com.example.test", relativePath: "file-\(index).bin",
                              replacementFilename: "file.bin", replacementData: Data([UInt8(index)]))
                ])
            }
            let packs = try projects.map { try PatchPackageCodec.encodeNew(project: $0, password: nil).data }
            CatalogTrust.allowed = Set(packs.prefix(previouslyTrusted).map(CatalogTrust.sha256Hex))
            let hashes = packs.map(CatalogTrust.sha256Hex)
            let packageRoot = try PatchProjectLibrary.packageRootURL(fileManager: manager)
            for (index, pack) in packs.enumerated() {
                try PatchProjectLibrary.installVerifiedContentPackage(pack, fileManager: manager)
                // Simulate the initial/background library read before commit.
                let visible = PatchProjectLibrary.load(fileManager: manager)
                try check(visible.count == min(index + 1, previouslyTrusted), "Untrusted files became visible")
                for installed in 0...index {
                    let path = packageRoot.appendingPathComponent(PatchPackageCodec.opaqueFilename(for: projects[installed].id))
                    try check(try Data(contentsOf: path) == packs[installed], "A later install/read deleted an earlier package")
                }
            }
            try check(PatchProjectLibrary.containsCompleteRelease(expectedHashes: hashes, fileManager: manager), "Complete release not detected")
            try check(!PatchProjectLibrary.containsCompleteRelease(expectedHashes: [hashes[0], hashes[0]], fileManager: manager), "Duplicate package IDs accepted")
            CatalogTrust.allowed = Set(hashes)
            try check(PatchProjectLibrary.load(fileManager: manager).count == 3, "Expected all three committed functions")

            // A repair of missing files must restore all functions with the same IDs.
            for index in 0..<2 {
                let path = packageRoot.appendingPathComponent(PatchPackageCodec.opaqueFilename(for: projects[index].id))
                try manager.removeItem(at: path)
            }
            try check(!PatchProjectLibrary.containsCompleteRelease(expectedHashes: hashes, fileManager: manager), "Incomplete marked release incorrectly accepted")
            for pack in packs {
                try PatchProjectLibrary.installVerifiedContentPackage(pack, fileManager: manager)
            }
            try check(PatchProjectLibrary.load(fileManager: manager).count == 3, "Repair did not restore the missing functions")
            try check(PatchProjectLibrary.containsCompleteRelease(expectedHashes: hashes, fileManager: manager), "Repaired release not detected")
            let damaged = packageRoot.appendingPathComponent(PatchPackageCodec.opaqueFilename(for: projects[0].id))
            try Data("damaged".utf8).write(to: damaged)
            try check(!PatchProjectLibrary.containsCompleteRelease(expectedHashes: hashes, fileManager: manager), "Damaged package incorrectly accepted")
        }
        print("Catalog installation checks passed")
    }
}
