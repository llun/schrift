import Foundation

func normalizedServerURL(from input: String) -> URL? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard var components = URLComponents(string: candidate),
          let scheme = components.scheme, ["http", "https"].contains(scheme),
          let host = components.host, !host.isEmpty else {
        return nil
    }
    components.path = ""
    components.query = nil
    components.fragment = nil
    return components.url
}
