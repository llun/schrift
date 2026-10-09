import Foundation

/// Whether a failed media fetch says nothing about the media itself — the device simply had no usable
/// connection. Such a failure is worth one automatic retry once the app is online again, unlike a 404, a
/// decode failure or an oversized body, which a second identical request would only repeat.
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
