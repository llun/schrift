import Foundation

/// What a request told us about whether the server can be reached at all, reported by
/// `DocsAPIClient` through `onTransportOutcome` together with the instant the request
/// started (so `ConnectivityMonitor` can drop a stale `.unreachable`). Any HTTP response
/// (even a 500) proves the server was reached; only a connectivity-class transport failure
/// says it was not.
enum TransportOutcome: Sendable, Equatable {
    case reachedServer
    case unreachable
}

/// Whether `error` means the request never got through to the server because the
/// connection is down or unusable — the "satisfied path but no internet" signal that
/// `NWPath` cannot see, for a connection that black-holes requests (plane Wi-Fi without a
/// purchase: timeouts, cannot connect).
///
/// An allowlist on purpose: `.cancelled` is the app's own doing, and TLS or
/// bad-response errors are not "offline". That deliberately leaves out a captive portal:
/// HTTPS through an intercepting portal fails with TLS errors, which are excluded.
func isConnectivityFailure(_ error: Error) -> Bool {
    guard let urlError = error as? URLError else { return false }
    switch urlError.code {
    case .notConnectedToInternet, .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
        .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .callIsActive:
        return true
    default:
        return false
    }
}
