import Foundation

enum DocumentRole: String, Codable {
    case reader
    case commenter
    case editor
    case administrator
    case owner
}

enum LinkRole: String, Codable {
    case reader
    case commenter
    case editor
}
