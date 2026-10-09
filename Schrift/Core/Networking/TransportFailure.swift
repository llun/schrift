import Foundation

/// Whether a failed media fetch says nothing about the media itself — the device simply had no usable
/// connection. Such a failure is worth one automatic retry once the app is online again, unlike a 404, a
/// decode failure or an oversized body, which a second identical request would only repeat.
///
/// `DocsAPIError.network` is accepted wholesale, not narrowed to connectivity codes: `DocsAPIClient` wraps every
/// `URLSession` error (including, say, a TLS or cancelled-request failure) as `.network`, so attachment loads —
/// which go through the client — get a slightly broader retry than image loads, which see the raw `URLError`.
/// That is deliberate and harmless: the retry happens at most once per failure and is never itself re-marked.
func isTransportFailure(_ error: Error) -> Bool {
    if let apiError = error as? DocsAPIError {
        if case .network = apiError { return true }
        return false
    }
    guard let urlError = error as? URLError else { return false }
    switch urlError.code {
    case .notConnectedToInternet, .timedOut, .cannotConnectToHost, .networkConnectionLost, .cannotFindHost,
        .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
        return true
    default:
        return false
    }
}
