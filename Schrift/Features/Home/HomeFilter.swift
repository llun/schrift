import Foundation

enum HomeFilter: Int, CaseIterable {
    case all = 0
    case shared = 1
    case pinned = 2

    var titleKey: L10nKey {
        switch self {
        case .all: return .home_filter_all
        case .shared: return .home_filter_shared
        case .pinned: return .home_filter_pinned
        }
    }
}

struct HomeFilterQueryParameters: Equatable {
    let isFavorite: Bool?
    let isCreatorMe: Bool?
}

func homeFilterQueryParameters(_ filter: HomeFilter) -> HomeFilterQueryParameters {
    switch filter {
    case .all:
        return HomeFilterQueryParameters(isFavorite: nil, isCreatorMe: nil)
    case .shared:
        return HomeFilterQueryParameters(isFavorite: nil, isCreatorMe: false)
    case .pinned:
        return HomeFilterQueryParameters(isFavorite: true, isCreatorMe: nil)
    }
}

func shouldShowPinnedSection(filter: HomeFilter, pinnedCount: Int) -> Bool {
    filter != .pinned && pinnedCount > 0
}

/// Whether a load may show the full-screen loading placeholder: only on a
/// true first run — the list was never cached (nil ≠ cached-empty) and no
/// rows are on screen. Every later load revalidates silently behind the
/// visible list. Shared by every cached list surface (Home, Shared tab).
func shouldShowLoadingPlaceholder(hasCachedList: Bool, visibleRowCount: Int) -> Bool {
    !hasCachedList && visibleRowCount == 0
}
