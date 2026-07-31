import Foundation

/// One rendered line of the pages tree: a document, how deep it sits, and
/// whether it can and does show its children.
struct PagesTreeRow: Equatable, Identifiable {
    let document: Document
    let depth: Int
    /// From the server's `numchild`, so a disclosure arrow appears without
    /// having to fetch a level first.
    let hasChildren: Bool
    let isExpanded: Bool

    var id: UUID { document.id }
}

/// Flattens the loaded tree into the rows to draw, depth-first.
///
/// Pure, and the whole layout rule lives here: a node contributes its children
/// only when it is expanded *and* they have been loaded. An expanded node whose
/// children are still in flight simply contributes nothing yet — the row itself
/// shows the spinner — so a slow level never collapses the levels above it.
///
/// `visited` guards against a cycle in the server's tree: a document that
/// somehow appears beneath itself would otherwise recurse until the stack runs
/// out. The data should never contain one; this is the same defensiveness the
/// Yjs layers apply to anything server-shaped.
func pagesTreeRows(
    parentID: UUID,
    children: [UUID: [Document]],
    expanded: Set<UUID>,
    depth: Int = 0,
    visited: Set<UUID> = []
) -> [PagesTreeRow] {
    guard !visited.contains(parentID) else { return [] }
    let visited = visited.union([parentID])

    return (children[parentID] ?? []).flatMap { document -> [PagesTreeRow] in
        let isExpanded = expanded.contains(document.id)
        let row = PagesTreeRow(
            document: document,
            depth: depth,
            hasChildren: document.numchild > 0,
            isExpanded: isExpanded
        )
        guard isExpanded else { return [row] }
        return [row]
            + pagesTreeRows(
                parentID: document.id, children: children, expanded: expanded,
                depth: depth + 1, visited: visited)
    }
}

/// The document tree behind the editor's Pages drawer.
///
/// Levels load lazily: opening the drawer fetches the root's children, and each
/// expand fetches that node's. Every level is served from
/// `DocumentChildrenCacheStore` first, which is what makes the drawer work
/// offline — it is the same store the editor's own Subpages list fills, so a
/// document you have opened already has its level cached.
@MainActor
@Observable
final class PagesTreeViewModel {
    private(set) var children: [UUID: [Document]] = [:]
    private(set) var expanded: Set<UUID> = []
    /// Parents with a fetch in flight, so a row can show progress and a second
    /// tap can't start a duplicate request.
    private(set) var loading: Set<UUID> = []
    var errorKey: L10nKey?

    let rootID: UUID
    private let client: DocsAPIClient
    private let cache: DocumentChildrenCacheStore

    init(rootID: UUID, client: DocsAPIClient, cache: DocumentChildrenCacheStore = DocumentChildrenCacheStore()) {
        self.rootID = rootID
        self.client = client
        self.cache = cache
    }

    var rows: [PagesTreeRow] {
        pagesTreeRows(parentID: rootID, children: children, expanded: expanded)
    }

    /// Loads the root level. Safe to call on every appearance — a level already
    /// loaded is refreshed silently rather than cleared and re-fetched.
    func loadRoot() async {
        await load(parentID: rootID)
    }

    func toggle(_ document: Document) async {
        if expanded.contains(document.id) {
            expanded.remove(document.id)
            return
        }
        expanded.insert(document.id)
        // Only the first expand fetches; later ones render what is already here
        // and revalidate silently.
        await load(parentID: document.id)
    }

    /// Cache first, then the network. A failed fetch keeps whatever the cache
    /// gave us and says so, rather than emptying a level the user can see.
    private func load(parentID: UUID) async {
        if children[parentID] == nil, let cached = cache.children(for: parentID) {
            children[parentID] = cached
        }
        guard !loading.contains(parentID) else { return }
        loading.insert(parentID)
        defer { loading.remove(parentID) }

        do {
            let fetched = try await client.listChildren(documentID: parentID).results
            children[parentID] = fetched
            cache.save(fetched, for: parentID)
            errorKey = nil
        } catch {
            // Never treat a failure here as the document being gone: this is a
            // *different* document's children, and the editor behind the drawer
            // must not be torn down over it.
            if children[parentID] == nil { errorKey = .pages_error_load }
        }
    }

    /// Creates a child of `parent` and slots it into the open tree, so the new
    /// page appears where it belongs instead of only after a reload.
    func addPage(under parent: UUID) async -> Document? {
        do {
            let child = try await client.createChild(documentID: parent, title: "Untitled subpage")
            expanded.insert(parent)
            children[parent, default: []].append(child)
            cache.save(children[parent] ?? [], for: parent)
            errorKey = nil
            return child
        } catch {
            errorKey = .pages_error_create
            return nil
        }
    }
}
