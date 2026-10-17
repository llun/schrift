import Foundation

struct CurrentUser: Codable, Equatable, Sendable, Identifiable {
    let id: UUID?
    let email: String?
    let fullName: String?
    let shortName: String?
    let language: String?

    init(
        id: UUID? = nil,
        email: String? = nil,
        fullName: String? = nil,
        shortName: String? = nil,
        language: String? = nil
    ) {
        self.id = id
        self.email = email
        self.fullName = fullName
        self.shortName = shortName
        self.language = language
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case email
        case fullName
        case shortName
        case language
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        fullName = try container.decodeIfPresent(String.self, forKey: .fullName)
        shortName = try container.decodeIfPresent(String.self, forKey: .shortName)
        language = try container.decodeIfPresent(String.self, forKey: .language)
    }
}

extension CurrentUser {
    var displayName: String {
        fullName ?? shortName ?? email ?? "Account"
    }

    var languageLabel: String? {
        guard let language, !language.isEmpty else { return nil }
        switch language.lowercased() {
        case "en", "en-us":
            return "English"
        case "fr":
            return "Français"
        default:
            return language
        }
    }
}

extension DocsAPIClient {
    /// Concurrent callers share one request (in-flight only, no cache: a call after the previous
    /// one settled always asks the server). The 401 hook fires inside the shared request, once.
    func currentUser() async throws -> CurrentUser {
        if let task = inFlightCurrentUser { return try await task.value }
        let task = Task { try await self.get("users/me/") as CurrentUser }
        inFlightCurrentUser = task
        defer { inFlightCurrentUser = nil }
        return try await task.value
    }
}
