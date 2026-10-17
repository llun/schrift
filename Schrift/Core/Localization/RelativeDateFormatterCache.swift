import Foundation

/// One abbreviated `RelativeDateTimeFormatter` per locale, shared by the row
/// dates and the editor's sync caption.
///
/// Both used to build a formatter on every call — once per document row per
/// render — and creating one is far costlier than using it. The formatter is
/// not `Sendable`, so every access goes through one lock (formatting included,
/// since a shared formatter is not guaranteed safe to call concurrently).
final class RelativeDateFormatterCache: @unchecked Sendable {
    static let shared = RelativeDateFormatterCache()

    private let lock = NSLock()
    private var formatters: [String: RelativeDateTimeFormatter] = [:]

    init() {}

    /// The cached formatter for `locale`; the same instance on every call.
    func formatter(for locale: Locale) -> RelativeDateTimeFormatter {
        lock.lock()
        defer { lock.unlock() }
        return locked(locale)
    }

    /// `date` relative to `now`, abbreviated, in `locale`.
    func string(for date: Date, relativeTo now: Date, locale: Locale) -> String {
        lock.lock()
        defer { lock.unlock() }
        return locked(locale).localizedString(for: date, relativeTo: now)
    }

    private func locked(_ locale: Locale) -> RelativeDateTimeFormatter {
        if let cached = formatters[locale.identifier] { return cached }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = locale
        formatters[locale.identifier] = formatter
        return formatter
    }
}
