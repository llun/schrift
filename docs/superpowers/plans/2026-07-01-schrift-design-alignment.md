# Schrift design-system alignment

Align the app to the **Schrift iOS Design System** handoff bundle (Interactive UI kit:
`ui_kits/docs-ios/`). Decisions confirmed with user: **full alignment**, **real backend
where possible**, **full rename** (bundle id + Xcode target → Schrift).

## Phase 0 — Rename + icon  ✅ DONE
- `DocsIOS` → `Schrift` everywhere: target/module/dirs (`Schrift/`, `SchriftTests/`),
  bundle ids (`dev.llun.Schrift`, `.Tests`), `@main SchriftApp`, persistence keys,
  display name, README, `.gitignore`, `@testable import Schrift`.
- App icon: `schrift-app-icon-1024.png` (square RGB) → `AppIcon.appiconset`.
- Brand logo imageset `SchriftLogo` (rounded icon) for the Connect welcome.
- Baseline: `xcodebuild build` + `test` green (234 tests pass).

## Phase 1 — Feature screens (parallel workflow, new files, no shared-file edits)
Each builder writes ONLY new files in its own folder; does NOT run xcodegen/xcodebuild.
Screens use existing DS components + tokens (see API ref). `ListRow` has no custom
leading/trailing view slot → build small bespoke rows for Switch/Badge/Avatar/AvatarGroup.

- **A. Search** (`Schrift/Features/Search/`): `SearchViewModel` (client.searchDocuments,
  quick-access = favoriteDocuments, local recent searches), `SearchScreen`
  (`onOpenDocument: (Document)->Void`). Empty = recent-search chips + quick access;
  typing = live results / empty state. + tests.
- **B. Shared** (`Schrift/Features/Shared/`): `SharedViewModel` (listDocuments
  isCreatorMe false/true), `SharedScreen` scope segmented, bespoke rows (DocIcon +
  title + reach/date subtitle + chevron). AvatarGroup omitted (no people list on the
  list payload — deviation, avoids N+1). + tests.
- **C. Profile + Account** (`Schrift/Features/Profile/` + `Core/Networking/UserEndpoints.swift`):
  add `CurrentUser` model + `currentUser()` → `GET users/me/` (lenient/all-optional).
  `ProfileViewModel`, `ProfileScreen` (`onOpenAccount`, `onSignOut`), `AccountScreen`.
  Appearance persisted via @AppStorage + applied; Notifications/Work-offline persisted
  toggles; About = bundle version. + tests.
- **D. Editor upgrades** (`Schrift/Features/Editor/` + `Core/Networking/DocumentChildren.swift`):
  add `listChildren(documentID:)` → `documents/{id}/children/`. Header (emoji/desc +
  title + LinkReachPill + "Edited …"), Subpages section (real children → push child
  Document), slide-in `DocTreePanel` (lazy children per node), in-editor breadcrumb
  trail, formatting accessory bar (markdown inserts while editing), offline banner.
  Add `onOpenDocument: ((Document)->Void)? = nil` to `EditorView` (defaulted, non-breaking).
  Presence badge omitted (no live-collab backend — deviation). + tests.

## Phase 2 — Integration (main session, owns shared files)
- `HomeView`: switch content by tab (Schrift/Search/Shared/Profile); `NavigationPath`
  with destinations for `Document` (Editor) and an `AccountRoute`; thread `onOpenDocument`
  into Editor for subpages; tab labels/icons per design (Schrift/Search/Shared/Profile).
- `DocumentListView`: title "Schrift"; search field taps → Search tab (read-only).
- `RootView`/`AuthenticatedHomeContainer`: thread `onSignOut` (SessionStore.signOut) +
  server host to Profile; keep iPad `HomeSplitView` working.
- `ConnectView`: `SchriftLogo` image + "Welcome to Schrift" + pill sign-in button.
- Remove remaining "Docs" UI strings (Editor backTitle, etc. — owned by builder D).
- `xcodegen generate`; build + test on iPhone 17; fix compile errors.

## Honest omissions (backend has nothing — rendered faithfully or omitted)
- Live collaborator presence (no websockets/Yjs) → omitted.
- Present / Version history → omitted (no backend).
- Per-row collaborator avatars on Shared → omitted (no people list on list payload).
- Notifications push → local persisted toggle only.

## Phase 3 — Verify: build + full test suite green; launch in simulator; screenshot key screens.
