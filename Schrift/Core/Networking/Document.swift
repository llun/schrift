import Foundation

extension JSONDecoder {
    static let docsAPI: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let withFractionalSeconds = ISO8601DateFormatter()
        withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let withoutFractionalSeconds = ISO8601DateFormatter()
        withoutFractionalSeconds.formatOptions = [.withInternetDateTime]

        decoder.dateDecodingStrategy = .custom { dateDecoder in
            let container = try dateDecoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = withFractionalSeconds.date(from: string) {
                return date
            }
            if let date = withoutFractionalSeconds.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected ISO8601 date, got \(string)"
            )
        }
        return decoder
    }()
}

extension LinkReach: Codable {}

struct DocumentAbilities: Codable, Equatable, Hashable {
    var update: Bool = false
    var partialUpdate: Bool = false
    var destroy: Bool = false
    var linkConfiguration: Bool = false
    var accessesManage: Bool = false
    var favorite: Bool = false
    var duplicate: Bool = false
    var childrenCreate: Bool = false

    enum CodingKeys: String, CodingKey {
        case update, partialUpdate, destroy, linkConfiguration, accessesManage, favorite, duplicate, childrenCreate
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        update = try container.decodeIfPresent(Bool.self, forKey: .update) ?? false
        partialUpdate = try container.decodeIfPresent(Bool.self, forKey: .partialUpdate) ?? false
        destroy = try container.decodeIfPresent(Bool.self, forKey: .destroy) ?? false
        linkConfiguration = try container.decodeIfPresent(Bool.self, forKey: .linkConfiguration) ?? false
        accessesManage = try container.decodeIfPresent(Bool.self, forKey: .accessesManage) ?? false
        favorite = try container.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        duplicate = try container.decodeIfPresent(Bool.self, forKey: .duplicate) ?? false
        childrenCreate = try container.decodeIfPresent(Bool.self, forKey: .childrenCreate) ?? false
    }
}

struct Document: Codable, Equatable, Hashable, Identifiable {
    let id: UUID
    var title: String?
    var excerpt: String?
    let abilities: DocumentAbilities
    var linkReach: LinkReach
    var linkRole: LinkRole
    var computedLinkReach: LinkReach?
    var computedLinkRole: LinkRole?
    var isFavorite: Bool
    let depth: Int
    let numchild: Int
    let path: String
    let createdAt: Date
    let updatedAt: Date
    let userRole: DocumentRole?
    let creator: UUID?
}

// The decoder lives in an extension so the memberwise initializer survives — `SubpageRow`'s
// preview builds a `Document` with it.
extension Document {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        excerpt = try container.decodeIfPresent(String.self, forKey: .excerpt)
        abilities = try container.decode(DocumentAbilities.self, forKey: .abilities)
        linkReach = try container.decode(LinkReach.self, forKey: .linkReach)
        linkRole = try container.decode(LinkRole.self, forKey: .linkRole)
        computedLinkReach = try container.decodeIfPresent(LinkReach.self, forKey: .computedLinkReach)
        computedLinkRole = try container.decodeIfPresent(LinkRole.self, forKey: .computedLinkRole)
        // `is_favorite` is a queryset annotation the *list* endpoints add. `POST documents/`
        // and `POST documents/{id}/children/` serialize a freshly created instance that
        // carries no such attribute, so the key is absent from both create responses.
        // Requiring it made every create fail with `keyNotFound` — after the server had
        // already created the document. A brand-new document is never a favorite.
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        depth = try container.decode(Int.self, forKey: .depth)
        numchild = try container.decode(Int.self, forKey: .numchild)
        path = try container.decode(String.self, forKey: .path)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        userRole = try container.decodeIfPresent(DocumentRole.self, forKey: .userRole)
        creator = try container.decodeIfPresent(UUID.self, forKey: .creator)
    }
}
