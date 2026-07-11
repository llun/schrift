import SwiftUI

/// The user's chosen appearance for the app — light, dark, or following the
/// system setting. Persisted by `AppearanceStore`.
enum AppAppearance: String, CaseIterable, Sendable {
    case system, light, dark

    /// The `ColorScheme` to force via `.preferredColorScheme(_:)`, or `nil` to
    /// let the system decide.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// Material icon representing this appearance in pickers/toggles.
    var icon: MaterialIcon {
        switch self {
        case .system: .contrast
        case .light: .light_mode
        case .dark: .dark_mode
        }
    }
}

/// Persists the user's chosen `AppAppearance` in UserDefaults under
/// `schrift.appearance`, defaulting to `.system`.
@MainActor
@Observable
final class AppearanceStore {
    var selected: AppAppearance {
        didSet { userDefaults.set(selected.rawValue, forKey: Self.key) }
    }

    private let userDefaults: UserDefaults
    private static let key = "schrift.appearance"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let raw = userDefaults.string(forKey: Self.key)
        selected = raw.flatMap(AppAppearance.init(rawValue:)) ?? .system
    }
}
