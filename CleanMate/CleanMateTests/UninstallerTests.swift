import Foundation
import Testing
@testable import CleanMate

/// Uninstaller runs against a throwaway fake home; nothing is ever moved to the real Trash or uninstalled.
struct UninstallerTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "CleanMateUninstaller-\(UUID().uuidString)")
    var home: URL { root.appending(path: "home") }
    var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }

    @discardableResult
    func make(_ path: String, folder: Bool = false) throws -> URL {
        let url = home.appending(path: path)
        if folder {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 5_000).write(to: url)
        }
        return url
    }

    @discardableResult
    func app(_ path: String, bundleID: String) throws -> URL {
        let url = try make(path, folder: true)
        let plist = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": "1.0", "CFBundlePackageType": "APPL"]
        try make("\(path)/Contents", folder: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: url.appending(path: "Contents/Info.plist"))
        return url
    }

    @Test(arguments: [
        ("com.foo.Bar", "Caches", true), ("com.foo.Bar.plist", "Preferences", true), ("com.foo.Bar.helper", "Caches", true),
        ("com.foo.Bar.savedState", "Saved Application State", true), ("com.foo.Bar.agent.plist", "LaunchAgents", true),
        ("ABCDE12345.com.foo.Bar", "Group Containers", true), ("group.com.foo.Bar.shared", "Group Containers", true),
        ("COM.FOO.BAR", "Containers", true), ("Barista", "Application Support", true), ("Barista", "Logs", true),
        // Shared prefixes, other apps of the vendor, name folders outside Application Support/Caches/Logs.
        ("com.foo.Barcode", "Caches", false), ("com.foo", "Caches", false), ("com.foo.Other", "Caches", false),
        ("com.foo.Bar.Pro", "Caches", false), ("com.foo.Bar.Pro.helper", "Caches", false), ("Barista", "Preferences", false),
        ("Baristas", "Application Support", false), ("Bar", "Caches", false), ("com.apple.Bar", "Caches", false),
        ("ABCDE12345.com.apple.foo", "Group Containers", false),
        // Other release channels of the app, installed or not.
        ("com.foo.Bar.canary.plist", "Preferences", false), ("com.foo.bar.for.testing.plist", "Preferences", false),
        ("com.foo.Bar.beta", "Caches", false), ("com.foo.Bar.devtools", "Caches", true),
    ])
    func matchesByBundleIDAndDistinctiveName(name: String, folder: String, expected: Bool) {
        #expect(AppMatcher.matches(name: name, folder: folder, bundleID: "com.foo.Bar", appName: "Barista",
                                   otherBundleIDs: ["com.foo.Bar", "com.foo.Bar.Pro", "com.foo.Other"]) == expected)
    }

    @Test func shortOrGenericAppNamesNeverMatchFolders() {
        for name in ["Go", "Google", "Microsoft", "Electron", "JetBrains", "Homebrew", "Studio"] {
            #expect(!AppMatcher.matches(name: name, folder: "Application Support", bundleID: "x.y.z", appName: name, otherBundleIDs: []),
                    "\(name)")
        }
        // A 3-character name counts as the app's name or CFBundleName, never as its executable.
        #expect(AppMatcher.matches(name: "Zed", folder: "Application Support", bundleID: "x.y.z", appName: "Zed", otherBundleIDs: []))
        #expect(AppMatcher.matches(name: "arc", folder: "Caches", bundleID: "x.y.z", appName: "Arc Browser", bundleName: "Arc",
                                   otherBundleIDs: []))
        #expect(!AppMatcher.matches(name: "Fox", folder: "Caches", bundleID: "x.y.z", appName: "Firefox Tools",
                                    executableName: "Fox", otherBundleIDs: []))
    }

    /// Folders named after the app's name, CFBundleName, CFBundleExecutable or a spelling of them are surely its data;
    /// a folder only starting with its first word is a suggestion; nothing another app goes by is ever picked.
    @Test func matchesNameVariantsAndSuggestsPrefixFolders() {
        let vscode = AppMatcher.Names(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code", bundleName: "Code",
                                      executableName: "Electron")
        let brave = AppMatcher.Names(bundleID: "com.brave.Browser", name: "Brave Browser", bundleName: "Brave Browser")
        let kind = { (name: String, folder: String, app: AppMatcher.Names, others: Set<String>) in
            AppMatcher.kind(name: name, folder: folder, app: app, otherBundleIDs: [], otherAppNames: others)
        }
        let others: Set = ["Cursor", "Arc", "Disk Utility", "Studio One"]
        #expect(kind("Code", "Application Support", vscode, others) == .data)
        #expect(kind("Visual Studio Code", "Logs", vscode, others) == .data)
        #expect(kind("Electron", "Application Support", vscode, others) == nil) // generic executable
        #expect(kind("Arc", "Application Support", AppMatcher.Names(bundleID: "company.thebrowser.Browser", name: "Arc"), []) == .data)
        let beekeeper = AppMatcher.Names(bundleID: "io.beekeeperstudio.desktop", name: "Beekeeper Studio")
        #expect(kind("beekeeper-studio", "Application Support", beekeeper, others) == .data)
        #expect(kind("Beekeeper_Studio", "Caches", beekeeper, others) == .data)
        let diskDrill = AppMatcher.Names(bundleID: "com.cleverfiles.Disk-Drill", name: "Disk Drill")
        #expect(kind("DiskDrill", "Application Support", diskDrill, others) == .data)
        #expect(kind("DiskDrill", "Preferences", diskDrill, others) == nil) // name folders only
        // Suggestion: only in Application Support, never reverse-DNS, never when another app starts the same way.
        #expect(kind("BraveSoftware", "Application Support", brave, others) == .suggested)
        #expect(kind("BraveSoftware", "Caches", brave, others) == nil)
        #expect(kind("brave.foo.bar", "Application Support", brave, others) == nil)
        #expect(kind("BraveSoftware", "Application Support", brave, others.union(["Brave Origin"])) == nil)
        #expect(kind("BraveSoftware", "Application Support", brave, others.union(["BraveVPN"])) == nil)
        #expect(kind("DiskUtilityPro", "Application Support", diskDrill, ["Disk Expert"]) == nil)
        let chrome = AppMatcher.Names(bundleID: "com.google.Chrome", name: "Google Chrome")
        #expect(kind("GoogleUpdater", "Application Support", chrome, []) == nil) // generic first word
        // Another app with the same name or a longer family name: ambiguous, only bundle ids count.
        #expect(kind("DiskDrill", "Application Support", diskDrill, ["Disk Drill Pro"]) == nil)
        #expect(kind("Code", "Application Support", vscode, ["Code"]) == nil)
        #expect(kind("beekeeper-studio", "Application Support", beekeeper, ["beekeeper-studio"]) == nil)
        #expect(kind("Code", "Application Support", vscode, ["Codebase Pro", "Codex"]) == .data)
        #expect(kind("com.microsoft.VSCode", "Caches", vscode, ["Code"]) == .data)
    }

    @Test func appConfigPolicyAllowsOnlyTopLevelConfigItems() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        for path in [".cursor", ".antigravity-ide", ".config/zed", ".config/opencode", ".zed.json"] {
            #expect(policy.allowsAppConfig(try make(path)), "\(path)")
        }
        try make(".ssh/config")
        for path in [".config", ".cache", ".local", ".Trash", ".ssh", ".SSH", ".ssh/config", ".gnupg", ".aws", ".kube", ".zshrc",
                     ".android", ".cargo", ".config/.DS_Store", ".config/zed/settings.json", ".local/share/zed", "visible",
                     "Documents", "Library/Application Support/Zed", ".com.apple.foo", ".cursor/extensions"] {
            #expect(!policy.allowsAppConfig(home.appending(path: path)), "\(path)")
        }
        #expect(!policy.allowsAppConfig(URL(fileURLWithPath: "/tmp/.cursor")))
        let link = home.appending(path: ".linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.appending(path: ".cursor"))
        #expect(!policy.allowsAppConfig(link))
        // A symlinked ~/.config (dotfile managers) is never followed.
        let other = root.appending(path: "dotfiles")
        try FileManager.default.createDirectory(at: other.appending(path: "zed"), withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: home.appending(path: ".config"))
        try FileManager.default.createSymbolicLink(at: home.appending(path: ".config"), withDestinationURL: other)
        #expect(!policy.allowsAppConfig(home.appending(path: ".config/zed")))
    }

    /// Config outside ~/Library: `~/.config/<name>` and `~/.<name>`/`~/.<name>-…` are listed, never ticked; never a
    /// protected or shared folder, a generic name, or a name a command-line tool outside the app uses.
    @MainActor @Test func listsAppConfigUntickedAndNeverToolOrProtectedFolders() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let cursorApp = try app("Applications/Cursor.app", bundleID: "com.todesktop.cursor")
        try make("Applications/Cursor.app/Contents/Resources/bin/code")
        for path in [".cursor/argv.json", ".cursor-tutor/x", ".config/cursor/x", ".config/zed/settings.json",
                     ".antigravity-ide/x", ".ssh/config", ".cache/zed/x", ".config/settings/x", ".mytool/x",
                     ".config/mytool/x", ".zedx/x", ".gemini/x", ".config/github-copilot/x", "Library/Application Support/Cursor/x"] {
            try make(path)
        }
        let bin = try make("bin", folder: true)
        try FileManager.default.createSymbolicLink(at: bin.appending(path: "cursor"),
                                                   withDestinationURL: cursorApp.appending(path: "Contents/Resources/bin/code"))
        try make("bin/mytool")
        let tools = Uninstaller.toolPaths(home: home, folders: [bin.path])
        let config = { (app: InstalledApp, others: Set<String>) async in
            await Uninstaller.data(of: app, otherBundleIDs: [], otherAppNames: others, tools: tools, policy: policy)
                .filter { $0.kind == .config }.map { ($0.url.path as NSString).replacingOccurrences(of: home.path, with: "~") }
        }
        let cursor = InstalledApp(url: cursorApp, name: "Cursor", bundleID: "com.todesktop.cursor", version: nil, lastUsed: nil)
        #expect(Set(await config(cursor, [])) == ["~/.cursor", "~/.cursor-tutor", "~/.config/cursor"])
        #expect(await config(cursor, ["Cursor"]).isEmpty) // another app goes by that name
        let zed = InstalledApp(url: URL(filePath: "/nonexistent/Zed.app"), name: "Zed", bundleID: "dev.zed.Zed", version: nil, lastUsed: nil)
        #expect(await config(zed, []) == ["~/.config/zed"]) // never ~/.cache/zed, nor ~/.zedx
        let ide = InstalledApp(url: URL(filePath: "/nonexistent/Antigravity IDE.app"), name: "Antigravity IDE",
                               bundleID: "com.google.antigravity", version: nil, lastUsed: nil)
        #expect(await config(ide, []) == ["~/.antigravity-ide"])
        for (name, bundleName) in [("SSH", "ssh"), ("Settings", "settings"), ("My Tool", "mytool"), ("Gemini", "Gemini"),
                                   ("GitHub Copilot", "GitHub Copilot")] {
            let app = InstalledApp(url: URL(filePath: "/nonexistent/\(name).app"), name: name, bundleID: "com.test.\(bundleName)",
                                   version: nil, lastUsed: nil, bundleName: bundleName)
            #expect(await config(app, []).isEmpty, "\(name)") // protected, generic, a tool outside the bundle, or a CLI's
        }
        // In the detail: listed with the ~/Library data, only the data ticked; data sizes count it all.
        let model = UninstallerModel()
        let policy = policy
        model.apps = [cursor]
        model.appData = { app, _, _ in // not the real Mac's other apps (it may have a real Cursor.app)
            await Uninstaller.data(of: app, otherBundleIDs: [], tools: tools, policy: policy)
        }
        model.selection = .app(cursor.url)
        await model.loadEntries()
        #expect(model.entries.count == 4)
        #expect(model.checked.map(\.lastPathComponent) == ["Cursor"])
        let matches = await Uninstaller.dataMatches(of: [cursor], otherBundleIDs: [], tools: tools, policy: policy)
        #expect(Set(matches[cursor.url] ?? []) == Set(model.entries.map(\.url)))
        // Moved to the (fake) Trash like other data, re-checked right before; a protected folder never is.
        let moved = Moved()
        let ssh = AppDataEntry(url: home.appending(path: ".ssh"), size: 1, kind: .config)
        let report = try await Uninstaller.trash(app: nil, data: model.entries + [ssh], policy: policy, launchctl: { _ in true },
                                                 moveToTrash: { moved.add($0); return $0 }, isRunning: { _ in false })
        #expect(Set(moved.all) == Set(model.entries.map(\.url)) && report.skipped == 1)
    }

    @Test func twoInstalledAppsWithSharedPrefixKeepTheirOwnData() {
        let ids: Set = ["com.foo.app", "com.foo.app.pro", "com.foo.app-helper"]
        let entries = [("com.foo.app", "Caches"), ("com.foo.app.plist", "Preferences"), ("com.foo.app.pro", "Caches"),
                       ("com.foo.app.pro.plist", "Preferences"), ("com.foo.app-helper", "Application Support"),
                       ("ABCDE12345.com.foo.app.pro", "Group Containers"), ("Barista", "Application Support")]
        let picked = { (bundleID: String, appName: String, others: Set<String>) in
            Set(entries.filter { AppMatcher.matches(name: $0.0, folder: $0.1, bundleID: bundleID, appName: appName,
                                                    otherBundleIDs: ids, otherAppNames: others) }.map(\.0))
        }
        // A never takes B's data (longer bundle id) nor the vendor's family folder shared with "Barista Pro".
        #expect(picked("com.foo.app", "Barista", ["Barista Pro", "Barista Helper"]) == ["com.foo.app", "com.foo.app.plist"])
        #expect(picked("com.foo.app.pro", "Barista Pro", ["Barista"]) == ["com.foo.app.pro", "com.foo.app.pro.plist",
                                                                          "ABCDE12345.com.foo.app.pro"])
        // Another installed app with the same name: the name folder is ambiguous, only bundle ids count.
        #expect(!AppMatcher.matches(name: "Barista", folder: "Logs", bundleID: "com.foo.app", appName: "Barista",
                                    otherBundleIDs: ids, otherAppNames: ["barista"]))
        #expect(AppMatcher.matches(name: "Barista", folder: "Logs", bundleID: "com.foo.app", appName: "Barista",
                                   otherBundleIDs: ids, otherAppNames: ["Baristas", "Coffee"]))
    }

    @Test func leftoversNeverClaimDataOfAnInstalledSibling() {
        for (name, folder) in [("com.foo.app.pro", "Caches"), ("com.foo.app-helper", "Caches"), ("com.foo.app.plist", "Preferences"),
                               ("ABCDE12345.com.foo.shared", "Group Containers"), ("group.com.foo.app.pro", "Group Containers"),
                               ("COM.FOO.Other", "Caches")] {
            #expect(!AppMatcher.isLeftover(name: name, folder: folder, installedBundleIDs: ["com.foo.App"], isRegistered: { _ in false }),
                    "\(name)")
        }
    }

    @Test(arguments: [
        ("com.gone.App", "Caches", true), ("com.gone.App.plist", "Preferences", true), ("ABCDE12345.com.gone.App", "Group Containers", true),
        ("io.gone.tool.savedState", "Saved Application State", true),
        // Installed vendors (also via LaunchServices), Apple, non-reverse-DNS names.
        ("com.foo.Updater", "Caches", false), ("com.foo.Bar.plist", "Preferences", false), ("com.registered.App", "Caches", false),
        ("com.apple.Safari", "Caches", false), ("group.com.apple.notes", "Group Containers", false), ("Google", "Application Support", false),
        ("com.gone", "Caches", false), ("loginwindow.plist", "Preferences", false), ("Barista", "Application Support", false),
        // System parts and shared SDKs without an app of their own.
        ("group.is.workflow.shortcuts", "Group Containers", false), ("org.cups.PrintingPrefs.plist", "Preferences", false),
        ("org.sparkle-project.Downloader", "HTTPStorages", false), ("org.swift.swiftpm", "Caches", false),
    ])
    func leftoversNeedAnUninstalledBundleID(name: String, folder: String, expected: Bool) {
        #expect(AppMatcher.isLeftover(name: name, folder: folder, installedBundleIDs: ["com.foo.Bar"],
                                      isRegistered: { $0 == "com.registered.app" }) == expected)
    }

    @Test func commandLineToolDataIsNotALeftover() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Library/Application Support/org.rust.Mytool", "Library/Application Support/dev.runner.Busytool",
                     "Library/Application Support/com.gone.App", "fakebin/mytool", ".cargo/bin/other"] {
            try make(path)
        }
        // Fake PATH: an absolute folder plus a `~/` one under the temp home; a running tool counts too.
        let tools = Uninstaller.commandLineTools(home: home, folders: [home.appending(path: "fakebin").path, "~/.cargo/bin", "~/missing"],
                                                 running: ["BusyTool", "Updater"])
        #expect(tools == ["mytool", "other", "busytool"])
        let leftovers = await Uninstaller.leftovers(installedBundleIDs: [], tools: tools, isRegistered: { _ in false }, policy: policy)
        #expect(leftovers.map { $0.url.lastPathComponent } == ["com.gone.App"])
        #expect(!AppMatcher.isLeftover(name: "org.rust.mytool.plist", folder: "Preferences", installedBundleIDs: [], tools: tools,
                                       isRegistered: { _ in false }))
    }

    /// macOS commands (`/usr/bin/installer`, `/usr/bin/chat`…) don't shield a removed app's data; Homebrew tools still do.
    @Test func systemCommandsDoNotShieldLeftovers() {
        #expect(Uninstaller.isSystemToolFolder("/usr/bin") && Uninstaller.isSystemToolFolder("/sbin/")
                && Uninstaller.isSystemToolFolder("/System/Cryptexes/App/usr/bin") && Uninstaller.isSystemToolFolder("/usr/libexec"))
        #expect(!Uninstaller.isSystemToolFolder("/usr/local/bin") && !Uninstaller.isSystemToolFolder("/opt/homebrew/bin")
                && !Uninstaller.isSystemToolFolder("/binaries"))
        #expect(!Uninstaller.userToolFolders.contains { ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/libexec"].contains($0) })
        #expect(Uninstaller.userToolFolders.contains("/opt/homebrew/bin"))
        let tools: Set<String> = []
        #expect(AppMatcher.isLeftover(name: "com.gone.installer", folder: "Application Support", installedBundleIDs: [], tools: tools,
                                      isRegistered: { _ in false }))
        #expect(!AppMatcher.isLeftover(name: "com.gone.installer", folder: "Application Support", installedBundleIDs: [],
                                       tools: ["installer"], isRegistered: { _ in false }))
    }

    @Test func appPolicyAllowsOnlyThirdPartyAppsInApplications() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Applications/Foo.app", "Applications/Sub/Foo.app", "Applications/Sub/Deeper/Foo.app", "Applications/A/B/C/Foo.app"] {
            #expect(policy.allowsApp(try app(path, bundleID: "com.foo.Bar")), "\(path)")
        }
        for url in [try app("Applications/A/B/C/D/Foo.app", bundleID: "com.foo.Bar"),
                    try app("Applications/Foo.app/Contents/Helpers/Helper.app", bundleID: "com.foo.Bar.helper"),
                    try app("Applications/Kit.bundle/Foo.app", bundleID: "com.foo.Kit"),
                    try app("Applications/.hidden/Foo.app", bundleID: "com.foo.Hidden"),
                    try app("Applications/Sub/Pages.app", bundleID: "com.apple.iWork.Pages"), try app("Applications/Pages.app", bundleID: "com.apple.iWork.Pages"),
                    try app("Applications/Self.app", bundleID: Bundle.main.bundleIdentifier ?? "com.homielab.CleanMate"),
                    try app("Desktop/Foo.app", bundleID: "com.foo.Bar"), try make("Applications/NoBundle.app", folder: true),
                    try make("Applications/file.app"), home.appending(path: "Applications"),
                    URL(fileURLWithPath: "/System/Applications/Calculator.app"), URL(fileURLWithPath: "/Applications/Safari.app")] {
            #expect(!policy.allowsApp(url), "\(url.path)")
        }
        let link = home.appending(path: "Applications/Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.appending(path: "Applications/Foo.app"))
        #expect(!policy.allowsApp(link))
    }

    @Test func listsAppsUpToThreePlainSubfoldersDownButNeverInsideBundles() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try app("Applications/Top.app", bundleID: "com.foo.Top")
        try app("Applications/Adobe Photoshop 2025/Photoshop.app", bundleID: "com.foo.Photoshop")
        try app("Applications/Vendor/Tools/Tool.app", bundleID: "com.foo.Tool")
        try app("Applications/Vendor/Suite/Tools/Deep.app", bundleID: "com.foo.Deep")
        try app("Applications/Vendor/Suite/Tools/Deep.app/Contents/Helpers/DeepHelper.app", bundleID: "com.foo.DeepHelper")
        try app("Applications/A/B/C/D/TooDeep.app", bundleID: "com.foo.TooDeep")
        try app("Applications/Top.app/Contents/Helpers/Helper.app", bundleID: "com.foo.Helper")
        try app("Applications/Kit.bundle/InKit.app", bundleID: "com.foo.InKit")
        try app("Applications/Sub/Pages.app", bundleID: "com.apple.iWork.Pages")
        let mine = await Uninstaller.installedApps(policy: policy).filter { $0.url.path.contains(root.lastPathComponent) }
        #expect(Set(mine.map(\.bundleID)) == ["com.foo.Top", "com.foo.Photoshop", "com.foo.Tool", "com.foo.Deep"])
        // Nested apps count as installed, so their data is never offered as a leftover.
        let ids = Uninstaller.allBundleIDs(policy: policy)
        #expect(ids.isSuperset(of: ["com.foo.Photoshop", "com.foo.Tool", "com.apple.iWork.Pages"]))
        #expect(ids.isDisjoint(with: ["com.foo.TooDeep", "com.foo.Helper", "com.foo.InKit", "com.foo.DeepHelper"]))
    }

    @Test func appDataPolicyAllowsOnlyItemsInsideLibraryDataFolders() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Library/Caches/com.foo.Bar", "Library/Preferences/com.foo.Bar.plist", "Library/Containers/com.foo.Bar",
                     "Library/LaunchAgents/com.foo.Bar.plist", "Library/Group Containers/ABCDE12345.com.foo.Bar"] {
            #expect(policy.allowsAppData(try make(path)), "\(path)")
        }
        for path in ["Library/Caches", "Library/Caches/com.foo.Bar/sub", "Library/Caches/com.apple.Safari", "Library/Caches/.hidden",
                     "Library/Keychains/com.foo.Bar", "Library/Mail/com.foo.Bar", "Documents/com.foo.Bar", "Library/com.foo.Bar"] {
            #expect(!policy.allowsAppData(home.appending(path: path)), "\(path)")
        }
        #expect(!policy.allowsAppData(URL(fileURLWithPath: "/Library/Caches/com.foo.Bar")))
    }

    @Test func findsDataAndLeftoversInLibrary() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Library/Caches/com.foo.Bar", "Library/Preferences/com.foo.Bar.plist", "Library/Application Support/Barista",
                     "Library/Caches/com.foo.Barcode", "Library/Caches/com.apple.Safari", "Library/Caches/com.gone.App",
                     "Library/Logs/Google"] {
            try make(path)
        }
        let bar = InstalledApp(url: home.appending(path: "Applications/Barista.app"), name: "Barista", bundleID: "com.foo.Bar",
                               version: nil, lastUsed: nil)
        let data = await Uninstaller.data(of: bar, otherBundleIDs: [], policy: policy)
        #expect(Set(data.map { $0.url.lastPathComponent }) == ["com.foo.Bar", "com.foo.Bar.plist", "Barista"])
        #expect(data.allSatisfy { $0.size > 0 })
        // Launch agents count only when their program is gone.
        let agents = home.appending(path: "Library/LaunchAgents")
        try make("Library/LaunchAgents", folder: true)
        try (["Label": "x", "ProgramArguments": ["/bin/sh"]] as NSDictionary).write(to: agents.appending(path: "com.live.agent.plist"))
        try (["Label": "x", "Program": "/nonexistent/gone"] as NSDictionary).write(to: agents.appending(path: "com.gone.agent.plist"))
        let leftovers = await Uninstaller.leftovers(installedBundleIDs: ["com.foo.Bar"], tools: [], isRegistered: { _ in false },
                                                    policy: policy)
        #expect(Set(leftovers.map { $0.url.lastPathComponent }) == ["com.gone.App", "com.gone.agent.plist"])
    }

    /// One listing for all apps gives each app exactly what its detail lists (`data(of:)`), and skipped (protected)
    /// folders are not listed.
    @Test func dataMatchesEqualEachAppsDetail() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Library/Caches/com.foo.Bar", "Library/Preferences/com.foo.Bar.plist", "Library/Application Support/Barista",
                     "Library/Caches/com.foo.Bar.Pro", "Library/Logs/Barista Pro", "Library/Containers/com.foo.Bar",
                     "Library/Caches/com.other.Tool", "Library/Logs/Toolbox", "Library/Caches/com.apple.Safari"] {
            try make(path)
        }
        let apps = [("Barista", "com.foo.Bar"), ("Barista Pro", "com.foo.Bar.Pro"), ("Toolbox", "com.other.Tool")].map {
            InstalledApp(url: home.appending(path: "Applications/\($0.0).app"), name: $0.0, bundleID: $0.1, version: nil, lastUsed: nil)
        }
        let ids = Set(apps.map(\.bundleID))
        let matches = await Uninstaller.dataMatches(of: apps, otherBundleIDs: ids, policy: policy)
        for app in apps {
            let others = apps.filter { $0.url != app.url }
            let detail = await Uninstaller.data(of: app, otherBundleIDs: ids, otherAppNames: Set(others.map(\.name)), policy: policy)
            #expect(Set(matches[app.url] ?? []) == Set(detail.map(\.url)), "\(app.name)")
        }
        #expect(Set(matches[apps[0].url]?.map(\.lastPathComponent) ?? []) == ["com.foo.Bar", "com.foo.Bar.plist"])
        #expect(matches[apps[0].url]?.count == 3) // Caches, Preferences, Containers; "Barista" is shared with Barista Pro
        let skipped = ProtectedFolders.skipped(home: home, hasFullDiskAccess: false)
        let guarded = await Uninstaller.dataMatches(of: apps, otherBundleIDs: ids, skipped: skipped, policy: policy)
        #expect(guarded[apps[0].url]?.contains { $0.path.contains("/Containers/") } == false)
        #expect(guarded[apps[0].url]?.count == 2)
    }

    /// Background totals: each app's data summed with every entry measured once; Size order uses app + data once
    /// measured; Uninstall/Reset forgets the totals. Fake paths and hooks only.
    @MainActor @Test func measuresAppDataTotalsAndSortsBySum() async {
        let apps = ["Small", "Big", "Plain"].map {
            InstalledApp(url: URL(filePath: "/nonexistent/\($0).app"), name: $0, bundleID: "com.test.\($0)", version: nil, lastUsed: nil)
        }
        let shared = URL(filePath: "/nonexistent/Library/Caches/shared")
        let small = URL(filePath: "/nonexistent/Library/Caches/small")
        let model = UninstallerModel()
        model.apps = apps
        model.appSizes = [apps[0].url: 10, apps[1].url: 500, apps[2].url: 100]
        model.appDataMatches = { _, _ in [apps[0].url: [small, shared], apps[1].url: [shared], apps[2].url: []] }
        let measured = Measured()
        model.appSize = { url in await measured.add(url); return url == small ? 1_000 : 7 }
        await model.measureAppData()
        #expect(model.appDataSizes == [apps[0].url: 1_007, apps[1].url: 7, apps[2].url: 0])
        #expect(await measured.urls.sorted { $0.path < $1.path } == [shared, small]) // each entry once
        #expect(UninstallerModel.sorted(apps, by: .size, sizes: model.totalSizes).map(\.name) == ["Small", "Big", "Plain"])
        // Not measured yet: the app size alone; unknown app size last.
        model.appDataSizes = [apps[0].url: 1_007]
        model.appSizes[apps[2].url] = nil
        #expect(UninstallerModel.sorted(apps, by: .size, sizes: model.totalSizes).map(\.name) == ["Small", "Big", "Plain"])
        let generation = model.dataGeneration
        model.invalidateAppData()
        #expect(model.appDataSizes.isEmpty && model.dataGeneration == generation + 1)
    }

    actor Measured {
        var urls: [URL] = []
        func add(_ url: URL) { urls.append(url) }
    }

    @Test func refusesEverythingWhenTheAppIsNotAllowed() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let blockedApp = try app("Applications/Pages.app", bundleID: "com.apple.iWork.Pages")
        let data = try make("Library/Caches/com.foo.Bar")
        await #expect(throws: Uninstaller.AppTrashError.notTrashed) {
            try await Uninstaller.trash(app: blockedApp, data: [AppDataEntry(url: data, size: 1)], policy: policy)
        }
        #expect(FileManager.default.fileExists(atPath: blockedApp.path) && FileManager.default.fileExists(atPath: data.path))
        // Data outside the rule is skipped, never trashed.
        let outside = try make("Documents/com.foo.Bar")
        let skipped = try await Uninstaller.trash(app: nil, data: [AppDataEntry(url: outside, size: 1)], policy: policy)
        #expect(skipped.skipped == 1 && FileManager.default.fileExists(atPath: outside.path))
    }

    /// A Finder-locked app: `trashItem` and `recycle` both refuse it, so nothing is tried or touched and the
    /// model reports it as locked. Fake Trash and fake recycle only.
    @MainActor @Test func reportsLockedApp() async throws {
        defer { chflags(root.appending(path: "Applications/Locked.app").path, 0); try? FileManager.default.removeItem(at: root) }
        let appURL = try app("Applications/Locked.app", bundleID: "com.foo.Locked")
        let cache = try make("Library/Caches/com.foo.Locked")
        #expect(chflags(appURL.path, UInt32(UF_IMMUTABLE)) == 0)
        let item = InstalledApp(url: appURL, name: "Locked", bundleID: "com.foo.Locked", version: nil, lastUsed: nil)
        let moved = Moved()
        let policy = policy
        let model = UninstallerModel()
        model.apps = [item]
        model.appData = { _, _, _ in [AppDataEntry(url: cache, size: 30)] }
        model.trash = { app, data throws(Uninstaller.AppTrashError) in
            try await Uninstaller.trash(app: app, data: data, policy: policy, launchctl: { _ in true },
                                        moveToTrash: { moved.add($0); return nil }, recycle: { moved.add($0); return nil },
                                        isRunning: { _ in false })
        }
        model.selection = .app(appURL)
        await model.loadEntries()
        await model.remove()
        guard case .appLocked(let a) = model.outcome, a == item else { Issue.record("\(String(describing: model.outcome))"); return }
        #expect(moved.all.isEmpty && model.apps.count == 1 && FileManager.default.fileExists(atPath: cache.path))
    }

    /// `trashItem` refused for lack of permission (root/App Store app) → `recycle` (the admin prompt) is tried; cancelled
    /// or failed → no data touched and the model reports which; success → data follows as before.
    /// Fake Trash and fake recycle only: nothing is moved and NSWorkspace is never called.
    @MainActor @Test func recyclesAppWhenTrashItemIsNotPermitted() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = try app("Applications/Rooted.app", bundleID: "com.foo.Rooted")
        let cache = try make("Library/Caches/com.foo.Rooted")
        let item = InstalledApp(url: appURL, name: "Rooted", bundleID: "com.foo.Rooted", version: nil, lastUsed: nil)
        let trashDir = root.appending(path: "Trash")
        let moved = Moved()
        let policy = policy
        let model = UninstallerModel()
        model.apps = [item]
        model.appData = { _, _, _ in [AppDataEntry(url: cache, size: 30)] }
        func run(_ recycle: @escaping @Sendable (URL) async throws -> URL?) async {
            model.trash = { app, data throws(Uninstaller.AppTrashError) in
                try await Uninstaller.trash(app: app, data: data, policy: policy, launchctl: { _ in true }, moveToTrash: { url in
                    if url == appURL { throw CocoaError(.fileWriteNoPermission) }
                    moved.add(url)
                    return trashDir.appending(path: url.lastPathComponent)
                }, recycle: recycle)
            }
            model.selection = .app(appURL)
            await model.loadEntries()
            await model.remove()
        }
        await run { _ in throw CocoaError(.userCancelled) }
        guard case .appTrashCancelled(let a) = model.outcome, a == item else { Issue.record("\(String(describing: model.outcome))"); return }
        await run { _ in throw CocoaError(.fileWriteUnknown) }
        guard case .appNotTrashed = model.outcome else { Issue.record("\(String(describing: model.outcome))"); return }
        #expect(moved.all.isEmpty && model.apps.count == 1)
        let recycled = Moved()
        await run { url in recycled.add(url); return trashDir.appending(path: "Rooted.app") }
        #expect(recycled.all == [appURL] && moved.all == [cache])
        guard case .removed(let report) = model.outcome else { Issue.record("\(String(describing: model.outcome))"); return }
        #expect(report.trashed.map(\.original) == [appURL, cache] && model.apps.isEmpty)
        // Any other trashItem error: no admin prompt.
        await #expect(throws: Uninstaller.AppTrashError.notTrashed) {
            try await Uninstaller.trash(app: appURL, data: [], policy: policy, moveToTrash: { _ in throw CocoaError(.fileNoSuchFile) },
                                        recycle: { _ in Issue.record("recycle called"); return nil })
        }
    }

    /// Calls are sequential in the test, so no lock is needed.
    final class Moved: @unchecked Sendable {
        var all: [URL] = []
        func add(_ url: URL) { all.append(url) }
    }

    @discardableResult
    func agent(_ path: String, label: String?) throws -> URL {
        let url = try make(path)
        try PropertyListSerialization.data(fromPropertyList: label.map { ["Label": $0] } ?? [:], format: .xml, options: 0).write(to: url)
        return url
    }

    /// Only the user's own agents, by label, and only when the plist's `Label` is its file name: a matched plist naming
    /// another app's or Apple's service, a symlink, or an unreadable one is never booted out.
    @Test func bootsOutOnlyTheUsersLaunchAgents() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let own = try agent("Library/LaunchAgents/com.foo.Bar.agent.plist", label: "com.foo.Bar.agent")
        let noLabel = try agent("Library/LaunchAgents/com.foo.Bar.nolabel.plist", label: nil)
        let other = try agent("Library/LaunchAgents/com.foo.Bar.other.plist", label: "com.vendor.Other.agent")
        let apple = try agent("Library/LaunchAgents/com.foo.Bar.apple.plist", label: "com.apple.Finder")
        let link = home.appending(path: "Library/LaunchAgents/com.foo.Bar.link.plist")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: own)
        let empty = try make("Library/LaunchAgents/com.foo.Bar.empty.plist")
        let cache = try make("Library/Caches/com.foo.Bar")
        let outside = try agent("Documents/LaunchAgents/com.foo.Bar.agent.plist", label: "com.foo.Bar.agent")
        let calls = Calls()
        let data = [own, noLabel, other, apple, link, empty, cache, outside].map { AppDataEntry(url: $0, size: 1) }
        await Uninstaller.bootOutAgents(in: data, policy: policy) {
            await calls.add($0); return false // not loaded: still fine
        }
        #expect(await calls.all == [["bootout", "gui/\(getuid())/com.foo.Bar.agent"], ["bootout", "gui/\(getuid())/com.foo.Bar.nolabel"]])
    }

    /// The app opened while its size was measured: refused right before it goes, nothing else touched.
    @Test func refusesAnAppThatIsRunningRightBeforeItGoes() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = try app("Applications/Open.app", bundleID: "com.foo.Open")
        let cache = try make("Library/Caches/com.foo.Open")
        let moved = Moved()
        let policy = policy
        await #expect(throws: Uninstaller.AppTrashError.notTrashed) {
            try await Uninstaller.trash(app: appURL, data: [AppDataEntry(url: cache, size: 1)], policy: policy,
                                        launchctl: { _ in true }, moveToTrash: { moved.add($0); return nil },
                                        recycle: { moved.add($0); return nil }, isRunning: { $0 == appURL })
        }
        #expect(moved.all.isEmpty)
    }

    /// Changing app drops the old app's ticked rows at once: Uninstall before the new load never sends app B with
    /// app A's data, and a load of A finishing late is discarded.
    @MainActor @Test func switchingAppNeverSendsTheOldAppsData() async {
        let a = InstalledApp(url: URL(filePath: "/nonexistent/A.app"), name: "Aaaa", bundleID: "com.test.qqx.a", version: nil, lastUsed: nil)
        let b = InstalledApp(url: URL(filePath: "/nonexistent/B.app"), name: "Bbbb", bundleID: "com.test.qqx.b", version: nil, lastUsed: nil)
        let aData = URL(filePath: "/nonexistent/Library/Caches/com.test.qqx.a")
        let model = UninstallerModel()
        model.apps = [a, b]
        model.appBundleIDs = { [] }
        model.appData = { app, _, _ in app.url == a.url ? [AppDataEntry(url: aData, size: 1)] : [] }
        var calls: [(URL?, [URL])] = []
        model.trash = { calls.append(($0, $1.map(\.url))); return CleanReport() }
        model.selection = .app(a.url)
        await model.loadEntries()
        #expect(model.checked == [aData])
        model.selection = .app(b.url) // no loadEntries yet
        await model.remove()
        #expect(calls.count == 1 && calls[0].0 == b.url && calls[0].1.isEmpty)
    }

    /// `runningApps` missed the launch: `remove` reads the running apps again and refuses.
    @MainActor @Test func removeReadsRunningAppsAgain() async {
        let a = InstalledApp(url: URL(filePath: "/nonexistent/A.app"), name: "Aaaa", bundleID: "com.test.qqx.a", version: nil, lastUsed: nil)
        let model = UninstallerModel()
        model.apps = [a]
        model.runningApps = []
        model.appBundleIDs = { ["com.test.qqx.a"] }
        var calls = 0
        model.trash = { _, _ in calls += 1; return CleanReport() }
        model.selection = .app(a.url)
        await model.remove()
        #expect(calls == 0 && model.isRunning(a))
    }

    /// Apps not listed (Apple's, excluded in Settings) still shield their name folder; the app itself never does.
    @Test func unlistedAppsShieldTheirNameFolders() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let barista = try app("Applications/Barista.app", bundleID: "com.foo.Bar")
        let pro = try app("Applications/Barista Pro.app", bundleID: "com.foo.BarPro")
        let folder = try make("Library/Application Support/Barista", folder: true)
        let item = InstalledApp(url: barista, name: "Barista", bundleID: "com.foo.Bar", version: nil, lastUsed: nil)
        #expect(Uninstaller.otherAppNames(than: barista, in: [barista, pro]) == ["Barista Pro"])
        let shielded = await Uninstaller.dataMatches(of: [item], otherBundleIDs: [], allApps: [barista, pro], policy: policy)
        #expect(shielded[barista] == [])
        let alone = await Uninstaller.dataMatches(of: [item], otherBundleIDs: [], allApps: [barista], policy: policy)
        #expect(alone[barista] == [folder])
    }

    actor Calls {
        var all: [[String]] = []
        func add(_ arguments: [String]) { all.append(arguments) }
    }

    @Test func droppedAppMatchesListedAppThroughSymlinksAndDotDot() throws {
        let real = try app("Applications/Barista.app", bundleID: "com.foo.Bar")
        let link = home.appending(path: "Desktop/Barista alias.app")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let listed = InstalledApp(url: real, name: "Barista", bundleID: "com.foo.Bar", version: nil, lastUsed: nil)
        let other = try app("Other/Barista.app", bundleID: "com.foo.Other")
        for dropped in [real, link, home.appending(path: "Desktop/../Applications/Barista.app"),
                        URL(fileURLWithPath: real.path + "/", isDirectory: true)] {
            #expect(UninstallerModel.listedApp(for: dropped, in: [listed]) == real, "\(dropped.path)")
        }
        #expect(UninstallerModel.listedApp(for: other, in: [listed]) == nil)
    }

    @MainActor @Test func dropSelectsListedAppOnlyAndExplainsTheRest() throws {
        let listed = try app("Applications/Barista.app", bundleID: "com.foo.Bar")
        let model = UninstallerModel()
        model.apps = [InstalledApp(url: listed, name: "Barista", bundleID: "com.foo.Bar", version: nil, lastUsed: nil)]
        model.search = "zzz"
        #expect(model.drop([try make("notes.txt")]) == false)
        #expect(model.dropRejection == .notApp && model.selection == nil && model.search == "zzz")
        #expect(model.drop([try app("Other/Safari.app", bundleID: "com.apple.Safari")]) == false)
        #expect(model.dropRejection == .notListed && model.selection == nil)
        #expect(model.drop([listed]))
        #expect(model.selection == .app(listed) && model.search.isEmpty)
        model.selection = nil
        model.working = true // removing: drops are ignored
        model.dropRejection = nil
        #expect(model.drop([listed]) == false && model.selection == nil && model.dropRejection == nil)
    }

    /// Name A–Z (natural order); size largest first; last used oldest first; unknown size/date last; ties by name.
    @Test(arguments: [
        (UninstallerModel.AppSort.name, ["app 2", "App 10", "beta", "Delta", "Gamma"]),
        (.size, ["Gamma", "app 2", "App 10", "Delta", "beta"]),
        (.lastUsed, ["Delta", "beta", "Gamma", "app 2", "App 10"]),
    ])
    func sortsApps(sort: UninstallerModel.AppSort, expected: [String]) {
        let day: TimeInterval = 86_400
        let apps: [(String, Int64?, Date?)] = [
            ("Gamma", 900, Date(timeIntervalSince1970: 5 * day)),
            ("beta", nil, Date(timeIntervalSince1970: 3 * day)),
            ("App 10", 100, nil),
            ("Delta", 100, Date(timeIntervalSince1970: 1 * day)),
            ("app 2", 500, nil),
        ]
        let installed = apps.map {
            InstalledApp(url: URL(filePath: "/Applications/\($0.0).app"), name: $0.0, bundleID: "x.\($0.0)", version: nil, lastUsed: $0.2)
        }
        let sizes = Dictionary(uniqueKeysWithValues: zip(installed, apps).compactMap { app, s in s.1.map { (app.url, $0) } })
        #expect(UninstallerModel.sorted(installed, by: sort, sizes: sizes).map(\.name) == expected)
    }

    /// "Not used for" filter: older than the cutoff or no date (never seen opened) is listed; combines with search.
    @Test(arguments: [
        (UninstallerModel.UnusedFilter.all, "", ["Fresh", "Old", "Ancient", "Unknown"]),
        (.months3, "", ["Old", "Ancient", "Unknown"]),
        (.months6, "", ["Old", "Ancient", "Unknown"]),
        (.year1, "", ["Ancient", "Unknown"]),
        (.months3, "an", ["Ancient"]),       // search narrows the filtered list ("Unknown" has no "an")
        (.all, "x.fresh", ["Fresh"]),        // bundle id search still works
    ])
    func filtersUnusedApps(unused: UninstallerModel.UnusedFilter, search: String, expected: [String]) {
        let now = Date(timeIntervalSince1970: 1_000 * 86_400)
        let day: TimeInterval = 86_400
        let apps = [("Fresh", -10.0), ("Old", -200), ("Ancient", -400), ("Unknown", nil)].map { (name: String, age: Double?) in
            InstalledApp(url: URL(filePath: "/Applications/\(name).app"), name: name, bundleID: "x.\(name.lowercased())",
                         version: nil, lastUsed: age.map { now.addingTimeInterval($0 * day) })
        }
        #expect(UninstallerModel.filtered(apps, search: search, unused: unused, now: now).map(\.name) == expected)
    }

    /// The selected app hidden by the filter is deselected, like the search does.
    @MainActor @Test func unusedFilterDeselectsHiddenApp() {
        let model = searchModel()
        let zed = model.apps[2]
        model.apps[2] = InstalledApp(url: zed.url, name: zed.name, bundleID: zed.bundleID, version: nil, lastUsed: .now)
        model.selection = .app(zed.url)
        model.unused = .months3
        #expect(model.selection == nil)
        #expect(model.filteredApps.map(\.name) == ["Barista", "Café Notes"])
    }

    /// "No matching apps" only when the search/filter hid every app, never for an empty or loading list.
    @Test(arguments: [
        (0, 0, "", UninstallerModel.UnusedFilter.months3, nil),   // no app at all (or still loading)
        (3, 1, "a", .months3, nil),                               // rows show
        (3, 0, "zzz", .all, [.clearSearch]),
        (3, 0, "", .year1, [.showAll]),
        (3, 0, "zzz", .months6, [.clearSearch, .showAll]),
    ] as [(Int, Int, String, UninstallerModel.UnusedFilter, [UninstallerModel.NoMatchFix]?)])
    func noMatchFixes(appCount: Int, shown: Int, search: String, unused: UninstallerModel.UnusedFilter,
                      expected: [UninstallerModel.NoMatchFix]?) {
        #expect(UninstallerModel.noMatchFixes(appCount: appCount, shownCount: shown, search: search, unused: unused) == expected)
    }

    /// Fake apps only (no files on disk); nothing is read or trashed.
    @MainActor func searchModel() -> UninstallerModel {
        let model = UninstallerModel()
        model.apps = [("Barista", "com.foo.Bar"), ("Café Notes", "org.example.notes"), ("Zed", "dev.zed.Zed")].map {
            InstalledApp(url: URL(filePath: "/Applications/\($0.0).app"), name: $0.0, bundleID: $0.1, version: nil, lastUsed: nil)
        }
        return model
    }

    @MainActor @Test(arguments: [
        ("", ["Barista", "Café Notes", "Zed"]), // empty search lists everything
        ("bar", ["Barista"]),                  // name, case-insensitive
        ("cafe", ["Café Notes"]),              // diacritic-insensitive
        ("ORG.EXAMPLE", ["Café Notes"]),       // bundle id
        ("zed.z", ["Zed"]),
        ("qqq", []),
    ])
    func searchFiltersByNameOrBundleID(search: String, expected: [String]) {
        let model = searchModel()
        model.search = search
        #expect(model.filteredApps.map(\.name) == expected)
    }

    @MainActor @Test func searchDeselectsOnlyAnAppItHides() {
        let model = searchModel()
        let barista = model.apps[0].url
        model.selection = .app(barista)
        model.search = "BAR" // still listed: kept
        #expect(model.selection == .app(barista))
        model.search = "zed" // hidden: deselected
        #expect(model.selection == nil && model.selectedApp == nil)
        model.search = "" // clearing does not bring the selection back
        #expect(model.selection == nil)
        model.selection = .leftovers // not an app: never touched by the search
        model.search = "qqq"
        #expect(model.selection == .leftovers)
    }

    /// App row unticked = reset: only the ticked data reaches the (fake) Trash, the app stays listed and its data reloads;
    /// ticked = uninstall as before. Fake paths and hooks only: nothing real is read or trashed.
    @MainActor @Test func untickedAppResetsDataAndKeepsApp() async {
        let app = InstalledApp(url: URL(filePath: "/nonexistent/Resettable.app"), name: "Resettable",
                               bundleID: "com.test.qqx.resettable", version: nil, lastUsed: nil)
        let (cache, prefs) = (URL(filePath: "/nonexistent/Library/Caches/qqx"), URL(filePath: "/nonexistent/Library/Preferences/qqx.plist"))
        let model = UninstallerModel()
        model.apps = [app]
        model.appSizes = [app.url: 1000]
        var loads = 0
        model.appData = { _, _, _ in loads += 1; return [AppDataEntry(url: cache, size: 30), AppDataEntry(url: prefs, size: 4)] }
        var calls: [(URL?, [URL])] = []
        model.trash = { calls.append(($0, $1.map(\.url))); return CleanReport(freed: 30) }
        model.selection = .app(app.url)
        await model.loadEntries()
        #expect(model.trashApp && model.checkedSize == 1034) // default: the app is ticked as before
        model.trashApp = false
        model.checked.remove(prefs)
        #expect(model.checkedSize == 30) // the app's size no longer counted
        await model.remove()
        #expect(calls.count == 1 && calls[0].0 == nil && calls[0].1 == [cache])
        #expect(model.apps.map(\.url) == [app.url] && model.selection == .app(app.url))
        #expect(loads == 2 && model.entries.count == 2 && !model.trashApp) // data listed again, still in reset mode
        model.checked = [] // nothing ticked and the app unticked: nothing to do
        await model.remove()
        #expect(calls.count == 1)
        model.selection = nil
        model.selection = .app(app.url) // picking the app again ticks it again
        #expect(model.trashApp)
        await model.loadEntries()
        await model.remove()
        #expect(calls.count == 2 && calls[1].0 == app.url && calls[1].1.count == 2)
        #expect(model.apps.isEmpty && model.selection == nil)
    }

    /// Space on highlighted rows: any tickable one off → tick all, else untick all; locked rows untouched.
    @MainActor @Test func spaceTogglesHighlightedRows() {
        let model = UninstallerModel()
        let app = InstalledApp(url: URL(filePath: "/nonexistent/A.app"), name: "A", bundleID: "com.test.a", version: nil, lastUsed: nil)
        let a = URL(filePath: "/nonexistent/a"), b = URL(filePath: "/nonexistent/b")
        model.apps = [app]
        model.selection = .app(app.url)
        model.entries = [AppDataEntry(url: a, size: 1), AppDataEntry(url: b, size: 1)]
        model.checked = [a]
        model.toggle(urls: [a, b, app.url]) // b off → tick all (app already ticked stays ticked)
        #expect(model.checked == [a, b] && model.trashApp)
        model.toggle(urls: [a, b, app.url]) // all on → untick all, app row too (reset)
        #expect(model.checked.isEmpty && !model.trashApp)
        model.toggle(urls: [app.url])
        #expect(model.trashApp && model.checked.isEmpty)
        model.working = true
        model.toggle(urls: [a])
        #expect(model.checked.isEmpty)
        model.working = false

        let pane = URL(filePath: "/nonexistent/Library/PreferencePanes/X.prefPane")
        let ql = URL(filePath: "/nonexistent/Library/QuickLook/Q.qlgenerator")
        let apple = URL(filePath: "/nonexistent/Library/QuickLook/A.qlgenerator")
        let wrong = URL(filePath: "/nonexistent/Library/QuickLook/W.txt")
        model.extensionItems = [
            ExtensionItem(url: pane, kind: .preferencePane, modified: nil, bundleID: "com.x.pane", owner: nil, appRemoved: true),
            ExtensionItem(url: ql, kind: .quickLook, modified: nil, bundleID: "com.x.ql", owner: nil, appRemoved: true),
            ExtensionItem(url: apple, kind: .quickLook, modified: nil, bundleID: "com.apple.a", owner: nil, appRemoved: false),
            ExtensionItem(url: wrong, kind: .quickLook, modified: nil, bundleID: nil, owner: nil, appRemoved: true)]
        model.selection = .extensions
        #expect(model.highlighted.isEmpty)
        model.runningApps = [UninstallerModel.systemSettingsID] // the pane is locked while System Settings is open
        model.toggle(urls: [pane, ql, apple, wrong])
        #expect(model.checked == [ql])
        model.toggle(urls: [apple, wrong]) // only locked rows: nothing changes
        #expect(model.checked == [ql])
        model.runningApps = []
        model.toggle(urls: [pane, ql]) // pane off → both on
        #expect(model.checked == [pane, ql])
        model.toggle(urls: [pane, ql])
        #expect(model.checked.isEmpty)
    }
}
