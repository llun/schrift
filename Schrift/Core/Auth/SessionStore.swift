import Foundation

@Observable
final class SessionStore {
    private static let serverURLKey = "dev.llun.Schrift.serverURL"
    private static let authenticatedKeychainKey = "dev.llun.Schrift.isAuthenticated"

    private let userDefaults: UserDefaults
    private let keychain: KeychainStoring

    private(set) var serverURL: URL?
    private(set) var isAuthenticated: Bool

    init(userDefaults: UserDefaults = .standard, keychain: KeychainStoring = KeychainStore()) {
        self.userDefaults = userDefaults
        self.keychain = keychain
        self.serverURL = userDefaults.url(forKey: Self.serverURLKey)
        self.isAuthenticated = (try? keychain.load(forKey: Self.authenticatedKeychainKey)) != nil
    }

    func signIn(serverURL: URL) throws {
        userDefaults.set(serverURL, forKey: Self.serverURLKey)
        try keychain.save(Data([1]), forKey: Self.authenticatedKeychainKey)
        self.serverURL = serverURL
        self.isAuthenticated = true
    }

    func signOut() throws {
        try keychain.delete(forKey: Self.authenticatedKeychainKey)
        self.isAuthenticated = false
    }
}
