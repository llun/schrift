import Foundation

/// Drives the read-only version history sheet (`VersionHistorySheetView`).
/// Deliberately has no restore method: F4 (in-app restore) is deferred, so the
/// only way to go back to an earlier version is the sheet's "Restore on the
/// web" link, which hands off to the web app.
@MainActor
@Observable
final class VersionHistoryViewModel {
    var versions: [DocumentVersion] = []
    var isLoading = false
    var errorKey: L10nKey?

    private let client: DocsAPIClient
    private let documentID: UUID

    init(client: DocsAPIClient, documentID: UUID) {
        self.client = client
        self.documentID = documentID
    }

    func load() async {
        isLoading = true
        errorKey = nil
        defer { isLoading = false }
        do {
            versions = try await client.documentVersions(documentID: documentID)
        } catch {
            versions = []
            errorKey = .versions_error
        }
    }
}
