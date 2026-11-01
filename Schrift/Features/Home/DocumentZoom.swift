import SwiftUI

/// Which list a row or card lives in. Part of the zoom source's identity, so a document that
/// is on screen twice at once (Home's list beneath the Search screen pushed over it) never
/// registers the same source id in one namespace.
enum DocumentZoomSurface: Hashable, Sendable {
    case home
    case search
    case shared
}

/// The identity of a row that a document zooms open from.
struct DocumentZoomSourceID: Hashable, Sendable {
    let documentID: UUID
    let surface: DocumentZoomSurface
}

/// How a pushed editor enters.
enum DocumentTransitionStyle: Equatable {
    /// The stack's default push.
    case automatic
    /// Grow out of the row or card with this source id.
    case zoom(DocumentZoomSourceID)
}

/// The transition for a pushed editor: a zoom only when it was opened from a row (there is a
/// source to grow from) and Reduce Motion is off. Deep links, page chips inside the editor
/// and "new document" have no source and use the stack's default push, as does everyone who
/// asked the system for less motion.
func documentTransitionStyle(source: DocumentZoomSourceID?, reduceMotion: Bool) -> DocumentTransitionStyle {
    guard let source, !reduceMotion else { return .automatic }
    return .zoom(source)
}

/// What a source row looks like to the zoom: the shape it grows out of and the fill behind it,
/// matching how that row or card is drawn so the first frame of the transition is seamless.
enum DocumentZoomSourceStyle: Equatable {
    /// A list row, drawn straight on the page canvas.
    case row
    /// A pinned card: a rounded `brandFillSubtle` surface.
    case card

    var cornerRadius: CGFloat { DocsRadius.lg }

    func background(_ colors: DocsColors) -> Color {
        switch self {
        case .row: return colors.surfacePage
        case .card: return colors.brandFillSubtle
        }
    }
}

/// Which pushed editors on one navigation stack were opened from a row, kept parallel to the
/// stack's path (one entry per pushed route, `nil` for a push that did not come from a row).
///
/// A destination closure only receives its route, so this is how it learns whether there is
/// a source to zoom from. Because each document's entry is fixed when it is pushed and only
/// removed when it is popped, a visible editor's transition never changes under it.
struct DocumentZoomTracker: Equatable {
    private(set) var entries: [DocumentZoomSourceID?] = []

    /// Record a push. Call it immediately before appending the route to the path.
    mutating func push(_ source: DocumentZoomSourceID?) {
        entries.append(source)
    }

    /// Drop the entries of routes that were popped.
    mutating func trim(to pathCount: Int) {
        guard pathCount >= 0, entries.count > pathCount else { return }
        entries.removeLast(entries.count - pathCount)
    }

    /// The row the most recent push of this document came from, if it came from one.
    func source(for documentID: UUID) -> DocumentZoomSourceID? {
        guard let entry = entries.last(where: { $0?.documentID == documentID }) else { return nil }
        return entry
    }
}

private struct DocumentZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    /// The namespace a compact navigation stack's rows register their zoom sources in. Left
    /// nil wherever nothing is pushed (the iPad split view's sidebar, previews, tests), which
    /// makes `documentZoomSource` a no-op there.
    var documentZoomNamespace: Namespace.ID? {
        get { self[DocumentZoomNamespaceKey.self] }
        set { self[DocumentZoomNamespaceKey.self] = newValue }
    }
}

private struct DocumentZoomSourceModifier: ViewModifier {
    @Environment(\.docsTheme) private var theme
    @Environment(\.documentZoomNamespace) private var namespace
    let id: DocumentZoomSourceID
    let style: DocumentZoomSourceStyle

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedTransitionSource(id: id, in: namespace) { source in
                source
                    .background(style.background(theme.colors))
                    .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
            }
        } else {
            content
        }
    }
}

private struct DocumentZoomDestinationModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let source: DocumentZoomSourceID?
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        switch documentTransitionStyle(source: source, reduceMotion: reduceMotion) {
        case .automatic:
            content.navigationTransition(.automatic)
        case .zoom(let id):
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        }
    }
}

extension View {
    /// Mark this row or card as the place `document` zooms open from.
    func documentZoomSource(
        document: UUID, surface: DocumentZoomSurface, style: DocumentZoomSourceStyle = .row
    ) -> some View {
        modifier(
            DocumentZoomSourceModifier(id: DocumentZoomSourceID(documentID: document, surface: surface), style: style))
    }

    /// Apply to a pushed editor at its `navigationDestination` site: it zooms out of `source`
    /// when there is one, and otherwise (or under Reduce Motion) uses the default push.
    func documentZoomDestination(source: DocumentZoomSourceID?, in namespace: Namespace.ID) -> some View {
        modifier(DocumentZoomDestinationModifier(source: source, namespace: namespace))
    }
}
