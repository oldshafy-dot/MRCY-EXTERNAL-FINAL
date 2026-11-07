import Combine
import Foundation

struct PatchDraftRequest: Identifiable {
    let id = UUID()
    let draft: PatchProjectDraft
}

enum PatchImportSource: Equatable {
    case file(URL)
    case remote(URL)
    case invalid
}

enum PatchImportRoute {
    static func resolve(_ incomingURL: URL) -> PatchImportSource {
        _ = incomingURL
        return .invalid
    }

    static func validatedRemoteURL(_ url: URL) -> URL? {
        _ = url
        return nil
    }
}

struct PatchImportRequest: Identifiable, Equatable {
    let id = UUID()
    let source: PatchImportSource
}

@MainActor
final class PatchDraftCoordinator: ObservableObject {
    @Published var request: PatchDraftRequest?
    @Published var importRequest: PatchImportRequest?

    func present(_ draft: PatchProjectDraft) {
        _ = draft
        RuntimeGuard.rejectImport()
    }

    func clear() {
        request = nil
    }

    func presentImport(_ url: URL) {
        _ = url
        RuntimeGuard.rejectImport()
    }

    func clearImport() {
        importRequest = nil
    }
}
