import Foundation

/// One rendered line of the pages tree: a document, how deep it sits, and
/// whether it can and does show its children.
struct PagesTreeRow: Equatable, Identifiable {
    let document: Document
    /// The level this row was reached through. Part of the row's identity, not
    /// decoration: the tree is drawn from a session-local dictionary of levels,
    /// so a document the server has since re-parented can still be cached under
    /// its old parent while the new one lists it too. Keyed on the document id
    /// alone those two rows collide in `ForEach`, which is undefined behaviour;
    /// keyed on the pair they are simply two rows, as they appear.
    let parentID: UUID
    let depth: Int
    /// From the server's `numchild`, so a disclosure arrow appears without
    /// having to fetch a level first.
    let hasChildren: Bool
    let isExpanded: Bool

    var id: TreePath { TreePath(parentID: parentID, documentID: document.id) }

    struct TreePath: Hashable {
        let parentID: UUID
        let documentID: UUID
    }
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
            parentID: parentID,
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
    /// Levels whose fetch failed with nothing cached to fall back on. Per node,
    /// not one shared flag: a success anywhere else in the tree must not clear a
    /// message about a level the user is still looking at.
    private(set) var failedLoads: Set<UUID> = []
    /// A failed *create*, which is about the action rather than any one level.
    private(set) var createErrorKey: L10nKey?

    /// The one message the drawer shows. A failed create is the more recent and
    /// more explicit of the two, so it wins.
    var errorKey: L10nKey? {
        createErrorKey ?? (failedLoads.isEmpty ? nil : .pages_error_load)
    }

    let rootID: UUID
    private let client: DocsAPIClient
    private let cache: DocumentChildrenCacheStore
    private let userDefaults: UserDefaults
    /// Per level, bumped by anything that edits it locally. A fetch captures it
    /// before awaiting and drops its result if it changed, so a snapshot taken
    /// before a create can't overwrite the level the create just added to.
    private var mutations: [UUID: Int] = [:]

    init(
        rootID: UUID,
        client: DocsAPIClient,
        cache: DocumentChildrenCacheStore = DocumentChildrenCacheStore(),
        userDefaults: UserDefaults = .standard
    ) {
        self.rootID = rootID
        self.client = client
        self.cache = cache
        self.userDefaults = userDefaults
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
        // "Work offline" (Profile > Preferences): serve the cached tree and
        // never hit the network, the same contract the document lists honour.
        // Read through the injected defaults, never the singleton.
        guard !userDefaults.bool(forKey: "schrift.workOffline") else { return }
        guard !loading.contains(parentID) else { return }
        loading.insert(parentID)
        defer { loading.remove(parentID) }

        let mutation = mutations[parentID] ?? 0
        do {
            let fetched = try await client.listChildren(documentID: parentID).results
            // A create landed while this was in flight, so this snapshot
            // predates the new child: dropping it keeps the child on screen.
            guard mutation == mutations[parentID] ?? 0 else { return }
            children[parentID] = fetched
            cache.save(fetched, for: parentID)
            failedLoads.remove(parentID)
        } catch {
            // Never treat a failure here as the document being gone: this is a
            // *different* document's children, and the editor behind the drawer
            // must not be torn down over it.
            guard children[parentID] == nil else { return }
            failedLoads.insert(parentID)
            // Collapse it again. Left expanded it would render as a node with no
            // children — indistinguishable from a leaf, and with no way back —
            // whereas collapsed it keeps its arrow, and tapping that is the retry.
            expanded.remove(parentID)
        }
    }

    /// Creates a child of `parent` and slots it into the open tree, so the new
    /// page appears where it belongs instead of only after a reload.
    func addPage(under parent: UUID) async -> Document? {
        let child: Document
        do {
            child = try await client.createChild(documentID: parent, title: "Untitled subpage")
        } catch {
            createErrorKey = .pages_error_create
            return nil
        }
        // Any fetch already in flight for this level predates the child.
        mutations[parent, default: 0] += 1
        expanded.insert(parent)
        // Only when the level is actually known (fetched or cached). Appending
        // to an unknown one would show — and durably cache — a fabricated
        // one-item level that hides the document's real children; the cache is
        // shared with the editor's own Subpages list, so that lie outlives the
        // drawer. Same rule, and the same reason, as `EditorViewModel.addSubpage`.
        if var updated = children[parent] {
            updated.append(child)
            children[parent] = updated
            cache.save(updated, for: parent)
        }
        createErrorKey = nil
        return child
    }
}
