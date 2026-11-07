import Foundation

enum BundledFunctionCatalog {
    private static let factoryPackageID = UUID(uuidString: "46AD507A-4E4B-4B86-A5D2-608CD5DB4D28")

    static func removeFactorySeedIfNeeded() {
        guard let factoryPackageID,
              let item = PatchProjectLibrary.load().first(where: { $0.id == factoryPackageID }),
              !ContentFunctionMetadataStore.isManaged(factoryPackageID),
              DevicePatchService.latestReceipt(projectID: factoryPackageID) == nil else {
            return
        }
        do {
            try PatchProjectLibrary.delete(item)
            log("vita: removed factory function so updates can provide the catalog")
        } catch {
            log("vita: factory function cleanup failed — \(error.localizedDescription)")
        }
    }

    static func displayName(for item: PatchLibraryItem) -> String {
        if let name = ContentFunctionMetadataStore.metadata(for: item.id)?.name, !name.isEmpty {
            return name
        }
        if let name = item.project?.name.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return "Function"
    }
}
