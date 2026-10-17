import Foundation

/// Remembers when a screen last loaded successfully, so a passive re-appearance (a tab switch, a
/// pop-back) within `window` does not repeat a fetch whose answer is already on screen.
///
/// Keyed on the availability token as well: a reconnect, a Work Offline flip or any other token
/// change is a reason to ask again regardless of age. Pull-to-refresh and the post-mutation
/// reloads (migration, replay, delete) call `load()` directly and never consult this.
struct LoadFreshness<Token: Equatable> {
    /// Long enough to absorb tab flipping, short enough that a co-author's edit is picked up on
    /// the next visit after half a minute.
    static var defaultWindow: TimeInterval { 30 }

    let window: TimeInterval
    private var lastSuccess: (at: Date, token: Token)?

    init(window: TimeInterval = 30) {
        self.window = window
    }

    mutating func noteSuccess(token: Token, at now: Date) {
        lastSuccess = (now, token)
    }

    /// True when the last success was under `window` ago and under the same token.
    func isFresh(token: Token, at now: Date) -> Bool {
        guard let lastSuccess, lastSuccess.token == token else { return false }
        let age = now.timeIntervalSince(lastSuccess.at)
        return age >= 0 && age < window
    }
}
