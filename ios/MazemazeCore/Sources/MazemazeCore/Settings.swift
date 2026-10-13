import Foundation

/// Preferences live in UserDefaults (this iPhone only; there is no account, no token and no server).
public final class SettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    enum Key {
        static let ratio = "mazemaze.ratio"
        static let unit = "mazemaze.unit"
        static let enabled = "mazemaze.enabled"
        static let hosts = "mazemaze.allowedHosts"
        static let restoreTabs = "mazemaze.restoreTabs"
        static let safariIdentityForX = "mazemaze.safariIdentityForX"
        static let autoHideBars = "mazemaze.autoHideBars"
        static let embedDictionary = "mazemaze.embedDictionary"
        static let autoMeaning = "mazemaze.autoMeaning"
        static let translationEngine = "mazemaze.engine.translation"
        static let searchEngine = "mazemaze.searchEngine"
        static let lastBackupExport = "mazemaze.lastBackupExport"
        static let embedDictionaryCrashed = "mazemaze.embedDictionaryCrashed"
        static let recents = "mazemaze.recentsEnabled"
        static let tabs = "mazemaze.tabs.v1"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var ratio: Double {
        get { let v = defaults.double(forKey: Key.ratio); return v == 0 ? 0.3 : min(max(v, 0.1), 0.7) }
        set { defaults.set(min(max(newValue, 0.1), 0.7), forKey: Key.ratio) }
    }
    public var unit: TranslationUnit {
        get { TranslationUnit(rawValue: defaults.string(forKey: Key.unit) ?? "") ?? .phrase }
        set { defaults.set(newValue.rawValue, forKey: Key.unit) }
    }
    public var translationEnabled: Bool {
        get { defaults.object(forKey: Key.enabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }
    /// Reopen the tabs of the last session (only pages that are safe to store; see SessionPrivacy).
    /// On by default (owner's decision, 2026-10-09): X is opened with a Safari-style user agent.
    public var safariIdentityForX: Bool {
        get { defaults.object(forKey: Key.safariIdentityForX) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.safariIdentityForX) }
    }

    /// When the person last wrote a backup file out (nil: never). Only used to say so in the settings.
    public var lastBackupExport: Date? {
        get { (defaults.object(forKey: Key.lastBackupExport) as? Double).map(Date.init(timeIntervalSince1970:)) }
        set { if let newValue { defaults.set(newValue.timeIntervalSince1970, forKey: Key.lastBackupExport) } else { defaults.removeObject(forKey: Key.lastBackupExport) } }
    }

    /// Where the address bar searches words (Google by default).
    public var searchEngine: SearchEngine {
        get { defaults.string(forKey: Key.searchEngine).flatMap(SearchEngine.init(rawValue:)) ?? .google }
        set { defaults.set(newValue.rawValue, forKey: Key.searchEngine) }
    }

    /// Which engine translates pages (Apple Translation by default). Both run inside the iPhone.
    public var translationEngine: TranslationEngineKind {
        get { defaults.string(forKey: Key.translationEngine).flatMap(TranslationEngineKind.init(rawValue:)) ?? .appleTranslation }
        set { defaults.set(newValue.rawValue, forKey: Key.translationEngine) }
    }

    /// A word saved from the iPhone's dictionary gets its meaning looked up in the background (on by default).
    public var autoMeaning: Bool {
        get { defaults.object(forKey: Key.autoMeaning) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.autoMeaning) }
    }

    /// Show the iPhone's dictionary inside the lookup sheet (on by default). It switches itself off if the app ever died while
    /// showing it, and says so (`embedDictionaryCrashed`); the person can switch it on again.
    public var embedDictionary: Bool {
        get { defaults.object(forKey: Key.embedDictionary) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.embedDictionary); if newValue { defaults.set(false, forKey: Key.embedDictionaryCrashed) } }
    }
    public var embedDictionaryCrashed: Bool {
        get { defaults.bool(forKey: Key.embedDictionaryCrashed) }
        set { defaults.set(newValue, forKey: Key.embedDictionaryCrashed) }
    }

    /// The address bar and toolbar slide away while reading (scroll down) and return on scrolling up. On by default.
    public var autoHideBars: Bool {
        get { defaults.object(forKey: Key.autoHideBars) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.autoHideBars) }
    }

    public var restoreTabs: Bool {
        get { defaults.object(forKey: Key.restoreTabs) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.restoreTabs) }
    }
    /// Remember recently opened (safe, public) sites for the home screen.
    public var recentsEnabled: Bool {
        get { defaults.object(forKey: Key.recents) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.recents) }
    }
    public var savedTabsData: Data? {
        get { defaults.data(forKey: Key.tabs) }
        set { if let newValue { defaults.set(newValue, forKey: Key.tabs) } else { defaults.removeObject(forKey: Key.tabs) } }
    }
    public var userDefaults: UserDefaults { defaults }
    /// Ask the system to write preferences to disk now (they are normally written a little later, and a
    /// force-quit right after a change could lose it). Called after tab and bookmark changes.
    public func flush() { defaults.synchronize() }

    public var allowedHosts: [String] {
        get { (defaults.array(forKey: Key.hosts) as? [String]).map { $0.compactMap(SitePolicy.normalizeEntry) } ?? SitePolicy.defaultAllowedHosts }
        set { defaults.set(newValue.compactMap(SitePolicy.normalizeEntry), forKey: Key.hosts) }
    }
}
