import AppIntents
import AppKit

// Actions for the Shortcuts app, Spotlight and Siri. None of them deletes anything: Clean Selected Junk only opens the
// review in CleanMate, where the user confirms. Nothing runs on a timer either; a schedule is the user's own shortcut.

/// The Smart Scan groups a Shortcuts scan can be limited to: the command line's `--group` names (Privacy is not junk).
nonisolated enum ShortcutsScanGroup: String, AppEnum {
    case system, user, dev, ai, apps

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Scan Group"
    static let caseDisplayRepresentations: [ShortcutsScanGroup: DisplayRepresentation] = [
        .system: "System Junk",
        .user: "Trash",
        .dev: "Developer Junk",
        .ai: "AI Tools",
        .apps: "Applications",
    ]
}

nonisolated extension Module: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Module"
    static let caseDisplayRepresentations: [Module: DisplayRepresentation] = [
        .overview: "Overview",
        .smartScan: "Smart Scan",
        .privacy: "Privacy",
        .largeFiles: "Large & Old Files",
        .uninstaller: "Uninstaller",
        .spaceLens: "Space Lens",
        .loginItems: "Login Items",
        .maintenance: "Maintenance",
    ]
}

/// What Scan for Junk passes to the next action.
struct JunkScanResult: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Junk Scan"

    @Property(title: "Junk in Bytes") var junk: Int
    @Property(title: "Items") var items: Int
    @Property(title: "Summary") var summary: String
    @Property(title: "Full Disk Access") var fullDiskAccess: Bool

    init() {}

    init(_ scan: ShortcutsSummary.Scan, summary: String) {
        junk = Int(scan.junk)
        items = scan.items
        self.summary = summary
        fullDiskAccess = scan.fullDiskAccess
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(summary)") }
}

/// What Free Space passes to the next action.
struct FreeSpaceResult: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Free Space"

    @Property(title: "Free Bytes") var free: Int
    @Property(title: "Capacity in Bytes") var capacity: Int
    @Property(title: "Junk Found by the Last Scan in Bytes") var lastScanJunk: Int
    @Property(title: "Summary") var summary: String

    init() {}

    init(_ volume: DiskVolume, last: LastScan?, summary: String) {
        free = Int(volume.available)
        capacity = Int(volume.total)
        lastScanJunk = Int(last?.junk ?? 0)
        self.summary = summary
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(summary)") }
}

/// Scans like Smart Scan, with Scan Groups, Exclusions and Full Disk Access as set, and reports the junk. Read-only:
/// nothing is ticked, cleaned, logged or saved (the same scan as `cleanmate scan`).
struct ScanJunkIntent: AppIntent {
    static var title: LocalizedStringResource = "Scan for Junk"
    static var description = IntentDescription("Scans for junk like Smart Scan, with your Scan Groups and Exclusions, and reports how much can be cleaned. Nothing is deleted.")

    @Parameter(title: "Group", description: "Scan only this group. Leave it empty to scan the groups turned on in Settings.")
    var group: ShortcutsScanGroup?

    static var parameterSummary: some ParameterSummary { Summary("Scan for junk in \(\.$group)") }

    func perform() async throws -> some IntentResult & ReturnsValue<JunkScanResult> & ProvidesDialog {
        let report = await Self.scan(group)
        let scan = ShortcutsSummary.scan(report, titles: ShortcutsSummary.groupTitles())
        let text = ShortcutsSummary.text(scan)
        return .result(value: JunkScanResult(scan, summary: text), dialog: IntentDialog("\(text)"))
    }

    /// Off the main thread: the window stays responsive while it scans.
    @concurrent static func scan(_ group: ShortcutsScanGroup?,
                                 sources: HeadlessScan.Sources = HeadlessScan.Sources()) async -> HeadlessScan.Report {
        await HeadlessScan.scan(HeadlessScan.Options(groups: group.map { [$0.rawValue] }), sources: sources)
    }
}

/// Free space on the startup volume and the junk the last Smart Scan found; scans nothing.
struct FreeSpaceIntent: AppIntent {
    static var title: LocalizedStringResource = "Free Space"
    static var description = IntentDescription("Shows the free space on your Mac and the junk the last Smart Scan found.")

    func perform() async throws -> some IntentResult & ReturnsValue<FreeSpaceResult> & ProvidesDialog {
        let volume = DiskVolume.read(SafetyPolicy.current.homeURL), last = LastScan.read()
        let text = ShortcutsSummary.spaceText(volume, last: last)
        return .result(value: FreeSpaceResult(volume, last: last, summary: text), dialog: IntentDialog("\(text)"))
    }
}

/// Opens Smart Scan with the review of the ticked junk (scanning first when there are no results). It never cleans:
/// the user confirms in the review, as after Clean….
struct CleanSelectedIntent: AppIntent {
    static var title: LocalizedStringResource = "Clean Selected Junk"
    static var description = IntentDescription("Opens Smart Scan with the review of the junk ticked, scanning first if needed. Nothing is deleted until you confirm in CleanMate.")
    static var openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        ModuleRouter.shared.reviewClean()
        return .result()
    }
}

/// Opens CleanMate on a module.
struct OpenModuleIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Module"
    static var description = IntentDescription("Opens CleanMate on a module, such as Smart Scan, Large & Old Files or the Uninstaller.")
    static var openAppWhenRun = true

    @Parameter(title: "Module") var module: Module

    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$module)") }

    @MainActor func perform() async throws -> some IntentResult {
        ModuleRouter.shared.show(module)
        return .result()
    }
}

/// The actions Spotlight and Siri offer without a shortcut being made; phrases in other languages are in
/// vi.lproj/AppShortcuts.strings (a string catalog needs macOS 14).
struct CleanMateShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .teal

    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ScanJunkIntent(), phrases: [
            "Scan junk with \(.applicationName)",
            "Scan for junk in \(.applicationName)",
            "\(.applicationName) scan junk",
        ], shortTitle: "Scan Junk", systemImageName: "sparkles")
        AppShortcut(intent: CleanSelectedIntent(), phrases: [
            "Clean junk with \(.applicationName)",
            "Clean selected junk in \(.applicationName)",
            "\(.applicationName) clean junk",
        ], shortTitle: "Clean Selected Junk", systemImageName: "trash")
        AppShortcut(intent: FreeSpaceIntent(), phrases: [
            "Free space in \(.applicationName)",
            "How much space is free in \(.applicationName)",
            "\(.applicationName) free space",
        ], shortTitle: "Free Space", systemImageName: "internaldrive")
        AppShortcut(intent: OpenModuleIntent(), phrases: [
            "Open \(\.$module) in \(.applicationName)",
            "\(.applicationName) open \(\.$module)",
            "Open a module in \(.applicationName)",
        ], shortTitle: "Open Module", systemImageName: "macwindow")
    }
}

/// Settings › Integrations › Open Shortcuts.
enum ShortcutsApp {
    static let bundleID = "com.apple.shortcuts"

    static func open() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
