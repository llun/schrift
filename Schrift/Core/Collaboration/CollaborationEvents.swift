import Foundation

/// Why a collaboration socket ended — the signal the session layer uses to
/// decide between tearing down and reconnecting.
enum CollaborationDisconnect: Equatable, Sendable {
    /// The server closed with 1000. y-provider does this on a *permission* change
    /// (its reset-connections), and the web treats it as terminal: refetch the
    /// document + abilities, no auto-reconnect. So this is **not** a reconnect
    /// candidate.
    case permissionsReset
    /// We closed the socket ourselves (suspend / teardown), signalled with 1001.
    /// The session meant to stop, so it must not reconnect.
    case selfClosed
    /// A transport error, an abnormal close, or any other code — a reconnect
    /// candidate, subject to the session's backoff.
    case transient

    /// Classifies a close observed *from the peer* (i.e. not our own close).
    /// Only 1000 carries the terminal permission-reset meaning; everything else
    /// — an error (`.invalid` close code), an abnormal 1006, a server 1001 — is
    /// treated as transient so the session may retry. A self-close is recognised
    /// by the transport before this is consulted, never here (our 1001 and a
    /// server's 1001 are indistinguishable by close code alone).
    static func classify(closeCode: URLSessionWebSocketTask.CloseCode) -> CollaborationDisconnect {
        closeCode == .normalClosure ? .permissionsReset : .transient
    }
}

/// One event surfaced by `CollaborationTransport.start()`.
enum CollaborationEvent: Equatable, Sendable {
    /// A decoded inbound Hocuspocus frame. Undecodable frames are dropped by the
    /// transport (unknown types are tolerated, never fatal), so this only ever
    /// carries a well-formed frame.
    case message(HocuspocusMessage)
    /// The socket ended; the stream finishes immediately after this event.
    case disconnected(CollaborationDisconnect)
}
