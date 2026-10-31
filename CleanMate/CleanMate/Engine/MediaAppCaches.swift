import Foundation

/// Downloaded media of chat and music apps kept outside ~/Library/Caches: Telegram for macOS (photos, videos, files
/// opened in chats) and Spotify (streamed songs). Often several GB; each app downloads again what it needs, so they
/// are deleted (regenerable), unticked, never while the app runs and never a file a process has open. Never
/// Telegram's database (`postbox/db`), keys or sign-in, nor Spotify's offline downloads settings.
nonisolated enum MediaAppCaches {
    // MARK: Telegram

    /// Shared group container of Telegram for macOS (App Store and direct builds). Privacy-protected: the item is only
    /// in the catalog with Full Disk Access.
    static let telegramGroup = "~/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram"
    static let telegramBundleIDs = ["ru.keepcoder.Telegram*", "org.telegram.desktop*"]
    static let telegramProcessNames = ["Telegram"]

    /// Each account's media store and cache in every release channel (`appstore`, `stable`, `beta`…).
    static let telegram = CleanerItem(
        id: "telegram-media-cache", title: "Telegram media cache",
        note: "Photos, videos and files from chats are downloaded again when opened; your chats and sign-in are kept",
        paths: [telegramGroup + "/*/account-*/postbox/media", telegramGroup + "/*/account-*/cache"],
        selectedByDefault: false, showsWhenEmpty: false, runningAppBundleIDs: telegramBundleIDs,
        runningProcessNames: telegramProcessNames, skipsOpenFiles: true)

    // MARK: Spotify

    static let spotifyBundleIDs = ["com.spotify.client*"]
    static let spotifyProcessNames = ["Spotify"]

    /// Spotify's streaming cache. Songs downloaded for offline use are in `PersistentCache/Storage` too, so the note
    /// says so.
    static let spotify = CleanerItem(
        id: "spotify-storage", title: "Spotify stream cache",
        note: "Songs are streamed again when played; songs downloaded for offline use must be downloaded again",
        paths: ["~/Library/Application Support/Spotify/PersistentCache/Storage"],
        selectedByDefault: false, showsWhenEmpty: false, runningAppBundleIDs: spotifyBundleIDs,
        runningProcessNames: spotifyProcessNames, skipsOpenFiles: true)
}
