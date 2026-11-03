import Foundation

/// Caches of chat, meeting, design and work apps: Zalo, Canva, Microsoft Teams (the new app), WhatsApp, and the Electron
/// apps Slack, Discord, Signal, Notion, Figma, Postman and Obsidian. Only folders the
/// app makes again by itself (web caches, compiled scripts, GPU shaders, the app's Caches and logs); never messages,
/// received photos and files, databases, cookies, local storage or sign-in. Ticked, deleted (regenerable), hidden when
/// the app is not installed, never while the app or one of its helpers runs.
nonisolated enum ChatAppCaches {
    // MARK: Zalo

    /// Zalo's Electron data folder (`app.setPath("userData")`). Its `media` folder holds each account's messages
    /// database, photos and files, with folders also named `Cache` inside (chat media), so only the Chromium cache
    /// folders at its top and in its partitions are listed, never a profile one level down.
    static let zaloData = "~/Library/Application Support/ZaloData"
    static let zaloBundleIDs = ["com.vng.zalo*"]
    static let zaloProcessNames = ["Zalo"]

    static let zalo = CleanerItem(
        id: "zalo", title: "Zalo", note: "Caches only; messages, photos, files and sign-in are kept",
        paths: CleanerGroup.electron(zaloData) + ["~/Library/Caches/com.vng.zalo"], showsWhenEmpty: false,
        runningAppBundleIDs: zaloBundleIDs, runningProcessNames: zaloProcessNames,
        about: "Web caches, compiled scripts and graphics caches of the Zalo app; Zalo makes them again when it opens. Your messages, the photos and files you received (ZaloData/media) and your sign-in are never touched")

    // MARK: Canva

    static let canvaData = "~/Library/Application Support/Canva"
    static let canvaBundleIDs = ["com.canva.CanvaDesktop*"]
    static let canvaProcessNames = ["Canva"]

    /// Canva keeps designs in your Canva account; its local folder holds the web app's caches and sign-in (cookies,
    /// local storage), of which only the caches are listed.
    static let canva = CleanerItem(
        id: "canva", title: "Canva", note: "Caches only; your designs and sign-in are kept",
        paths: CleanerGroup.electron(canvaData) + ["~/Library/Caches/com.canva.CanvaDesktop"], showsWhenEmpty: false,
        runningAppBundleIDs: canvaBundleIDs, runningProcessNames: canvaProcessNames,
        about: "Web caches, compiled scripts and graphics caches of the Canva app; Canva downloads or makes them again. Your designs are saved in your Canva account, and your sign-in stays")

    // MARK: Microsoft Teams

    /// The new Teams (`com.microsoft.teams2`) is sandboxed: everything is in its container, read only with Full Disk
    /// Access. Its web view (`EBWebView`, WebView2) keeps a profile per account (`WV2Profile_*`) whose service worker
    /// cache alone is often hundreds of MB.
    static let teamsContainer = "com.microsoft.teams2"
    static let teamsBundleIDs = ["com.microsoft.teams2*"]
    static let teamsProcessNames = ["MSTeams"]

    static let teams = CleanerItem(
        id: "teams-new", title: "Microsoft Teams", note: "Caches and logs only; chats, files and sign-in are kept",
        paths: [library(teamsContainer) + "/Caches", library(teamsContainer) + "/Logs"]
            + CleanerGroup.chromium(library(teamsContainer) + "/Application Support/Microsoft/MSTeams/EBWebView"),
        excluded: CleanerGroup.keptCaches, showsWhenEmpty: false,
        runningAppBundleIDs: teamsBundleIDs, runningProcessNames: teamsProcessNames,
        about: "Web caches, graphics caches and logs of the new Microsoft Teams, inside its container; Teams makes them again and downloads what it needs. Chats and files stay in Microsoft 365, and your sign-in is kept")

    // MARK: WhatsApp

    /// WhatsApp for Mac (App Store and direct download, both sandboxed). Messages and media live in its group container
    /// (`group.net.whatsapp.WhatsApp.shared`: `ChatStorage.sqlite`, `Message/Media`), never listed; only the
    /// container's Caches, read with Full Disk Access.
    static let whatsAppContainer = "net.whatsapp.WhatsApp"
    static let whatsAppBundleIDs = ["net.whatsapp.WhatsApp*"]
    static let whatsAppProcessNames = ["WhatsApp"]

    static let whatsApp = CleanerItem(
        id: "whatsapp", title: "WhatsApp", note: "Caches only; chats, photos, files and sign-in are kept",
        paths: [library(whatsAppContainer) + "/Caches"], excluded: CleanerGroup.keptCaches, showsWhenEmpty: false,
        runningAppBundleIDs: whatsAppBundleIDs, runningProcessNames: whatsAppProcessNames,
        about: "Files WhatsApp keeps in its Caches folder to open faster; it makes them again. Chats, photos and files are in another folder and are never touched")

    // MARK: Electron apps

    /// An Electron app's caches: the Chromium caches at the top of its data folder and in its partitions
    /// (`CleanerGroup.electron`), never a folder one level down, plus its `~/Library/Caches` folder and `extra` (logs).
    /// Cookies, Local Storage, IndexedDB, Session Storage and the app's own files (databases, attachments) stay.
    private static func electronApp(_ id: String, _ title: LocalizedStringResource, note: LocalizedStringResource,
                                    data: String, caches: String, extra: [String] = [], bundleID: String,
                                    process: String, about: LocalizedStringResource) -> CleanerItem {
        let root = "~/Library/Application Support/" + data
        return CleanerItem(id: id, title: title, note: note,
                           paths: CleanerGroup.electron(root) + extra.map { root + "/" + $0 } + ["~/Library/Caches/" + caches],
                           showsWhenEmpty: false, runningAppBundleIDs: [bundleID + "*"], runningProcessNames: [process],
                           about: about)
    }

    /// Slack downloaded from slack.com; `logs` holds its own log files. The App Store build is `slackAppStore`.
    static let slack = electronApp(
        "slack", "Slack", note: "Caches and logs only; messages, files and sign-in are kept",
        data: "Slack", caches: "com.tinyspeck.slackmacgap", extra: ["logs"],
        bundleID: "com.tinyspeck.slackmacgap", process: "Slack",
        about: "Web caches, compiled scripts, graphics caches and logs of the Slack app; Slack makes them again when it opens. Messages and files stay in your Slack workspace, and your sign-in is kept")

    /// The App Store Slack is sandboxed: the same Electron folder inside its container, read only with Full Disk Access.
    static let slackContainer = "com.tinyspeck.slackmacgap"
    static let slackAppStore = CleanerItem(
        id: "slack-app-store", title: "Slack (App Store)", note: "Caches and logs only; messages, files and sign-in are kept",
        paths: CleanerGroup.electron(library(slackContainer) + "/Application Support/Slack")
            + [library(slackContainer) + "/Application Support/Slack/logs", library(slackContainer) + "/Caches"],
        excluded: CleanerGroup.keptCaches, showsWhenEmpty: false,
        runningAppBundleIDs: ["com.tinyspeck.slackmacgap*"], runningProcessNames: ["Slack"],
        about: "Web caches, compiled scripts, graphics caches and logs of the Slack app from the App Store, inside its container; Slack makes them again when it opens. Messages and files stay in your Slack workspace, and your sign-in is kept")

    /// Discord's data folder also holds the app's own modules (`0.0.*/modules`), never listed.
    static let discord = electronApp(
        "discord", "Discord", note: "Caches only; messages and sign-in are kept",
        data: "discord", caches: "com.hnc.Discord", bundleID: "com.hnc.Discord", process: "Discord",
        about: "Web caches, compiled scripts and graphics caches of the Discord app; Discord makes them again when it opens. Messages stay on Discord, and your sign-in and the app's modules are kept")

    /// Signal keeps every message on this Mac: `sql/db.sqlite` (encrypted) and `attachments.noindex`, never listed.
    static let signal = electronApp(
        "signal", "Signal", note: "Caches only; messages, attachments and sign-in are kept",
        data: "Signal", caches: "org.whispersystems.signal-desktop",
        bundleID: "org.whispersystems.signal-desktop", process: "Signal",
        about: "Web caches, compiled scripts and graphics caches of the Signal app; Signal makes them again when it opens. Your messages and attachments (the sql and attachments.noindex folders) and the link to your phone are never touched")

    /// Notion keeps offline pages in its own database (`notion.db`) and IndexedDB, never listed.
    static let notion = electronApp(
        "notion", "Notion", note: "Caches only; pages, offline pages and sign-in are kept",
        data: "Notion", caches: "notion.id", bundleID: "notion.id", process: "Notion",
        about: "Web caches, compiled scripts and graphics caches of the Notion app; Notion makes them again when it opens. Your pages, the pages kept for offline use and your sign-in are never touched")

    /// Figma's web views each keep a profile in `DesktopProfile/*`, with the same Chromium caches.
    static let figma = CleanerItem(
        id: "figma", title: "Figma", note: "Caches only; your files and sign-in are kept",
        paths: CleanerGroup.electron("~/Library/Application Support/Figma")
            + CleanerGroup.electron("~/Library/Application Support/Figma/DesktopProfile/*")
            + ["~/Library/Caches/com.figma.Desktop"],
        showsWhenEmpty: false, runningAppBundleIDs: ["com.figma.Desktop*"], runningProcessNames: ["Figma"],
        about: "Web caches, compiled scripts and graphics caches of the Figma app; Figma downloads or makes them again. Your files are saved in your Figma account, and your sign-in stays")

    /// Postman keeps one partition per signed-in user (`Partitions/<uuid>`); its collections and history are in the
    /// partition's IndexedDB and `userPartitionData`, and in `storage`, never listed. `logs` holds its own log files.
    static let postman = electronApp(
        "postman", "Postman", note: "Caches and logs only; collections, history and sign-in are kept",
        data: "Postman", caches: "com.postmanlabs.mac", extra: ["logs"],
        bundleID: "com.postmanlabs.mac", process: "Postman",
        about: "Web caches, compiled scripts, graphics caches and logs of the Postman app; Postman makes them again when it opens. Your collections, environments, history and sign-in are never touched")

    /// Obsidian's vaults are folders the user picked, never in its data folder; `obsidian.json` (the vault list) and
    /// the downloaded app versions (`obsidian-*.asar`) stay.
    static let obsidian = electronApp(
        "obsidian", "Obsidian", note: "Caches only; your vaults and settings are kept",
        data: "obsidian", caches: "md.obsidian", bundleID: "md.obsidian", process: "Obsidian",
        about: "Web caches, compiled scripts and graphics caches of the Obsidian app; Obsidian makes them again when it opens. Your vaults are your own folders and are never touched, nor the list of vaults and settings")

    /// Items that need nothing more than the home folder.
    static let all = [zalo, canva, slack, discord, signal, notion, figma, postman, obsidian]
    /// Items inside another app's container: macOS asks without Full Disk Access.
    static let fullDiskAccess = [teams, whatsApp, slackAppStore]
    /// Containers whose Caches these items list, kept out of "Sandboxed app caches".
    static let containers: Set = [teamsContainer, whatsAppContainer, slackContainer]

    // MARK: Folders

    static func library(_ container: String) -> String { "~/Library/Containers/\(container)/Data/Library" }
}
