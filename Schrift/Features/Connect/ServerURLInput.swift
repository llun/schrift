import Foundation

/// The single canonicalization point for the user-typed server address. Everything
/// downstream — the persisted `serverURL`, the API client's `baseURL`, the login web view's
/// `serverHost` — is derived from what this returns.
///
/// Scheme and host are **lowercased**, because neither is case-sensitive but plenty of code
/// that compares them is. iOS autocapitalizes the first letter of a plain text field, so a
/// user typing their address gets `Docs.llun.dev`, and that capital broke two things at
/// once: `isLoginNavigationComplete` compared against WebKit's always-lowercase `url.host`
/// and never matched, leaving the login sheet stuck open on the signed-in web app; and
/// `DocsAPIClient.siteOrigin` sent `Origin: https://Docs.llun.dev`, which Django rejects
/// ("Origin checking failed") on every non-GET, while GETs — which carry no Origin — kept
/// working, making the app look read-only. The path is *not* lowercased (paths are
/// case-sensitive); it is stripped, along with the query and fragment.
func normalizedServerURL(from input: String) -> URL? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard var components = URLComponents(string: candidate),
        let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
        let host = components.host, !host.isEmpty
    else {
        return nil
    }
    components.scheme = scheme
    components.host = host.lowercased()
    components.path = ""
    components.query = nil
    components.fragment = nil
    return components.url
}
