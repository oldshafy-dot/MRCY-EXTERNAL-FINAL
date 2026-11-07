import Foundation

// The production configuration loader is unrelated to these native core tests.
// Compile the actual licensing models without embedding deployment material.
enum RuntimeMaterial {
    static func reveal() throws -> (url: URL, key: Data, response: Data, pins: [Data]) {
        throw LicenseClientError.unconfigured("Not used by core checks")
    }
}

private enum TestFailure: Error { case assertion(String), injected }

private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw TestFailure.assertion(message) }
}

private func fails(_ body: () throws -> Void) throws {
    var failed = false
    do { try body() } catch { failed = true }
    try check(failed, "Expected an operation to fail")
}

private final class FailingCopyManager: FileManager, @unchecked Sendable {
    var rejectedSource: String?
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        if srcURL.lastPathComponent == rejectedSource { throw TestFailure.injected }
        try super.copyItem(at: srcURL, to: dstURL)
    }
}

private struct Fixture {
    let root: URL
    let container: URL
    let backups: URL
    let project: PatchProject

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vita-core-test-\(UUID().uuidString)", isDirectory: true)
        container = root.appendingPathComponent("container", isDirectory: true)
        backups = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try Data("original-a".utf8).write(to: container.appendingPathComponent("a.bin"))
        try Data("original-b".utf8).write(to: container.appendingPathComponent("b.bin"))
        project = PatchProject(name: "Test", rules: ["a", "b"].map {
            PatchRule(bundleID: "com.example.test", relativePath: "\($0).bin",
                      replacementFilename: "\($0).bin", replacementData: Data("patched-\($0)".utf8))
        })
    }

    func value(_ name: String) throws -> String {
        try String(contentsOf: container.appendingPathComponent("\(name).bin"), encoding: .utf8)
    }
    func apply(beforeWrite: ((Int) throws -> Void)? = nil,
               fileManager: FileManager = .default) throws -> PatchTransactionReceipt {
        try PatchTransaction.apply(project: project, backupRoot: backups,
            containerResolver: { _ in container }, beforeWrite: beforeWrite, fileManager: fileManager)
    }
    func restore(_ receipt: PatchTransactionReceipt,
                 beforeWrite: ((Int) throws -> Void)? = nil,
                 fileManager: FileManager = .default) throws {
        try PatchTransaction.restore(receipt: receipt, allowChangedTargets: true,
            containerResolver: { _ in container }, beforeWrite: beforeWrite, fileManager: fileManager)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@main
enum RecoveryChecks {
    static func main() throws {
        try identityChecks()
        try recoveryChecks()
        print("PASS: device identity migration and native file recovery checks")
    }

    static func identityChecks() throws {
        let id = "A54F9D6B-518E-4694-B288-DA7F059CF0B3"
        let data = Data(id.utf8)
        var writes: [Data] = []
        let current = try DeviceStamp.resolveInstallationID(current: { data },
            legacy: { throw TestFailure.injected }, hasRegistration: { true }, save: { writes.append($0) })
        try check(current == id && writes.isEmpty, "Existing identity must remain unchanged")

        let migrated = try DeviceStamp.resolveInstallationID(current: { nil }, legacy: { data },
            hasRegistration: { true }, save: { writes.append($0) })
        try check(migrated == id && writes == [data], "Legacy UUID must migrate byte-for-byte")
        let failedCopy = try DeviceStamp.resolveInstallationID(current: { nil }, legacy: { data },
            hasRegistration: { true }, save: { _ in throw TestFailure.injected })
        try check(failedCopy == id, "Failed migration copy must still use the legacy identity")

        writes = []
        try fails {
            _ = try DeviceStamp.resolveInstallationID(current: { Data("damaged".utf8) },
                legacy: { data }, hasRegistration: { false }, save: { writes.append($0) })
        }
        try fails {
            _ = try DeviceStamp.resolveInstallationID(current: { throw LicenseClientError.keychain },
                legacy: { nil }, hasRegistration: { false }, save: { writes.append($0) })
        }
        try fails {
            _ = try DeviceStamp.resolveInstallationID(current: { nil }, legacy: { nil },
                hasRegistration: { true }, save: { writes.append($0) })
        }
        try check(writes.isEmpty, "Damaged/inaccessible/missing registered identity must not be replaced")
        let fresh = try DeviceStamp.resolveInstallationID(current: { nil }, legacy: { nil },
            hasRegistration: { false }, save: { writes.append($0) })
        try check(UUID(uuidString: fresh) != nil && writes == [Data(fresh.utf8)], "Fresh install must persist its UUID")
        try fails {
            _ = try DeviceStamp.resolveInstallationID(current: { nil }, legacy: { nil },
                hasRegistration: { false }, save: { _ in throw LicenseClientError.keychain })
        }
    }

    static func recoveryChecks() throws {
        do {
            let f = try Fixture(); defer { f.cleanup() }
            let receipt = try f.apply()
            try check(f.value("a") == "patched-a" && f.value("b") == "patched-b", "Apply must write both files")
            try f.restore(receipt)
            try check(f.value("a") == "original-a" && f.value("b") == "original-b", "Restore must recover both originals")
        }
        do {
            let f = try Fixture(); defer { f.cleanup() }
            try fails {
                _ = try f.apply(beforeWrite: { index in
                    if index == 1 { throw URLError(.notConnectedToInternet) }
                })
            }
            try check(f.value("a") == "original-a" && f.value("b") == "original-b", "Failed Apply must roll back locally")
            try check(PatchTransaction.latestReceipt(projectID: f.project.id, backupRoot: f.backups) == nil,
                      "Successful rollback must not leave an active patch")
        }
        do {
            let f = try Fixture(); defer { f.cleanup() }
            let receipt = try f.apply()
            try fails { try f.restore(receipt, beforeWrite: { if $0 == 1 { throw TestFailure.injected } }) }
            try check(f.value("a") == "patched-a" && f.value("b") == "patched-b", "Failed Restore must recover the pre-Restore state")
            try f.restore(receipt)
            try check(f.value("a") == "original-a" && f.value("b") == "original-b", "Retry Restore must succeed")
        }
        do {
            let f = try Fixture(); defer { f.cleanup() }
            let receipt = try f.apply()
            let original = receipt.journalURL.deletingLastPathComponent()
                .appendingPathComponent("\(f.project.rules[0].id.uuidString).original")
            try Data("corrupt-backup".utf8).write(to: original)
            try fails { try f.restore(receipt) }
            try check(f.value("a") == "patched-a" && f.value("b") == "patched-b", "Bad backup must fail before Restore writes")
        }
        do {
            let f = try Fixture(); defer { f.cleanup() }
            let manager = FailingCopyManager()
            manager.rejectedSource = "\(f.project.rules[1].id.uuidString).original"
            var error: Error?
            do { _ = try f.apply(beforeWrite: { if $0 == 1 { throw TestFailure.injected } }, fileManager: manager) }
            catch let failure { error = failure }
            try check(error as? PatchPackageError == .recoveryRequired, "Incomplete rollback must be reported")
            try check(f.value("a") == "original-a", "One failed rollback copy must not stop recovery of other files")
            guard let receipt = PatchTransaction.latestReceipt(projectID: f.project.id, backupRoot: f.backups) else {
                throw TestFailure.assertion("Incomplete rollback must retain its journal")
            }
            try f.restore(receipt)
            try check(f.value("b") == "original-b", "Retained originals must allow a retry")
        }
        do {
            let f = try Fixture(); defer { f.cleanup() }
            let receipt = try f.apply()
            let manager = FailingCopyManager()
            manager.rejectedSource = "1.current"
            var error: Error?
            do { try f.restore(receipt, beforeWrite: { if $0 == 1 { throw TestFailure.injected } }, fileManager: manager) }
            catch let failure { error = failure }
            try check(error as? PatchPackageError == .recoveryRequired, "Failed snapshot recovery must be reported")
            let files = try FileManager.default.contentsOfDirectory(atPath: receipt.journalURL.deletingLastPathComponent().path)
            try check(files.contains(where: { $0.hasPrefix(".recovery-") }), "Recovery snapshots must be kept")
            try f.restore(receipt)
            try check(f.value("a") == "original-a" && f.value("b") == "original-b", "Original backups remain usable after failed snapshot recovery")
        }
        do {
            let f = try Fixture(); defer { f.cleanup() }
            try Data("original-c".utf8).write(to: f.container.appendingPathComponent("c.bin"))
            _ = try f.apply()
            let extra = PatchProject(name: "Test2", rules: [
                PatchRule(
                    bundleID: "com.example.test",
                    relativePath: "c.bin",
                    replacementFilename: "c.bin",
                    replacementData: Data("patched-c".utf8)
                )
            ])
            _ = try PatchTransaction.apply(
                project: extra,
                backupRoot: f.backups,
                containerResolver: { _ in f.container }
            )
            let leftovers = PatchTransaction.allActiveReceipts(backupRoot: f.backups)
            try check(
                Set(leftovers.map(\.projectID)) == Set([f.project.id, extra.id]),
                "Relaunch cleanup must see every leftover function"
            )
            for receipt in leftovers {
                try f.restore(receipt)
            }
            try check(
                PatchTransaction.allActiveReceipts(backupRoot: f.backups).isEmpty,
                "Relaunch cleanup must turn leftover functions off"
            )
            try check(
                f.value("a") == "original-a" && f.value("c") == "original-c",
                "Relaunch cleanup must restore original files"
            )
        }
    }
}
