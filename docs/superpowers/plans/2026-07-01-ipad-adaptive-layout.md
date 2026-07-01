# iPad Adaptive Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement design spec Phase 9 — an iPad adaptive layout using `NavigationSplitView` (document list sidebar + detail/editor pane) on regular-width size classes, while preserving the existing iPhone single-column `NavigationStack` behavior unchanged on compact-width size classes.

**Architecture:** Every design decision here was validated end-to-end against this machine's Xcode 26.6/iOS 26.5 toolchain in a scratch project before being written into this plan — including builds and Simulator screenshots on both an iPhone destination (`iPhone 17`) and an iPad destination (`iPad Pro 11-inch (M5)`, the iOS-26.5-runtime iPad closest in generation to the iPhone destination already used by every prior plan).

- **The document list's body (search field, segmented filter, pinned/recent sections, favorite confirmation dialog) is extracted into a new `DocumentListView`**, shared between the iPhone and iPad layouts instead of duplicated. It takes an `onSelect: (Document) -> Void` closure instead of directly mutating a navigation path, so the same view works whether tapping a row should push (iPhone) or set a split-view selection (iPad). `HomeView` (iPhone) still owns the `NavigationStack` + `TabBar` + `navigationDestination` chrome around it; the new `HomeSplitView` (iPad) uses it as the `NavigationSplitView` sidebar.
- **`HomeSplitView`'s detail pane switches between `EditorView` (a document is selected) and `ContentUnavailableView("Select a Document", ...)` (nothing selected yet)** — matching the design spec's "document list sidebar + detail/editor pane" description. `EditorView` already accepts `onBack: (() -> Void)? = nil`; verified directly in the Simulator that passing no `onBack` (as the detail pane does — there is no back button in a split view, the sidebar stays visible) renders `NavBar` cleanly with no gap or broken back-button element, since `NavBar` only renders the back button when both `backTitle` and `onBack` are non-nil.
- **Switching to a different selected document while one is already open needs `EditorView.id(selectedDocument.id)`** — without it, `EditorView`'s `@Bindable var viewModel: EditorViewModel` gets a new `EditorViewModel` instance on every body re-evaluation (since it's constructed inline from `selectedDocument`), but SwiftUI's `.task` (which triggers the actual content load) only re-runs when the view's *identity*, not just its data, changes. `.id(selectedDocument.id)` forces that identity change on document switch, so `.task` reliably reloads.
- **A real, non-obvious bug found and fixed during scratch validation, not by a failing test:** `RootView`'s original body created `HomeViewModel` inline (`HomeView(viewModel: HomeViewModel(client: ...), ...)`). This was safe before this plan because `RootView`'s body only re-evaluated when `sessionStore`'s own observed properties changed (which don't change once authenticated). Adding `@Environment(\.horizontalSizeClass)` to decide between `HomeView`/`HomeSplitView` means `RootView`'s body now also re-evaluates on every size-class transition (e.g., iPad multitasking Split View resize) — which would have silently recreated `HomeViewModel` (and its `DocsAPIClient`), discarding the loaded document list and search state, on every such resize. Fixed by extracting a private `AuthenticatedHomeContainer` view that owns `@State private var viewModel: HomeViewModel`, initialized exactly once via a custom `init(serverURL:)`, so the same view model instance survives size-class changes and is merely handed to whichever of `HomeView`/`HomeSplitView` the current size class calls for.
- **`horizontalSizeClass == .regular` is the split point**, matching Apple's standard adaptive-layout idiom (this is `.regular` on a full-screen iPad in both portrait and landscape on all current iPad models, and `.compact` on iPhone and on narrow iPad multitasking/Slide Over widths) — no custom width thresholds.

**Tech Stack:** Swift 6.0, SwiftUI, XCTest, XcodeGen 2.45 (Homebrew), Xcode 26.6 / iOS 26.5 SDK, deployment target iOS 18.0.

## Global Constraints

- Deployment target: iOS 18.0, universal app.
- Zero third-party Swift package dependencies.
- `project.yml` is the single source of truth; regenerate via `xcodegen generate` after adding any new file, **before** building/testing.
- Verified local build/test destinations: `-destination 'platform=iOS Simulator,name=iPhone 17'` (iPhone) and `-destination 'id=39CD8A98-B7AA-4914-ACD0-7CCB6068A399'` (the `iPad Pro 11-inch (M5)` simulator, iOS 26.5 runtime — look it up fresh with `xcrun simctl list devices available` if this UDID is no longer present on the build machine, matching by `iPad Pro 11-inch (M5)` name and the same iOS runtime as the iPhone destination; do not use a same-named iPad on an older runtime, there are multiple `iPad Pro 11-inch` simulators installed on different OS versions).
- Each task ends in its own commit.
- A benign toolchain warning — `warning: Metadata extraction skipped. No AppIntents.framework dependency found.` — appears in every build regardless of code changes. Ignore it.
- `DocumentListView` must take an `onSelect: (Document) -> Void` closure, not directly reference a navigation path or selection state — it is shared by both `HomeView` (push) and `HomeSplitView` (selection), which handle the tap differently.
- `HomeViewModel` must be created exactly once per authenticated session and must survive `horizontalSizeClass` changes — do not construct it inline inside a view body that also reads `@Environment(\.horizontalSizeClass)`.
- `EditorView` in the split-view detail pane must use `.id(selectedDocument.id)` so switching the selected document reliably re-triggers `.task`-driven content loading.
- Task 2 has no new XCTest files by design — it is UI glue verified by build-check (both iPhone and iPad destinations) and Simulator screenshots. If `RootView.swift` is temporarily swapped for screenshots, it MUST be reverted to the real auth-gated version before committing — never commit a temporary version.

## File Structure

```
DocsIOS/
├── App/
│   └── RootView.swift                                   — MODIFY: AuthenticatedHomeContainer, horizontalSizeClass branch (Task 2)
└── Features/
    └── Home/
        ├── DocumentListView.swift                        — DocumentListView (Task 1)
        ├── HomeView.swift                                — MODIFY: use DocumentListView, drop inlined list body (Task 1)
        └── HomeSplitView.swift                            — HomeSplitView (Task 2)
```

---

### Task 1: Extract DocumentListView from HomeView

**Files:**
- Create: `DocsIOS/Features/Home/DocumentListView.swift`
- Modify: `DocsIOS/Features/Home/HomeView.swift`

**Interfaces:**
- Consumes: `HomeViewModel`, `HomeFilter`, `Document`, `NavBar`, `SearchField`, `SegmentedControl`, `ListSection`, `DocRow` (earlier plans).
- Produces: `struct DocumentListView: View` (`init(viewModel:serverHost:onSelect:)`) — consumed by `HomeView` in this task and by Task 2's `HomeSplitView`. `documentRowDate(_:)` stays in `HomeView.swift` (unchanged location, still used by `DocumentListView`).

This is a pure refactor: `DocumentListView`'s body is `HomeView`'s current body content from `NavBar` through the `ScrollView`'s document sections, including the favorite `confirmationDialog`, `.task { await viewModel.load() }`, and `.onChange(of: viewModel.searchQuery)` — moved verbatim, with `path.append(document)` replaced by calling the new `onSelect(document)` closure. `HomeView`'s iPhone behavior must be pixel-for-pixel identical after this refactor — this task has no XCTest changes because the underlying behavior (documented and tested via `HomeViewModel`'s own existing tests) is unchanged, only which view struct contains the code.

- [ ] **Step 1: Write the implementation**

`DocsIOS/Features/Home/DocumentListView.swift`:
```swift
import SwiftUI

struct DocumentListView: View {
    @Bindable var viewModel: HomeViewModel
    let serverHost: String
    var onSelect: (Document) -> Void

    @State private var documentPendingFavoriteChoice: Document?

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: "Docs", subtitle: serverHost, largeTitle: true)

            VStack(spacing: DocsSpacing.spaceSM) {
                SearchField(text: $viewModel.searchQuery, placeholder: "Search documents")

                SegmentedControl(
                    segments: HomeFilter.allCases.map(\.title),
                    selectedIndex: Binding(
                        get: { viewModel.selectedFilter.rawValue },
                        set: { newValue in
                            let filter = HomeFilter(rawValue: newValue) ?? .all
                            Task { await viewModel.selectFilter(filter) }
                        }
                    )
                )
            }
            .padding(.horizontal, DocsSpacing.gutter)
            .padding(.vertical, DocsSpacing.spaceSM)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(DocsFont.footnote)
                    .foregroundStyle(DocsColor.danger)
                    .padding(.horizontal, DocsSpacing.gutter)
            }

            ScrollView {
                if viewModel.isLoading {
                    ProgressView()
                        .padding(DocsSpacing.spaceBase)
                } else if !viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    documentSection(title: "Search Results", documents: viewModel.searchResults)
                } else {
                    if viewModel.showsPinnedSection {
                        documentSection(title: "Pinned", documents: viewModel.pinnedDocuments)
                    }
                    documentSection(title: "Recent", documents: viewModel.recentDocuments)
                }
            }
        }
        .background(DocsColor.surfacePage)
        .task {
            await viewModel.load()
        }
        .onChange(of: viewModel.searchQuery) {
            Task { await viewModel.search() }
        }
        .confirmationDialog(
            "Document Options",
            isPresented: Binding(
                get: { documentPendingFavoriteChoice != nil },
                set: { if !$0 { documentPendingFavoriteChoice = nil } }
            ),
            presenting: documentPendingFavoriteChoice
        ) { document in
            Button(document.isFavorite ? "Unpin" : "Pin") {
                Task { await viewModel.toggleFavorite(document) }
            }
        }
    }

    @ViewBuilder
    private func documentSection(title: String, documents: [Document]) -> some View {
        if !documents.isEmpty {
            ListSection(header: title) {
                VStack(spacing: 0) {
                    ForEach(documents) { document in
                        DocRow(
                            emoji: nil,
                            title: document.title ?? "Untitled document",
                            pinned: document.isFavorite,
                            reach: document.linkReach,
                            date: documentRowDate(document),
                            onOpen: { onSelect(document) },
                            onMore: { documentPendingFavoriteChoice = document }
                        )
                    }
                }
            }
        }
    }
}

#Preview {
    DocumentListView(
        viewModel: HomeViewModel(client: DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!)),
        serverHost: "docs.llun.dev",
        onSelect: { _ in }
    )
}
```

`DocsIOS/Features/Home/HomeView.swift` — replace entirely with:
```swift
import SwiftUI

func documentRowDate(_ document: Document) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: document.updatedAt, relativeTo: Date())
}

struct HomeView: View {
    @Bindable var viewModel: HomeViewModel
    let serverHost: String

    @State private var selectedTab = "docs"
    @State private var path: [Document] = []

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                DocumentListView(viewModel: viewModel, serverHost: serverHost, onSelect: { path.append($0) })

                TabBar(items: [
                    TabBarItem(value: "docs", label: "Docs", systemImage: "doc.text"),
                    TabBarItem(value: "search", label: "Search", systemImage: "magnifyingglass"),
                    TabBarItem(value: "shared", label: "Shared", systemImage: "person.2"),
                    TabBarItem(value: "me", label: "Profile", systemImage: "person.crop.circle"),
                ], selection: $selectedTab)
            }
            .background(DocsColor.surfacePage)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Document.self) { document in
                EditorView(
                    viewModel: EditorViewModel(
                        client: viewModel.client,
                        documentID: document.id,
                        title: document.title ?? "Untitled document"
                    ),
                    reach: document.linkReach,
                    serverHost: serverHost,
                    linkRole: document.linkRole,
                    initialIsFavorite: document.isFavorite,
                    onBack: { path.removeLast() },
                    onDeleted: {
                        path.removeLast()
                        Task { await viewModel.load() }
                    }
                )
                .toolbar(.hidden, for: .navigationBar)
            }
        }
    }
}

#Preview {
    HomeView(viewModel: HomeViewModel(client: DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!)), serverHost: "docs.llun.dev")
}
```

- [ ] **Step 2: Regenerate, build, and run the full test suite**

Run: `xcodegen generate && xcodebuild build -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** BUILD SUCCEEDED **`

Run: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** TEST SUCCEEDED **` with `Executed 221 tests, with 0 failures` (no new tests in this task — pure refactor, iPhone behavior unchanged).

- [ ] **Step 3: Commit**

```bash
git add DocsIOS/Features/Home/DocumentListView.swift DocsIOS/Features/Home/HomeView.swift
git commit -m "Extract DocumentListView from HomeView"
```

---

### Task 2: HomeSplitView + RootView adaptive wiring

**Files:**
- Create: `DocsIOS/Features/Home/HomeSplitView.swift`
- Modify: `DocsIOS/App/RootView.swift`

**Interfaces:**
- Consumes: `DocumentListView` (Task 1), `EditorView`, `EditorViewModel`, `HomeViewModel` (earlier plans).
- Produces: `struct HomeSplitView: View` (`init(viewModel:serverHost:)`); `RootView` gains a private `AuthenticatedHomeContainer` that owns the `HomeViewModel` and branches between `HomeView`/`HomeSplitView` on `horizontalSizeClass`.

This task has no new XCTest files — same rationale as prior UI-wiring tasks (Home Screen, Editor Screen, Share Sheet, Options Sheet plans).

- [ ] **Step 1: Write the implementation**

`DocsIOS/Features/Home/HomeSplitView.swift`:
```swift
import SwiftUI

struct HomeSplitView: View {
    @Bindable var viewModel: HomeViewModel
    let serverHost: String

    @State private var selectedDocument: Document?

    var body: some View {
        NavigationSplitView {
            DocumentListView(viewModel: viewModel, serverHost: serverHost, onSelect: { selectedDocument = $0 })
        } detail: {
            if let selectedDocument {
                EditorView(
                    viewModel: EditorViewModel(
                        client: viewModel.client,
                        documentID: selectedDocument.id,
                        title: selectedDocument.title ?? "Untitled document"
                    ),
                    reach: selectedDocument.linkReach,
                    serverHost: serverHost,
                    linkRole: selectedDocument.linkRole,
                    initialIsFavorite: selectedDocument.isFavorite,
                    onDeleted: {
                        self.selectedDocument = nil
                        Task { await viewModel.load() }
                    }
                )
                .id(selectedDocument.id)
            } else {
                ContentUnavailableView("Select a Document", systemImage: "doc.text")
                    .background(DocsColor.surfacePage)
            }
        }
    }
}

#Preview {
    HomeSplitView(viewModel: HomeViewModel(client: DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!)), serverHost: "docs.llun.dev")
}
```

`DocsIOS/App/RootView.swift` — replace entirely with:
```swift
import SwiftUI

private struct AuthenticatedHomeContainer: View {
    @State private var viewModel: HomeViewModel
    let serverHost: String

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(serverURL: URL) {
        _viewModel = State(initialValue: HomeViewModel(client: DocsAPIClient(baseURL: serverURL.appendingPathComponent("api/v1.0/"))))
        serverHost = serverURL.host ?? ""
    }

    var body: some View {
        if horizontalSizeClass == .regular {
            HomeSplitView(viewModel: viewModel, serverHost: serverHost)
        } else {
            HomeView(viewModel: viewModel, serverHost: serverHost)
        }
    }
}

struct RootView: View {
    @State private var sessionStore = SessionStore()
    @State private var recentServers = RecentServersStore()

    var body: some View {
        if sessionStore.isAuthenticated, let serverURL = sessionStore.serverURL {
            AuthenticatedHomeContainer(serverURL: serverURL)
        } else {
            ConnectView(viewModel: ConnectViewModel(sessionStore: sessionStore, recentServers: recentServers))
        }
    }
}

#Preview {
    RootView()
}
```

- [ ] **Step 2: Regenerate, build, and run the full test suite on both destinations**

Run: `xcodegen generate && xcodebuild build -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** BUILD SUCCEEDED **`

Run: `xcodebuild build -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'id=39CD8A98-B7AA-4914-ACD0-7CCB6068A399'` (look up the current `iPad Pro 11-inch (M5)` UDID on the iOS-26.5 runtime with `xcrun simctl list devices available` if this one is no longer present)
Expected: `** BUILD SUCCEEDED **`

Run: `xcodebuild test -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** TEST SUCCEEDED **` with `Executed 221 tests, with 0 failures` (no new tests in this task).

- [ ] **Step 3: Visually verify in the Simulator**

Temporarily point `RootView.body` at a `HomeSplitView` with sample data (matching this plan's own validation — see Architecture), build and run on the iPad destination, screenshot, then revert `RootView.swift` back to the real auth-gated version **before committing**:

```bash
xcrun simctl bootstatus <ipad-udid> -b || xcrun simctl boot <ipad-udid> || true
xcodebuild build -project DocsIOS.xcodeproj -scheme DocsIOS -destination 'id=<ipad-udid>'
APP_PATH=$(ls -dt ~/Library/Developer/Xcode/DerivedData/DocsIOS-*/Build/Products/Debug-iphonesimulator/DocsIOS.app | head -1)
xcrun simctl install <ipad-udid> "$APP_PATH"
xcrun simctl launch <ipad-udid> dev.llun.DocsIOS
xcrun simctl io <ipad-udid> screenshot /tmp/ipad-split-verify.png
```
Expected: the screenshot shows a two-column `NavigationSplitView` — sidebar with the "Docs" `NavBar`, search field, segmented filter, and document sections; detail pane showing "Select a Document" (`ContentUnavailableView`) when nothing is selected. Also verify (e.g. by constructing an `EditorView` directly with no `onBack` in a scratch `RootView` swap) that the detail pane's `NavBar` renders cleanly with no stray back-button gap when a document is selected.

- [ ] **Step 4: Commit**

```bash
git add DocsIOS/Features/Home/HomeSplitView.swift DocsIOS/App/RootView.swift
git commit -m "Add iPad adaptive layout with NavigationSplitView"
```

## Self-Review Notes

- **Spec coverage:** Implements design spec Phase 9 in full — `NavigationSplitView` (document list sidebar + detail/editor pane) on iPad/regular-width, `NavigationStack` single-column preserved unchanged on iPhone/compact-width.
- **Real-device-class cross-check:** Both the iPhone and iPad layouts were built and the iPad layout was screenshotted end-to-end against this machine's Xcode 26.6/iOS 26.5 toolchain before being written into this plan — not just assumed to compile from reading `NavigationSplitView`'s API alone.
- **Real bug caught and fixed during validation, not by a failing test:** `RootView`'s original inline `HomeViewModel` construction would have silently reset document-list state on every iPad multitasking size-class change once `horizontalSizeClass` was added to `RootView`'s body — fixed with the `AuthenticatedHomeContainer` pattern (see Architecture) before it ever shipped.
- **Placeholder scan:** No TBD/TODO. The empty detail-pane state (`ContentUnavailableView("Select a Document", ...)`) is an intentional, specified state, not a placeholder.
- **Type consistency:** `DocumentListView`, `HomeSplitView`, `AuthenticatedHomeContainer` are each defined once. `DocumentListView` is shared verbatim between `HomeView` and `HomeSplitView` rather than duplicated.
- **Cross-file validation:** All code in this plan (both tasks, including the `DocumentListView` extraction verified to preserve iPhone behavior via the full existing test suite, the `AuthenticatedHomeContainer` state-preservation fix, and Simulator screenshots of both the populated split-view sidebar/empty-detail state and a directly-constructed `EditorView` with no `onBack` in the detail-pane position) was compiled, test-run, and visually verified end-to-end against this machine's Xcode 26.6/iOS 26.5 toolchain before being written into this plan — final state matches `Executed 221 tests, with 0 failures` on iPhone, a successful build on iPad, plus passing Simulator screenshots of both layouts.
