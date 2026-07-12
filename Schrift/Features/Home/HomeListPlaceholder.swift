import Foundation

/// Whether a load may show the full-screen loading placeholder: only on a
/// true first run — the list was never cached (nil ≠ cached-empty) and no
/// rows are on screen. Every later load revalidates silently behind the
/// visible list. Shared by every cached list surface (Home, Shared tab).
func shouldShowLoadingPlaceholder(hasCachedList: Bool, visibleRowCount: Int) -> Bool {
    !hasCachedList && visibleRowCount == 0
}
