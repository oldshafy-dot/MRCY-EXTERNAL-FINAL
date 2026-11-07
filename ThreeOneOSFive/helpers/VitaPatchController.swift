import Foundation

@MainActor
final class VitaPatchController: ObservableObject {
    @Published private(set) var receipts: [UUID: PatchTransactionReceipt] = [:]
    @Published private(set) var isWorking = false
    @Published var message: String?
    var licenseAllowsApply: () -> Bool = { false }
    var requestPermit: ((UUID, Data, Bool) async throws -> Void)?

    private var leftoverRestoreAttempted = false
    private var leftoverRestoreContinuations: [() -> Void] = []

    func refresh(items: [PatchLibraryItem]) {
        guard !isWorking else { return }
        receipts = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            DevicePatchService.latestReceipt(projectID: item.id).map { (item.id, $0) }
        })
    }

    /// After a force-close or relaunch, put original game files back and turn every function off.
    /// This is local cleanup of backups we already wrote — it does not request a new write permit.
    func restoreLeftoversIfNeeded(
        items: [PatchLibraryItem],
        canAccessFiles: Bool,
        completion: (() -> Void)? = nil
    ) {
        if let completion {
            leftoverRestoreContinuations.append(completion)
        }

        guard canAccessFiles else { return }

        if leftoverRestoreAttempted {
            if !isWorking {
                flushLeftoverContinuations()
            }
            return
        }

        leftoverRestoreAttempted = true
        let leftovers = DevicePatchService.allActiveReceipts()
        guard !leftovers.isEmpty else {
            refresh(items: items)
            flushLeftoverContinuations()
            return
        }

        isWorking = true
        Task {
            var failure: String?
            do {
                try DevicePatchService.restoreAllActive(allowChangedTargets: true)
            } catch let error as PatchPackageError {
                failure = error.errorDescription ?? error.localizedDescription
            } catch {
                failure = error.localizedDescription
            }

            let currentReceipts = Dictionary(uniqueKeysWithValues: items.compactMap { candidate in
                DevicePatchService.latestReceipt(projectID: candidate.id).map {
                    (candidate.id, $0)
                }
            })

            await MainActor.run {
                self.receipts = currentReceipts
                self.isWorking = false
                if let failure {
                    self.leftoverRestoreAttempted = currentReceipts.isEmpty
                    self.message = "Could not restore original files. \(failure)"
                    log("app: leftover restore failed: \(failure)")
                } else {
                    log("app: restored leftover function files")
                }
                self.flushLeftoverContinuations()
            }
        }
    }

    private func flushLeftoverContinuations() {
        let pending = leftoverRestoreContinuations
        leftoverRestoreContinuations = []
        pending.forEach { $0() }
    }

    func isOpen(_ item: PatchLibraryItem) -> Bool {
        receipts[item.id] != nil
    }

    func setOpen(
        _ open: Bool,
        item: PatchLibraryItem,
        items: [PatchLibraryItem]
    ) {
        guard !isWorking else { return }
        guard licenseAllowsApply() else {
            message = "License required."
            return
        }
        guard let packageData = try? PatchProjectLibrary.readPackage(at: item.packageURL),
              CatalogTrust.contains(packageData) else {
            RuntimeGuard.rejectTamper()
            return
        }
        let receipt = DevicePatchService.latestReceipt(projectID: item.id)
        guard open ? receipt == nil : receipt != nil else { return }
        // Apply exactly the bytes whose hash was authorized, not an older
        // in-memory project from before an update replaced the package file.
        guard let decoded = try? PatchPackageCodec.decode(packageData, password: nil),
              decoded.project.id == item.id else {
            message = "This function is not ready. Check for an update and try again."
            return
        }

        isWorking = true
        let displayName = BundledFunctionCatalog.displayName(for: item)
        let permit = requestPermit
        Task {
            var failure: String?
            do {
                guard let permit else { throw LicenseClientError.unauthorized }
                try await permit(item.id, packageData, open)
                try RuntimePermit.assertReady()
                if open {
                    _ = try DevicePatchService.apply(project: decoded.project)
                } else if let receipt {
                    try DevicePatchService.restore(
                        receipt: receipt,
                        allowChangedTargets: true
                    )
                }
            } catch let error as PatchPackageError {
                failure = error.errorDescription ?? error.localizedDescription
            } catch {
                failure = error.localizedDescription
            }

            let currentReceipts = Dictionary(uniqueKeysWithValues: items.compactMap { candidate in
                DevicePatchService.latestReceipt(projectID: candidate.id).map {
                    (candidate.id, $0)
                }
            })

            await MainActor.run {
                self.receipts = currentReceipts
                self.isWorking = false
                self.message = failure ?? (
                    open ? "\(displayName) is open." : "\(displayName) is closed."
                )
            }
        }
    }
}
