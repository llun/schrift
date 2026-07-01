import Foundation

enum HomeFilter: Int, CaseIterable {
    case all = 0
    case shared = 1
    case pinned = 2

    var title: String {
        switch self {
        case .all: return "All"
        case .shared: return "Shared"
        case .pinned: return "Pinned"
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
