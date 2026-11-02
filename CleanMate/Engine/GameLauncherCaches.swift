import Foundation

/// Caches and logs game launchers keep in `~/Library/Application Support`: web caches, downloaded store and library
/// artwork, update manifests, logs and crash dumps, 0.5–3 GB on a Mac with Steam. The launcher downloads or writes them
/// again, so they are ticked and deleted; each folder is emptied and kept. One item per launcher, skipped while it (or
/// one of its helpers) runs. Installed games, downloads in progress, saves, settings and sign-ins are never listed.
/// What the launchers keep in `~/Library/Caches` and `~/Library/Logs` is left to "User caches" and "User logs", so
/// nothing is counted twice.
nonisolated enum GameLauncherCaches {
    static let note: LocalizedStringResource = "Downloaded again by the launcher; games, saves and sign-ins are kept"

    // MARK: Steam

    static let steamRoot = "~/Library/Application Support/Steam"
    static let steamBundleIDs = ["com.valvesoftware.steam", "com.valvesoftware.steam.*"]
    /// The client (`steam_osx`) and its web helper (`Steam Helper`, `Steam Helper (Renderer)`…, `steamwebhelper`).
    static let steamProcessNames = ["steam_osx", "Steam Helper*", "steamwebhelper"]

    /// Web and HTTP caches, library artwork (custom artwork lives in `userdata/*/config/grid`), depot manifests Steam
    /// downloads again before an update, logs, crash dumps and compiled shaders. Never `steamapps/common` (games),
    /// `steamapps/*.acf`, `steamapps/downloading` (resumable downloads), `steamapps/workshop`, `userdata` (saves,
    /// settings), `config` beyond its `htmlcache`, `ssfn*` (sign-in), `appcache/appinfo.vdf` nor `Steam.AppBundle`.
    static let steam = CleanerItem(
        id: "steam-cache", title: appName("Steam"), note: note,
        paths: ["htmlcache", "config/htmlcache", "appcache/httpcache", "appcache/librarycache", "depotcache", "logs",
                "dumps", "steamapps/shadercache"].map { steamRoot + "/" + $0 },
        showsWhenEmpty: false, runningAppBundleIDs: steamBundleIDs, runningProcessNames: steamProcessNames,
        skipsOpenFiles: true)

    // MARK: Epic Games Launcher

    static let epicSaved = "~/Library/Application Support/Epic/EpicGamesLauncher/Saved"
    static let epicBundleIDs = ["com.epicgames.EpicGamesLauncher", "com.epicgames.EpicGamesLauncher.*"]
    static let epicProcessNames = ["EpicGamesLauncher", "Epic Games Launcher", "EpicWebHelper*"]

    /// Web caches (`webcache`, `webcache_4147`…) and logs in the launcher's Unreal `Saved` folder. Never `Saved/Config`,
    /// `Data/Manifests` (installed games) or the games. Its other web cache is in
    /// `~/Library/Caches/com.epicgames.EpicGamesLauncher`, its other logs in `~/Library/Logs/Unreal Engine`.
    static let epic = CleanerItem(
        id: "epic-games-cache", title: appName("Epic Games Launcher"), note: note,
        paths: [epicSaved + "/webcache*", epicSaved + "/Logs"],
        showsWhenEmpty: false, runningAppBundleIDs: epicBundleIDs, runningProcessNames: epicProcessNames,
        skipsOpenFiles: true)

    // MARK: Battle.net

    static let battleNetRoot = "~/Library/Application Support/Battle.net"
    static let battleNetBundleIDs = ["net.battle.app", "net.battle.app.*", "net.battle.net.app"]
    static let battleNetProcessNames = ["Battle.net", "Battle.net Helper*"]

    /// The desktop app's browser cache, cache and logs (the folders its Windows build keeps in `%LOCALAPPDATA%`).
    /// Never `Battle.net.config` (settings), `Agent` (installer and patch data), `/Users/Shared/Battle.net` nor
    /// `~/Library/Application Support/Blizzard` (game data).
    static let battleNet = CleanerItem(
        id: "battlenet-cache", title: appName("Battle.net"), note: note,
        paths: ["BrowserCaches", "Cache", "Logs"].map { battleNetRoot + "/" + $0 },
        showsWhenEmpty: false, runningAppBundleIDs: battleNetBundleIDs, runningProcessNames: battleNetProcessNames,
        skipsOpenFiles: true)

    // MARK: GOG Galaxy

    static let gogRoot = "~/Library/Application Support/GOG.com/Galaxy"
    static let gogBundleIDs = ["com.gog.galaxy", "com.gog.galaxy.*"]
    static let gogProcessNames = ["GOG Galaxy*", "GalaxyClient*", "GalaxyCommunication*"]

    /// The client's web cache (its Windows build keeps it in `%LOCALAPPDATA%\GOG.com\Galaxy\webcache`, mapped here like
    /// `plugins`). Never `plugins` (integrations), `Storage` (library database) nor `/Users/Shared/GOG.com`, where its
    /// logs and games are.
    static let gogGalaxy = CleanerItem(
        id: "gog-galaxy-cache", title: appName("GOG Galaxy"), note: note,
        paths: [gogRoot + "/webcache"],
        showsWhenEmpty: false, runningAppBundleIDs: gogBundleIDs, runningProcessNames: gogProcessNames,
        skipsOpenFiles: true)

    static let all = [steam, epic, battleNet, gogGalaxy]

    /// Launcher names are not translated, like the other app rows.
    private static func appName(_ name: String) -> LocalizedStringResource {
        LocalizedStringResource(String.LocalizationValue(name))
    }
}
