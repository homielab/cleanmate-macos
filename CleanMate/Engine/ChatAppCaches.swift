import Foundation

/// Caches of chat, meeting and design apps: Zalo, Canva, Microsoft Teams (the new app) and WhatsApp. Only folders the
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

    /// Items that need nothing more than the home folder.
    static let all = [zalo, canva]
    /// Items inside another app's container: macOS asks without Full Disk Access.
    static let fullDiskAccess = [teams, whatsApp]
    /// Containers whose Caches these items list, kept out of "Sandboxed app caches".
    static let containers: Set = [teamsContainer, whatsAppContainer]

    // MARK: Folders

    static func library(_ container: String) -> String { "~/Library/Containers/\(container)/Data/Library" }
}
