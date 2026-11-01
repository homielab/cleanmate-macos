import Foundation

/// Downloaded media of chat, music and podcast apps kept outside ~/Library/Caches: Telegram for macOS (photos, videos,
/// files opened in chats), Spotify (streamed songs) and Apple Podcasts (downloaded episodes, artwork). Often several
/// GB; each app downloads again what it needs, so they are deleted (regenerable), unticked, never while the app runs
/// and never a file a process has open. Never Telegram's database (`postbox/db`), keys or sign-in, Spotify's offline
/// downloads settings, nor Podcasts' library database (`Documents/MTLibrary.sqlite`: subscriptions, played state).
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

    // MARK: Apple Podcasts

    /// Apple Podcasts' group container. Privacy-protected like every group container: the items are only in the
    /// catalog with Full Disk Access.
    static let podcastsGroup = "~/Library/Group Containers/243LU875E5.groups.com.apple.podcasts"
    /// Downloaded episodes (`<UUID>.mp3`, `.m4a`…) are files directly in `Library/Cache`; its folders (`Assets/Artwork`,
    /// `Assets/StreamedMedia`, `JSStoreDataProvider`) are artwork and playback cache. Not `Library/Caches`: it holds
    /// downloads in progress (`com.apple.nsurlsessiond`) and is left alone.
    static let podcastsCache = podcastsGroup + "/Library/Cache"
    /// The app and its extensions (the widget created the container).
    static let podcastsBundleIDs = ["com.apple.podcasts*"]
    static let podcastsProcessNames = ["Podcasts", "podcastsd"]
    /// Names of downloaded episode files (audio, video; `.movpkg` = a streamed-video download package), any case.
    static let episodePatterns = ["mp3", "m4a", "m4b", "mp4", "m4v", "mov", "aac", "wav", "aif", "aiff", "caf", "flac",
                                  "movpkg"].flatMap { ["*." + $0, "*." + $0.uppercased()] }

    /// Downloaded episodes, one entry per file; Podcasts downloads an episode again when it is played.
    static let podcastEpisodes = CleanerItem(
        id: "podcasts-episodes", title: "Apple Podcasts: downloaded episodes",
        note: "Episodes are downloaded again when you play them; your subscriptions and library are kept",
        paths: [podcastsCache], included: episodePatterns, selectedByDefault: false, showsWhenEmpty: false,
        runningAppBundleIDs: podcastsBundleIDs, runningProcessNames: podcastsProcessNames, skipsOpenFiles: true)

    /// The rest of `Library/Cache`: artwork and audio cached while streaming.
    static let podcastsPlaybackCache = CleanerItem(
        id: "podcasts-cache", title: "Apple Podcasts cache",
        note: "Artwork and audio cached while streaming; downloaded again when needed",
        paths: [podcastsCache], excluded: Set(episodePatterns), selectedByDefault: false, showsWhenEmpty: false,
        runningAppBundleIDs: podcastsBundleIDs, runningProcessNames: podcastsProcessNames, skipsOpenFiles: true)

    static let podcasts = [podcastEpisodes, podcastsPlaybackCache]
}
