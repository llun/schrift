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

    let availability: OnlineAvailability
    private var loadGeneration = 0

    private let client: DocsAPIClient
    private let documentID: UUID

    init(client: DocsAPIClient, documentID: UUID, availability: OnlineAvailability = OnlineAvailability()) {
        self.availability = availability
        self.client = client
        self.documentID = documentID
    }

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = false
        guard !availability.isOffline else { return }
        let token = availability.token
        isLoading = true
        errorKey = nil
        do {
            let fetched = try await client.documentVersions(documentID: documentID)
            guard generation == loadGeneration else { return }
            isLoading = false
            guard availability.permitsResponse(for: token), !Task.isCancelled else { return }
            versions = fetched
        } catch {
            guard generation == loadGeneration else { return }
            isLoading = false
            guard availability.permitsResponse(for: token), !Task.isCancelled else { return }
            versions = []
            errorKey = .versions_error
        }
    }
}
