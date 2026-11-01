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

/// What a navigation stack's path holds for a pushed editor: the route plus the row it was
/// opened from, if any. The zoom source travels on the path element itself, so the destination
/// closure receives it with the route and it is fixed for as long as that element is on the
/// stack. Nothing parallel to the path has to be kept in step with it, and a pop, a
/// programmatic reset or state restoration cannot leave a stale answer behind.
struct DocumentPush: Hashable {
    let route: DocumentEditorRoute
    /// The row or card to grow out of. `nil` for every push that did not come from a row (deep
    /// links, page chips inside the editor, "new document") and for every push made while
    /// Reduce Motion was on.
    let zoomSource: DocumentZoomSourceID?
}

/// Build the path element for opening `route`. Reduce Motion is decided here, once, when the
/// push happens: with it on the push records no source, so the stack's default transition runs.
/// The destination only reads the stored value, so flipping the setting while an editor is
/// open changes nothing about that editor, and the next push picks the new setting up.
func documentPush(
    for route: DocumentEditorRoute, from surface: DocumentZoomSurface?, reduceMotion: Bool
) -> DocumentPush {
    let source = surface.map { DocumentZoomSourceID(documentID: route.document.id, surface: $0) }
    return DocumentPush(route: route, zoomSource: reduceMotion ? nil : source)
}

/// The transition for a pushed editor: a zoom when it was pushed with a source, otherwise the
/// stack's default push.
func documentTransitionStyle(source: DocumentZoomSourceID?) -> DocumentTransitionStyle {
    guard let source else { return .automatic }
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
    let source: DocumentZoomSourceID?
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        switch documentTransitionStyle(source: source) {
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
    /// when the push recorded one, and otherwise uses the default push. It reads no live
    /// environment, so the transition of an open editor never changes.
    func documentZoomDestination(source: DocumentZoomSourceID?, in namespace: Namespace.ID) -> some View {
        modifier(DocumentZoomDestinationModifier(source: source, namespace: namespace))
    }
}
