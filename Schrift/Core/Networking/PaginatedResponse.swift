import Foundation

struct PaginatedResponse<T: Decodable & Sendable>: Decodable, Sendable {
    let count: Int
    let next: String?
    let previous: String?
    let results: [T]
}
