import AppKit
import SwiftUI
import Testing
@testable import CleanMate

/// Offscreen PNGs of every main screen, EN + VI, light + dark, with fixed sample data (no real HOME scan).
/// Skipped unless `CLEANMATE_SNAPSHOTS=1` reaches the test runner:
///   TEST_RUNNER_CLEANMATE_SNAPSHOTS=1 xcodebuild … test -only-testing:CleanMateTests/UISnapshots
/// Writes `$TMPDIR/CleanMateSnapshots/<screen>-<en|vi>-<light|dark>.png` and prints the folder.
/// Each module's detail view is rendered alone (models are private @State of ContentView), at the detail size of a
/// 920×600 window; no screen-recording permission is needed (`cacheDisplay` of an NSHostingView in an offscreen window).
/// Language: `\.locale` in the environment, which SwiftUI uses to look up `Text` keys in the String Catalog.
/// Also formats `Text(x, format:)` dates/sizes. Limit: the window title (`.navigationTitle`) and `String(localized:)`
/// outside views follow the test process language (EN) even in VI shots; the real app uses its bundle language.
/// Limit: the selected segment label of the Settings TabView stays blank in `cacheDisplay` (fine in the real window and in
/// `screencapture -l`); a key/main NSWindow subclass and `CALayer.render` did not help.
/// Same code gives byte-identical PNGs run to run, except the collapsed 16 px toolbar search icon of
/// `largefiles-results-*`. Sample dates count back from the fixed `today`, not `.now`. Also seen while other builds
/// loaded the Mac: Uninstaller light app icons off by 1 color level (x 19–34), once Settings VI in English and Space
/// Lens changed; rerun on an idle Mac before trusting a diff. Each shot is retaken until 2 in a row match; dark
/// Smart Scan checkboxes still vary by 2 color levels between runs (snapshot-diff tolerance 2).
/// Search icon, why not fixed (macOS 27): AppKit gives the icon's `ImageLayer` (in `NSSearchToolbarItemView`) a
/// random vibrancy per window: a `vibrantColorMatrix` filter, `plusL`/`plusD` compositing, or none; each draws a
/// different grey. Tried, none deterministic: animations off (`.transaction`), window ordered front off screen (display
/// link runs), clearing filters before `cacheDisplay` (AppKit sets them again while drawing), new window until a fixed
/// vibrancy kind (dark with `plusL` became stable, but light gives 2 results from the same layer state). Compare those
/// shots by eye, or ignore pixels x 686–701, y 18–34.
/// Before/after compare: run, `cp -R "$TMPDIR/CleanMateSnapshots" /tmp/before`, change code, run again, then
/// `scripts/snapshot-diff.sh /tmp/before "$TMPDIR/CleanMateSnapshots"` (masks that icon, lists changed PNGs, exit 1 if any).
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CLEANMATE_SNAPSHOTS"] == "1"))
struct UISnapshots {
    static let folder = FileManager.default.temporaryDirectory.appending(path: "CleanMateSnapshots")
    nonisolated static let detailSize = CGSize(width: 720, height: 600)
    static let sample = URL(fileURLWithPath: "/Users/Shared/Sample")
    /// Fixed "now" for sample dates so shots do not change at midnight; noon UTC keeps the day in any time zone near UTC.
    static let today = Date(timeIntervalSince1970: 1_768_478_400) // 2026-01-15 12:00 UTC
    /// Language of the shot being rendered, for sample labels built with `String(localized:)`.
    static var language = "en"

    /// Renders `view` in the 4 variants and checks each PNG is not a blank fill.
    func snapshot(_ name: String, size: CGSize = detailSize, _ view: @escaping () -> some View) async throws {
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        for language in ["en", "vi"] {
            Self.language = language
            for dark in [false, true] {
                let host = NSHostingView(rootView: view()
                    .environment(\.locale, Locale(identifier: language))
                    .environment(\.controlActiveState, .key) // window is never key: else prominent buttons draw grey
                    .frame(width: size.width, height: size.height)
                    .background(Color(nsColor: .windowBackgroundColor))) // else plain SwiftUI areas are transparent in the PNG
                let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                      backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                if #available(macOS 14, *) { // shots are taken on the dev Mac; on 13 they lack the title bar and toolbar
                    host.sceneBridgingOptions = [.toolbars, .title] // .toolbar / .searchable / .navigationTitle go to the window
                }
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(600)) // let .task, List/Table and images settle
                // The window's frame view, so the title bar and toolbar are in the picture.
                let frame = try #require(host.superview)
                // On a busy Mac 600 ms is sometimes not enough (Table filler rows missing, checkbox mid-fade):
                // shoot again until 2 shots in a row match, at most 5 extra.
                var png = Data()
                for _ in 0..<6 {
                    host.layoutSubtreeIfNeeded()
                    let rep = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
                    frame.cacheDisplay(in: frame.bounds, to: rep)
                    let shot = try #require(rep.representation(using: .png, properties: [:]))
                    #expect(Self.colorCount(rep) > 2, "blank snapshot: \(name)")
                    if shot == png { break }
                    png = shot
                    try await Task.sleep(for: .milliseconds(200))
                }
                let url = Self.folder.appending(path: "\(name)-\(language)-\(dark ? "dark" : "light").png")
                try png.write(to: url)
                window.close()
            }
        }
        print("SNAPSHOTS \(Self.folder.path)")
    }

    /// Distinct colors on a coarse grid; 1–2 means a blank fill.
    static func colorCount(_ rep: NSBitmapImageRep) -> Int {
        var colors = Set<String>()
        for x in stride(from: 0, to: rep.pixelsWide, by: 7) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 7) {
                if let c = rep.colorAt(x: x, y: y) { colors.insert("\(c)") }
            }
        }
        return colors.count
    }

    /// Smart Scan / Privacy model on its real catalog with made-up results; nothing is scanned.
    func cleanerModel(_ module: Module) -> SmartScanModel {
        // The real catalog, not as this Mac's Full Disk Access, Settings › ages or Scan Groups shape it.
        let model = SmartScanModel(module: module) { module == .privacy ? CleanerGroup.privacy : CleanerGroup.smartScan(ages: .default, hasFullDiskAccess: true) }
        model.runningApps = []
        model.runningProcesses = []
        // An app launching or quitting on this Mac mid-shot would reload runningApps from the real list.
        model.appBundleIDs = { [weak model] in model?.runningApps ?? [] }
        return model
    }

    func fill(_ model: SmartScanModel, upTo limit: Int = .max) {
        let items = model.groups.flatMap(\.items)
        model.totalItems = items.count
        for (index, item) in items.prefix(limit).enumerated() {
            let size = Int64((index * 7_919) % 900 + 1) * 1_300_000
            let entry = item.database == nil
                ? ScanEntry(url: Self.sample.appending(path: item.id), size: size)
                : ScanEntry(url: Self.sample.appending(path: item.id), size: 0, isDatabase: true, records: index * 37 + 12)
            model.scans[item.id] = ItemScan(entries: [entry])
            if item.selectedByDefault { model.selected.insert(item.id) }
            model.scannedItems = index + 1
        }
    }

    @Test func smartScan() async throws {
        // Fixed disk/freed values so the idle overview never reads the real disk; the second one is low on space.
        try await snapshot("smartscan-1-idle") {
            SmartScanView(model: cleanerModel(.smartScan), module: .smartScan, readOverview: {
                .init(volume: .init(name: "Macintosh HD", total: 494_000_000_000, available: 182_000_000_000), freed30Days: 3_400_000_000)
            })
        }
        try await snapshot("smartscan-1-idle-low") {
            SmartScanView(model: cleanerModel(.smartScan), module: .smartScan, readOverview: {
                .init(volume: .init(name: "Macintosh HD", total: 494_000_000_000, available: 21_000_000_000), freed30Days: 0)
            })
        }
        try await snapshot("smartscan-2-scanning") {
            let model = cleanerModel(.smartScan)
            model.phase = .scanning
            fill(model, upTo: model.groups.flatMap(\.items).count / 2)
            return SmartScanView(model: model, module: .smartScan)
        }
        try await snapshot("smartscan-3-results") {
            let model = cleanerModel(.smartScan)
            fill(model)
            model.phase = .results
            return SmartScanView(model: model, module: .smartScan)
        }
        // Every group but the first folded away; headers keep their totals and group checkboxes.
        try await snapshot("smartscan-3-results-collapsed") {
            let model = cleanerModel(.smartScan)
            fill(model)
            model.collapsedGroups = Set(model.groups.dropFirst().map(\.id))
            model.phase = .results
            return SmartScanView(model: model, module: .smartScan)
        }
        // Rows highlighted for the keyboard (arrows + Space), one ticked and one not, next to the checkboxes.
        try await snapshot("smartscan-3-results-highlighted") {
            let model = cleanerModel(.smartScan)
            fill(model)
            let items = model.groups[0].items
            model.highlighted = [items[0].id, items[1].id]
            model.phase = .results
            return SmartScanView(model: model, module: .smartScan)
        }
        // One item unfolded: its path rows sit under the title, sizes in the item's size column.
        try await snapshot("smartscan-3-results-expanded") {
            let model = cleanerModel(.smartScan)
            fill(model)
            let items = Array(model.groups[0].items.prefix(3))
            model.scans[items[0].id]?.entries = ["Caches/com.example.app", "Caches/com.example.tool/blobs", "Caches/com.example.browser"]
                .enumerated().map { ScanEntry(url: Self.sample.appending(path: $1), size: Int64(3 - $0) * 210_000_000) }
            return List(items) { item in
                CleanerItemRow(item: item, scan: model.scans[item.id], isOn: .constant(model.selected.contains(item.id)),
                               isRunning: false, quit: {}, groupImage: model.groups[0].systemImage,
                               largestInGroup: 700_000_000, isExpanded: item.id == items[0].id)
            }
        }
        // An item with per-entry ticks, one of three archives left out: the item checkbox shows mixed.
        try await snapshot("smartscan-3-results-entries") {
            let model = cleanerModel(.smartScan)
            fill(model)
            let item = try! #require(model.groups.flatMap(\.items).first { $0.id == "xcode-archives" })
            model.scans[item.id]?.entries = ["2025-03-02/App 3-2-25.xcarchive", "2025-06-11/App 6-11-25.xcarchive",
                                             "2025-09-20/App 9-20-25.xcarchive"]
                .enumerated().map { ScanEntry(url: Self.sample.appending(path: "Archives/" + $1), size: Int64(3 - $0) * 410_000_000) }
            model.selected.insert(item.id)
            model.setEntry(item, model.scans[item.id]!.entries[1].url, false)
            return List([item]) { item in
                CleanerItemRow(item: item, scan: model.scans[item.id],
                               isOn: .init(get: { model.selected.contains(item.id) }, set: { model.setSelected(item, $0) }),
                               isRunning: false, quit: {}, groupImage: "hammer", largestInGroup: 1_230_000_000, isExpanded: true,
                               entryOn: { url in .init(get: { model.isEntrySelected(item, url) }, set: { model.setEntry(item, url, $0) }) },
                               selectedSize: model.partialSelectedSize(item))
            }
        }
        // Labelled entries: DerivedData projects with their workspace and last-opened date, one DeviceSupport version.
        try await snapshot("smartscan-3-results-labelled") {
            let model = cleanerModel(.smartScan)
            fill(model)
            let all = model.groups.flatMap(\.items)
            let items = ["xcode-derived-data", "xcode-device-support"].compactMap { id in all.first { $0.id == id } }
            let derived = Self.sample.appending(path: "Library/Developer/Xcode/DerivedData")
            model.scans[items[0].id]?.entries = [
                ScanEntry(url: derived.appending(path: "CleanMate-bqzxkvhdmwpyfkgdtsoaucnhrjle"), size: 2_140_000_000,
                          title: "CleanMate · ~/Developer/cleanmate/CleanMate.xcodeproj", date: Self.today.addingTimeInterval(-2 * 86_400)),
                ScanEntry(url: derived.appending(path: "Weather-fhwqzjtnlcyrbmdgkoaexpsuivht"), size: 860_000_000,
                          title: "Weather · ~/Projects/Weather/Weather.xcworkspace", date: Self.today.addingTimeInterval(-41 * 86_400)),
                ScanEntry(url: derived.appending(path: "ModuleCache.noindex"), size: 310_000_000,
                          title: XcodeData.derivedDataLabel(of: derived.appending(path: "ModuleCache.noindex"), locale: Locale(identifier: Self.language))?.title),
            ]
            model.scans[items[1].id]?.entries = [
                ScanEntry(url: Self.sample.appending(path: "Library/Developer/Xcode/iOS DeviceSupport/iPhone15,2 18.1 (22B83)"),
                          size: 4_200_000_000, title: "iOS 18.1 (22B83)"),
            ]
            model.selected.formUnion(items.map(\.id))
            return List(items) { item in
                CleanerItemRow(item: item, scan: model.scans[item.id],
                               isOn: .init(get: { model.selected.contains(item.id) }, set: { model.setSelected(item, $0) }),
                               isRunning: false, quit: {}, groupImage: "hammer", largestInGroup: 4_200_000_000, isExpanded: true,
                               entryOn: { url in .init(get: { model.isEntrySelected(item, url) }, set: { model.setEntry(item, url, $0) }) },
                               selectedSize: model.partialSelectedSize(item))
            }
        }
        try await snapshot("smartscan-4-cleaning") {
            let model = cleanerModel(.smartScan)
            model.phase = .cleaning
            model.scannedItems = 3
            model.totalItems = 12
            model.cleaningItem = model.groups[0].items[0].title
            return SmartScanView(model: model, module: .smartScan)
        }
        try await snapshot("smartscan-5-done") {
            let model = cleanerModel(.smartScan)
            model.phase = .done(CleanReport(freed: 3_456_000_000, upTo: 300_000_000, skipped: 2))
            model.freeSpaceChange = .init(before: 41_200_000_000, after: 44_600_000_000, total: 494_000_000_000)
            let g = model.groups
            model.cleanedGroups = [
                .init(id: g[0].id, title: g[0].title, systemImage: g[0].systemImage, freed: 2_100_000_000),
                .init(id: g[1].id, title: g[1].title, systemImage: g[1].systemImage, freed: 1_356_000_000, trashed: 900_000_000),
            ]
            return SmartScanView(model: model, module: .smartScan)
        }
        try await snapshot("privacy-results") {
            let model = cleanerModel(.privacy)
            fill(model)
            // One row locked by a running app and one without Full Disk Access, to show their links.
            let items = model.groups.flatMap(\.items)
            if let locked = items.first(where: { !$0.runningAppBundleIDs.isEmpty }) {
                model.runningApps = Set(locked.runningAppBundleIDs)
                model.selected.remove(locked.id)
            }
            model.scans[items[0].id]?.permissionDenied = true
            model.phase = .results
            return SmartScanView(model: model, module: .privacy)
        }
        // Only database items selected: the footer total is "N records", no bytes.
        try await snapshot("privacy-records-only") {
            let model = cleanerModel(.privacy)
            fill(model)
            let items = model.groups.flatMap(\.items)
            model.selected = Set(items.filter { $0.database != nil }.map(\.id))
            model.phase = .results
            return SmartScanView(model: model, module: .privacy)
        }
    }

    @Test func largeFiles() async throws {
        let day: TimeInterval = 86_400
        let files: [(String, Int64, Double, FileKind)] = [
            ("Movies/Holiday 2023.mov", 4_800_000_000, 400, .video),
            ("Downloads/macOS-Installer.dmg", 13_200_000_000, 200, .installer),
            ("Documents/Backup/Photos.zip", 2_100_000_000, 800, .archive),
            ("Downloads/Dataset.csv", 640_000_000, 30, .other),
            ("Desktop/Recording.m4a", 180_000_000, 5, .other),
        ]
        try await snapshot("largefiles-results") {
            let model = LargeFilesModel()
            model.files = files.map {
                LargeFile(url: Self.sample.appending(path: $0.0), size: $0.1, lastUsed: Self.today.addingTimeInterval(-$0.2 * day), kind: $0.3,
                          home: Self.sample)
            }.sorted { $0.size > $1.size }
            model.checked = [model.files[0].url]
            model.skippedProtected = true // no Full Disk Access: shows the note
            model.phase = .results
            return LargeFilesView(model: model)
        }
        // Duplicates filter: two copies of the installer, three of the movie; nothing ticked for the user.
        // Wider than the other screens so the toolbar shows the Duplicates picker instead of moving it to the overflow menu.
        try await snapshot("largefiles-duplicates", size: CGSize(width: 1_000, height: 600)) {
            let model = LargeFilesModel()
            let copies: [(String, Int64, Double, FileKind)] = [
                ("Desktop/macOS-Installer copy.dmg", 13_200_000_000, 200, .installer),
                ("Movies/Old/Holiday 2023.mov", 4_800_000_000, 700, .video),
                ("Desktop/Holiday 2023 (1).mov", 4_800_000_000, 380, .video),
            ]
            model.files = (files + copies).map {
                LargeFile(url: Self.sample.appending(path: $0.0), size: $0.1, lastUsed: Self.today.addingTimeInterval(-$0.2 * day), kind: $0.3,
                          home: Self.sample)
            }.sorted { $0.size > $1.size }
            let url = { (path: String) in Self.sample.appending(path: path) }
            model.duplicateGroups = [
                [url("Desktop/macOS-Installer copy.dmg"), url("Downloads/macOS-Installer.dmg")],
                [url("Desktop/Holiday 2023 (1).mov"), url("Movies/Holiday 2023.mov"), url("Movies/Old/Holiday 2023.mov")],
            ]
            model.duplicatesOnly = true
            model.phase = .results
            return LargeFilesView(model: model)
        }
        try await snapshot("largefiles-done") {
            let model = LargeFilesModel()
            let moved = TrashedItem(original: Self.sample.appending(path: "Movies/Holiday 2023.mov"),
                                    inTrash: URL(fileURLWithPath: "/tmp/Holiday 2023.mov"), size: 4_800_000_000)
            model.phase = .done(CleanReport(freed: 4_800_000_000, skipped: 0, trashed: [moved])) // "Undo" shown
            return LargeFilesView(model: model)
        }
        // Locked in Finder count apart from skipped.
        try await snapshot("largefiles-done-locked") {
            let model = LargeFilesModel()
            model.phase = .done(CleanReport(freed: 4_800_000_000, skipped: 1, locked: 2))
            return LargeFilesView(model: model)
        }
        // Scope: only Downloads, its name under the title; then a protected scope without Full Disk Access.
        try await snapshot("largefiles-scope") {
            let model = LargeFilesModel()
            model.home = Self.sample
            model.hasFullDiskAccess = { true }
            model.scanFiles = { _, _, _, _ in try await Task.sleep(for: .seconds(3600)); return [] } // never ends: results below stay
            model.setScope(Self.sample.appending(path: "Downloads"))
            model.files = files.filter { $0.0.hasPrefix("Downloads/") }.map {
                LargeFile(url: Self.sample.appending(path: $0.0), size: $0.1, lastUsed: Self.today.addingTimeInterval(-$0.2 * day), kind: $0.3,
                          home: Self.sample)
            }.sorted { $0.size > $1.size }
            model.phase = .results
            return LargeFilesView(model: model)
        }
        try await snapshot("largefiles-needs-access") {
            let model = LargeFilesModel()
            model.home = Self.sample
            model.hasFullDiskAccess = { false }
            model.setScope(Self.sample.appending(path: "Documents"))
            return LargeFilesView(model: model)
        }
        try await snapshot("largefiles-empty") {
            let model = LargeFilesModel()
            model.phase = .results
            return LargeFilesView(model: model)
        }
    }

    /// Data totals of the sample apps: Calculator's matches its listed files, one app has no data.
    static func appDataSizes(_ apps: [InstalledApp]) -> [URL: Int64] {
        Dictionary(uniqueKeysWithValues: zip(apps, [921_204_096, 1_350_000_000, 0, 12_400_000]).map { ($0.url, Int64($1)) })
    }

    @Test func uninstaller() async throws {
        let apps = ["Calculator", "TextEdit", "Chess", "Stickies"].map {
            InstalledApp(url: URL(fileURLWithPath: "/System/Applications/\($0).app"), name: $0,
                         bundleID: "com.example.\($0.lowercased())", version: "1.2", lastUsed: Self.today.addingTimeInterval(-86_400 * 40))
        }
        let library = Self.sample.appending(path: "Library")
        let data = [("Application Support/com.example.calculator", 820_000_000), ("Caches/com.example.calculator", 96_000_000),
                    ("Preferences/com.example.calculator.plist", 4_096), ("Logs/Calculator", 1_200_000)]
            .map { AppDataEntry(url: library.appending(path: $0.0), size: Int64($0.1)) }
            // Listed but never ticked: a folder only starting like the app's name, and config outside ~/Library.
            + [AppDataEntry(url: library.appending(path: "Application Support/CalculatorSoftware"), size: 2_400_000, kind: .suggested),
               AppDataEntry(url: Self.sample.appending(path: ".config/calculator"), size: 48_000, kind: .config)]
        try await snapshot("uninstaller-results") {
            let model = UninstallerModel()
            model.appData = { _, _, _ in data }
            model.apps = apps
            model.appSizes = Dictionary(uniqueKeysWithValues: apps.enumerated().map { ($1.url, Int64($0 + 1) * 45_000_000) })
            model.appDataSizes = Self.appDataSizes(apps) // Also keeps the view from measuring the real ~/Library
            model.selection = .app(apps[0].url)
            model.hiddenItems = [] // never scans the real home
            model.extensionItems = []
            return UninstallerView(model: model)
        }
        // App row unticked: Reset… keeps the app and moves only its ticked data.
        try await snapshot("uninstaller-reset") {
            let model = UninstallerModel()
            model.appData = { _, _, _ in data }
            model.apps = apps
            model.appSizes = Dictionary(uniqueKeysWithValues: apps.enumerated().map { ($1.url, Int64($0 + 1) * 45_000_000) })
            model.appDataSizes = Self.appDataSizes(apps) // Also keeps the view from measuring the real ~/Library
            model.selection = .app(apps[0].url)
            model.trashApp = false
            model.hiddenItems = []
            model.extensionItems = []
            return UninstallerView(model: model)
        }
        // "Reset…" sheet: only the app's own data, all ticked but one; the app itself is not listed.
        try await snapshot("uninstaller-reset-sheet", size: CGSize(width: 520, height: 400)) {
            let model = UninstallerModel()
            model.apps = apps
            model.runningApps = []
            model.selection = .app(apps[0].url)
            model.entries = data
            model.prepareReset()
            model.resetChecked.remove(data[3].url)
            return ResetSheet(model: model, app: apps[0])
        }
        // Read-only list of unknown hidden config: no checkbox, no footer.
        let home = URL(fileURLWithPath: "/Users/Shared/Sample")
        let hidden = [(".mysterytool", true, true), (".config/oddsync", false, true), (".legacy-cache", false, false)].map {
            HiddenConfigItem(url: home.appending(path: $0.0), modified: Self.today.addingTimeInterval(-86_400 * ($0.2 ? 2 : 90)),
                             hasExecutable: $0.1, isRecent: $0.2)
        }
        try await snapshot("uninstaller-hidden-config") {
            let model = UninstallerModel()
            model.apps = apps
            model.appSizes = Dictionary(uniqueKeysWithValues: apps.map { ($0.url, 45_000_000) })
            model.appDataSizes = Self.appDataSizes(apps) // Also keeps the view from measuring the real ~/Library
            model.hiddenItems = hidden
            model.extensionItems = []
            model.hiddenSizes = Dictionary(uniqueKeysWithValues: hidden.enumerated().map { ($1.url, Int64($0 + 1) * 3_400_000) })
            model.selection = .hiddenConfig
            return UninstallerView(model: model)
        }
        // Extensions in ~/Library: type, owning app or "App removed"; checkboxes never pre-ticked, footer.
        let samples: [(String, ExtensionItem.Kind, String?, String?, Bool)] = [
            ("PreferencePanes/SwitchResX.prefPane", .preferencePane, "fr.madrau.switchresx", nil, true),
            ("QuickLook/QLMarkdown.qlgenerator", .quickLook, "org.example.qlmarkdown", "Markdown Editor", false),
            ("Services/Resize Images.workflow", .service, nil, nil, false),
            ("Spotlight/Sketch.mdimporter", .spotlight, "com.example.sketch.mdimporter", "Sketch", false),
        ]
        let extensions = samples.enumerated().map { index, item in
            ExtensionItem(url: library.appending(path: item.0), kind: item.1,
                          modified: Self.today.addingTimeInterval(-86_400 * Double(30 * index + 3)),
                          bundleID: item.2, owner: item.3, appRemoved: item.4)
        }
        try await snapshot("uninstaller-extensions") {
            let model = UninstallerModel()
            model.apps = apps
            model.appSizes = Dictionary(uniqueKeysWithValues: apps.map { ($0.url, 45_000_000) })
            model.appDataSizes = Self.appDataSizes(apps) // Also keeps the view from measuring the real ~/Library
            model.hiddenItems = []
            model.extensionItems = extensions
            model.extensionSizes = Dictionary(uniqueKeysWithValues: extensions.enumerated().map { ($1.url, Int64($0 + 1) * 1_200_000) })
            model.selection = .extensions
            return UninstallerView(model: model)
        }
        // Leftovers of removed apps: never ticked, sizes and bars like the app's files.
        try await snapshot("uninstaller-leftovers") {
            let model = UninstallerModel()
            model.leftovers = { _ in
                [("Application Support/com.example.oldeditor", 1_400_000_000), ("Caches/com.example.oldeditor", 230_000_000),
                 ("Preferences/com.example.oldgame.plist", 8_192)]
                    .map { AppDataEntry(url: library.appending(path: $0.0), size: Int64($0.1)) }
            }
            model.apps = apps
            model.appSizes = Dictionary(uniqueKeysWithValues: apps.map { ($0.url, 45_000_000) })
            model.appDataSizes = Self.appDataSizes(apps) // Also keeps the view from measuring the real ~/Library
            model.hiddenItems = []
            model.extensionItems = []
            model.selection = .leftovers
            return UninstallerView(model: model)
        }
        // Several apps ticked: the batch panel with each app's size (app + data surely its own) and one Uninstall;
        // an open app is shown as skipped.
        try await snapshot("uninstaller-batch") {
            let model = UninstallerModel()
            model.appData = { _, _, _ in data }
            model.apps = apps
            model.appSizes = Dictionary(uniqueKeysWithValues: apps.enumerated().map { ($1.url, Int64($0 + 1) * 45_000_000) })
            model.appDataSizes = Self.appDataSizes(apps) // Also keeps the view from measuring the real ~/Library
            model.runningApps = [apps[2].bundleID]
            model.appTicks = [apps[0].url, apps[1].url, apps[2].url]
            model.batchData = Dictionary(uniqueKeysWithValues: apps.prefix(3).enumerated().map { index, app in
                (app.url, Array(data.filter { $0.kind == .data }.prefix(4 - index)))
            })
            model.hiddenItems = []
            model.extensionItems = []
            return UninstallerView(model: model)
        }
        try await snapshot("uninstaller-no-selection") {
            let model = UninstallerModel()
            model.apps = apps
            model.appSizes = Dictionary(uniqueKeysWithValues: apps.map { ($0.url, 45_000_000) })
            model.appDataSizes = Self.appDataSizes(apps) // Also keeps the view from measuring the real ~/Library
            model.hiddenItems = []
            model.extensionItems = []
            return UninstallerView(model: model)
        }
    }

    @Test func spaceLens() async throws {
        // Real files (Space Lens measures allocated size), a few MB, removed afterwards.
        let root = Self.folder.appending(path: "Sample Home")
        defer { try? FileManager.default.removeItem(at: root) }
        for (path, megabytes) in [("Developer/app/build.bin", 9), ("Movies/clip.mov", 6), ("Documents/report.pdf", 2),
                                  ("Downloads/setup.dmg", 4), ("notes.txt", 1)] {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: megabytes * 1_000_000).write(to: url)
        }
        // Stable PNG: a fixed disk (the real free space changes) and sizes measured before the window opens (the bottom
        // bar's progress spinner going away mid-layout left the table header/rows a pixel off, depending on timing).
        let model = SpaceLensModel()
        model.start(at: root)
        model.volume = .init(name: "Macintosh HD", total: 494_000_000_000, available: 182_000_000_000)
        while model.measuring { try await Task.sleep(for: .milliseconds(50)) }
        try await snapshot("spacelens-results") { SpaceLensView(model: model) }
        model.search = "zzz" // Search with no match shows the empty state; total/donut stay the whole folder
        try await snapshot("spacelens-search-empty") { SpaceLensView(model: model) }
        model.search = ""
        model.report = CleanReport(freed: 6_000_000, skipped: 1, locked: 2)
        try await snapshot("spacelens-locked") { SpaceLensView(model: model) }
        model.report = nil
        // The Move to Trash confirmation dialog does not render offscreen, so its three titles are drawn as plain text.
        let item = { (size: Int64?) in SpaceItem(url: root.appending(path: "x"), isFolder: true, size: size) }
        try await snapshot("spacelens-trash-titles", size: CGSize(width: 520, height: 160)) {
            VStack(alignment: .leading, spacing: 8) {
                Text(SpaceLensModel.trashTitle([item(nil), item(nil)]))
                Text(SpaceLensModel.trashTitle([item(4_000_000), item(nil)]))
                Text(SpaceLensModel.trashTitle([item(4_000_000), item(2_000_000)]))
            }.font(.headline).padding().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @Test func overview() async throws {
        // Empty sample folders with injected sizes, fixed drives and a sample activity log; removed afterwards.
        let root = Self.folder.appending(path: "Overview Home")
        defer { try? FileManager.default.removeItem(at: root) }
        let sizes: [String: Int64] = ["Library": 48_200_000_000, "Developer": 36_900_000_000, "Movies": 21_400_000_000,
                                      "Pictures": 12_800_000_000, "Downloads": 6_300_000_000, ".docker": 5_100_000_000,
                                      "Documents": 3_700_000_000, "Music": 1_900_000_000, "Desktop": 420_000_000]
        for name in sizes.keys {
            try FileManager.default.createDirectory(at: root.appending(path: name), withIntermediateDirectories: true)
        }
        for (days, size) in [(40.0, 3_100_000_000), (12, 2_400_000_000), (2, 1_250_000_000)] as [(Double, Int64)] {
            ActivityLog.record(module: "Smart Scan", item: "User caches", size: size, mode: .delete, home: root,
                               date: Self.today.addingTimeInterval(-days * 86_400))
        }
        let model = OverviewModel(center: NotificationCenter())
        model.home = root
        model.hasFullDiskAccess = { true }
        model.now = { Self.today }
        // A month of daily readings, slowly filling up with a clean on day 12.
        model.diskHistory = DiskHistory(file: nil, points: (0..<30).map { day in
            let free = 200_000_000_000 - Int64(day) * 1_100_000_000 + (day >= 12 ? 9_000_000_000 : 0)
            return .init(date: Self.today.addingTimeInterval(Double(day - 29) * 86_400), available: free, total: 494_000_000_000)
        })
        model.measure = { url, _, _ in (sizes[url.lastPathComponent] ?? 0, [:]) }
        model.readDisks = {
            [OverviewModel.Disk(url: URL(fileURLWithPath: "/"),
                                volume: .init(name: "Macintosh HD", total: 494_000_000_000, available: 182_000_000_000,
                                              purgeable: 14_600_000_000)),
             OverviewModel.Disk(url: URL(fileURLWithPath: "/Volumes"),
                                volume: .init(name: "Backup Drive", total: 1_000_000_000_000, available: 62_000_000_000))]
        }
        // The firewall off shows its reminder; SIP unknown is grey.
        let security = SecurityStatus(gatekeeper: .on, firewall: .off, sip: .unknown, fileVault: .on,
                                      xprotect: .init(version: "5368", date: Self.today.addingTimeInterval(-3 * 86_400)))
        model.readSecurity = { security }
        let snapshots = LocalSnapshots(count: 4, oldest: Self.today.addingTimeInterval(-86_400),
                                       newest: Self.today.addingTimeInterval(-3_600))
        model.readSnapshots = { snapshots }
        model.introduced = Set(OverviewModel.Intro.allCases) // still, final values: no count-up or growing bars
        model.refresh()
        while model.measuring || model.security == nil || model.snapshots == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await snapshot("overview") { OverviewView(model: model) }
        // Tall enough for the whole form, from "Space outside your folders" down to "System protection" at the bottom.
        try await snapshot("overview-protection", size: CGSize(width: Self.detailSize.width, height: 1_900)) {
            OverviewView(model: model)
        }
    }

    /// The Uninstaller's result alert does not render offscreen (the window only dims), so the locked-app texts
    /// are drawn as plain text at about NSAlert's text width.
    @Test func uninstallerLockedAlert() async throws {
        let app = InstalledApp(url: URL(fileURLWithPath: "/Applications/Sample.app"), name: "Sample", bundleID: "com.example.sample",
                               version: "1.2", lastUsed: Self.today)
        try await snapshot("uninstaller-locked-alert", size: CGSize(width: 300, height: 200)) {
            VStack(spacing: 8) {
                Text("Couldn’t move \(app.name) to the Trash").font(.headline)
                Text("It is locked in Finder. Select it, choose File > Get Info, turn off Locked, then try again. Nothing was moved.")
                // Same joined message as UninstallerView for a removal with locked items; the view's String(localized:)
                // follows the process language, so the locale is passed here for the VI shot.
                let locale = Locale(identifier: Self.language)
                Text(verbatim: [String(localized: LocalizedStringResource("Empty the Trash to free the space.", locale: locale)),
                                String(localized: LocalizedStringResource("Locked in Finder (turn off Locked in Get Info): \(2)", locale: locale))]
                    .joined(separator: " "))
            }.multilineTextAlignment(.center).frame(width: 240).padding()
        }
    }

    @Test func loginItems() async throws {
        let agents = [
            LaunchAgent(url: Self.sample.appending(path: "LaunchAgents/com.example.updater.plist"), label: "com.example.updater",
                        scope: .user, program: "/Applications/Example.app/Contents/MacOS/updater", programMissing: false,
                        owner: URL(fileURLWithPath: "/System/Applications/Calculator.app"), state: .running(pid: 812)),
            LaunchAgent(url: Self.sample.appending(path: "LaunchAgents/com.old.helper.plist"), label: "com.old.helper",
                        scope: .user, program: "/Applications/Old.app/helper", programMissing: true, owner: nil, state: .notLoaded),
            LaunchAgent(url: Self.sample.appending(path: "LaunchAgents/com.example.sync.plist"), label: "com.example.sync",
                        scope: .user, program: "/usr/local/bin/sync", programMissing: false, owner: nil, state: .disabled),
            LaunchAgent(url: URL(fileURLWithPath: "/Library/LaunchAgents/com.vendor.agent.plist"), label: "com.vendor.agent",
                        scope: .systemAgent, program: "/Library/Vendor/agent", programMissing: false, owner: nil, state: .loaded),
            LaunchAgent(url: URL(fileURLWithPath: "/Library/LaunchDaemons/com.vendor.daemon.plist"), label: "com.vendor.daemon",
                        scope: .systemDaemon, program: "/Library/Vendor/daemon", programMissing: false, owner: nil, state: .unknown),
        ]
        try await snapshot("loginitems-results") {
            let model = LaunchAgentsModel()
            model.scan = { agents }
            return LaunchAgentsView(model: model)
        }
        try await snapshot("loginitems-empty") {
            let model = LaunchAgentsModel()
            model.scan = { [] }
            return LaunchAgentsView(model: model)
        }
    }

    @Test func maintenance() async throws {
        try await snapshot("maintenance-idle") { MaintenanceView(model: MaintenanceModel()) }
        let model = MaintenanceModel()
        model.now = { Self.today }
        model.record = { _, _ in }
        model.runCommand = { command in
            switch command.arguments {
            case ["-r"]: .init(succeeded: true, output: "qlmanage: resetting quicklookd\n")
            case ["Finder"]: .init(succeeded: false, output: "No matching processes belonging to you were found\n")
            default: .init(succeeded: true, output: "")
            }
        }
        for task in MaintenanceTask.allCases { await model.run(task) }
        model.readSnapshots = {
            LocalSnapshots.parse("com.apple.TimeMachine.2026-10-29-080000.local\ncom.apple.TimeMachine.2026-10-30-101112.local")
        }
        await model.loadSnapshots()
        try await snapshot("maintenance-results") { MaintenanceView(model: model) }
    }

    /// General tab only (the default one); it shows this Mac's real settings, nothing is scanned.
    @Test func settings() async throws {
        try await snapshot("settings", size: CGSize(width: 520, height: 590)) { SettingsView() }
    }

    /// Settings › Smart Scan tab alone; shows this Mac's real choices.
    @Test func settingsSmartScan() async throws {
        try await snapshot("settings-smartscan", size: CGSize(width: 520, height: 590)) { SmartScanSettings() }
    }

    /// Settings › Activity tab alone, from a sample log in a temporary home (not this Mac's log).
    @Test func settingsActivity() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "CleanMateSnapshotsHome-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let day: Double = 86_400
        ActivityLog.record(module: "Smart Scan", item: ActivityLog.english("User caches"), count: 214, size: 1_240_000_000,
                           mode: .delete, home: home, date: Self.today - 3 * day)
        ActivityLog.record(module: "Smart Scan", item: ActivityLog.english("\("Chrome"): cache & logs"), count: 37,
                           size: 386_000_000, mode: .delete, home: home, date: Self.today - 3 * day)
        ActivityLog.record(module: "Large & Old Files", item: "/Users/Shared/Sample/Movies/Trip 2019.mov", size: 4_300_000_000,
                           mode: .trash, home: home, date: Self.today - 2 * day)
        ActivityLog.record(module: "Uninstaller", item: "/Applications/Sample.app", size: 512_000_000, mode: .trash,
                           home: home, date: Self.today - day)
        ActivityLog.recordRestored(module: "Uninstaller", item: "/Applications/Sample.app", size: 512_000_000, home: home,
                                   date: Self.today - day + 60)
        // Old 6-column line: size text as written, no raw bytes.
        let old = "2025-12-20T10:00:00Z\tSmart Scan\tTrash\t12\t88 MB\tdeleted\n"
        let url = ActivityLog.url(home: home)
        let text = ActivityLog.read(home: home)
        try (old + text).write(to: url, atomically: true, encoding: .utf8)
        try await snapshot("settings-activity", size: CGSize(width: 520, height: 590)) { ActivitySettings(home: home, now: Self.today) }
    }
}
