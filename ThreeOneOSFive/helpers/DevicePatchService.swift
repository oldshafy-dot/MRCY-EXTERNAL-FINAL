import Foundation

enum DevicePatchService {
    static func apply(project: PatchProject) throws -> PatchTransactionReceipt {
        return try withResolvedContainers(targets: project.containerTargets) { roots in
            try PatchTransaction.apply(
                project: project,
                backupRoot: try PatchProjectLibrary.backupRootURL(),
                containerResolver: { identifier in
                    try resolvedRoot(identifier, in: roots)
                }
            )
        }
    }

    static func inspectRestore(receipt: PatchTransactionReceipt) throws -> PatchRestoreInspection {
        let targets = try PatchTransaction.requiredContainerTargets(for: receipt)
        return try withResolvedContainers(targets: targets) { roots in
            try PatchTransaction.inspectRestore(
                receipt: receipt,
                containerResolver: { identifier in
                    try resolvedRoot(identifier, in: roots)
                }
            )
        }
    }

    static func restore(
        receipt: PatchTransactionReceipt,
        allowChangedTargets: Bool = false
    ) throws {
        let targets = try PatchTransaction.requiredContainerTargets(for: receipt)
        try withResolvedContainers(targets: targets) { roots in
            try PatchTransaction.restore(
                receipt: receipt,
                allowChangedTargets: allowChangedTargets,
                containerResolver: { identifier in
                    try resolvedRoot(identifier, in: roots)
                }
            )
        }
    }

    static func resetToAppliedState(
        receipt: PatchTransactionReceipt,
        project: PatchProject
    ) throws {
        let targets = try PatchTransaction.requiredContainerTargets(for: receipt)
        try withResolvedContainers(targets: targets) { roots in
            try PatchTransaction.resetToAppliedState(
                receipt: receipt,
                fallbackProject: project,
                containerResolver: { identifier in
                    try resolvedRoot(identifier, in: roots)
                }
            )
        }
    }

    static func latestReceipt(projectID: UUID) -> PatchTransactionReceipt? {
        guard let backupRoot = try? PatchProjectLibrary.backupRootURL() else { return nil }
        return PatchTransaction.latestReceipt(projectID: projectID, backupRoot: backupRoot)
    }

    static func allActiveReceipts() -> [PatchTransactionReceipt] {
        guard let backupRoot = try? PatchProjectLibrary.backupRootURL() else { return [] }
        return PatchTransaction.allActiveReceipts(backupRoot: backupRoot)
    }

    static func restoreAllActive(allowChangedTargets: Bool = true) throws {
        var firstError: Error?
        for receipt in allActiveReceipts() {
            do {
                try restore(receipt: receipt, allowChangedTargets: allowChangedTargets)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError {
            throw firstError
        }
    }

    private static func resolvedRoot(_ identifier: String, in roots: [String: URL]) throws -> URL {
        guard let root = roots[identifier] else {
            throw PatchPackageError.targetAppUnavailable(identifier)
        }
        return root
    }

    private static func withResolvedContainers<T>(
        targets: [PatchContainerTarget],
        operation: ([String: URL]) throws -> T
    ) throws -> T {
        var roots: [String: URL] = [:]
        for target in targets {
            if roots[target.identifier] != nil { continue }
            guard let path = ContainerStore.resolvePatchContainerPath(
                kind: target.kind,
                identifier: target.identifier
            ),
            ContainerStore.isPatchContainerPath(path, kind: target.kind) else {
                throw PatchPackageError.targetAppUnavailable(target.identifier)
            }
            roots[target.identifier] = PatchPathValidator.canonicalFileURL(
                URL(fileURLWithPath: path, isDirectory: true)
            )
        }
        return try operation(roots)
    }
}
