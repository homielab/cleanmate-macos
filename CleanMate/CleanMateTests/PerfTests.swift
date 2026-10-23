import AppKit
import Darwin
import SwiftUI
import Testing
@testable import CleanMate

/// Speed and memory of the models and views with large made-up data. Skipped unless `CLEANMATE_PERF=1`:
///   TEST_RUNNER_CLEANMATE_PERF=1 xcodebuild … test -only-testing:CleanMateTests/PerfTests
/// Prints `PERF <what> <ms per access | ms total> <MB>` lines; nothing is scanned or cleaned, Space Lens only measures a
/// temporary folder of empty subfolders it creates and removes. A frame is ~16 ms: a property the view reads on every
/// render should stay well under it. Expectations are loose (10× the measured numbers) so only regressions fail.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CLEANMATE_PERF"] == "1"))
struct PerfTests {
    static let sample = URL(fileURLWithPath: "/Users/Shared/Sample")

    /// Physical footprint of the test process (what Activity Monitor shows as Memory), in MB.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1e6 : 0
    }

    /// Average milliseconds of `work` over `runs` runs.
    @discardableResult
    func timed(_ label: String, runs: Int = 20, _ work: () -> Void) -> Double {
        let start = ContinuousClock.now
        for _ in 0..<runs { work() }
        let ms = (ContinuousClock.now - start) / .milliseconds(1) / Double(runs)
        print("PERF " + label.padding(toLength: 44, withPad: " ", startingAt: 0) + String(format: "%9.3f ms", ms))
        return ms
    }

    /// Lays out `view` once in an offscreen window (like UISnapshots) and returns the milliseconds it took.
    func render(_ label: String, _ view: some View) -> Double {
        let start = ContinuousClock.now
        let host = NSHostingView(rootView: view.frame(width: 720, height: 600))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.display()
        let ms = (ContinuousClock.now - start) / .milliseconds(1)
        window.close()
        print("PERF " + label.padding(toLength: 44, withPad: " ", startingAt: 0) + String(format: "%9.3f ms", ms))
        return ms
    }

    /// Smart Scan's real catalog with 50k entries spread over its items (the real machine had ~11k).
    @Test func smartScan() {
        let before = Self.footprintMB()
        // The real catalog, not as this Mac's Full Disk Access, Settings › ages or Scan Groups shape it.
        let model = SmartScanModel(module: .smartScan) { CleanerGroup.smartScan(ages: .default, hasFullDiskAccess: true) }
        model.runningApps = []
        model.runningProcesses = []
        let items = model.groups.flatMap(\.items)
        let perItem = 50_000 / items.count
        for (index, item) in items.enumerated() {
            model.scans[item.id] = ItemScan(entries: (0..<perItem).map {
                ScanEntry(url: Self.sample.appending(path: "\(item.id)/\($0)"), size: Int64($0 % 900 + 1) * 4_096)
            })
            if index % 2 == 0 { model.selected.insert(item.id) }
        }
        model.phase = .results
        print("PERF " + "smartScan memory (50k entries)".padding(toLength: 44, withPad: " ", startingAt: 0)
              + String(format: "%9.1f MB", Self.footprintMB() - before))
        #expect(timed("smartScan visibleGroups") { _ = model.visibleGroups } < 50)
        #expect(timed("smartScan selectedSize + upTo") { _ = model.selectedSize + model.selectedUpToSize } < 50)
        #expect(timed("smartScan hasSelection") { _ = model.hasSelection } < 50)
        #expect(render("smartScan view render", SmartScanView(model: model, module: .smartScan)) < 2_000)
        #expect(render("smartScan view render again", SmartScanView(model: model, module: .smartScan)) < 2_000) // icons cached
    }

    /// 5k and 50k large files: the table's sort, the sidebar's per-kind totals and the selected total.
    @Test(arguments: [5_000, 50_000])
    func largeFiles(count: Int) {
        let before = Self.footprintMB()
        let model = LargeFilesModel()
        let kinds = FileKind.allCases
        model.files = (0..<count).map {
            LargeFile(url: Self.sample.appending(path: "folder\($0 % 97)/file\($0).bin"), size: Int64($0 % 5_000 + 50) * 1_000_000,
                      lastUsed: .now.addingTimeInterval(-Double($0 % 1_000) * 86_400), kind: kinds[$0 % kinds.count])
        }.sorted { $0.size > $1.size }
        model.checked = Set(model.files.prefix(count / 2).map(\.url))
        model.phase = .results
        print("PERF " + "largeFiles memory (\(count) files)".padding(toLength: 44, withPad: " ", startingAt: 0)
              + String(format: "%9.1f MB", Self.footprintMB() - before))
        let sortOrder = [KeyPathComparator(\LargeFile.size, order: .reverse)]
        #expect(timed("largeFiles \(count) visibleFiles sorted") { _ = model.visibleFiles.sorted(using: sortOrder) } < 500)
        let byName = [KeyPathComparator(\LargeFile.name)]
        #expect(timed("largeFiles \(count) sorted by name (old)", runs: 5) { _ = model.visibleFiles.sorted(using: byName) } < 2_000)
        // First sort after a scan builds the ranks; later sorts (filter, search) reuse them.
        #expect(timed("largeFiles \(count) name ranks + first sort", runs: 1) {
            model.files = model.files
            _ = model.sorted(model.visibleFiles, using: byName)
        } < 1_000)
        #expect(timed("largeFiles \(count) sorted by name", runs: 5) { _ = model.sorted(model.visibleFiles, using: byName) } < 200)
        let byLocation = [KeyPathComparator(\LargeFile.location, order: .reverse)]
        #expect(timed("largeFiles \(count) sorted by location", runs: 5) { _ = model.sorted(model.visibleFiles, using: byLocation) } < 200)
        #expect(timed("largeFiles \(count) sidebar kind totals") {
            for kind in kinds { _ = model.files(of: kind).reduce(0) { $0 + $1.size } }
        } < 500)
        model.search = "folder4" // search + kind picker totals per keystroke
        #expect(timed("largeFiles \(count) search + kind totals") {
            _ = model.visibleFiles.count
            for kind in kinds { _ = model.files(of: kind).reduce(0) { $0 + $1.size } }
        } < 1_000)
        model.search = ""
        #expect(timed("largeFiles \(count) checkedFiles + size") { _ = (model.checkedFiles.count, model.checkedSize) } < 500)
        #expect(render("largeFiles \(count) view render", LargeFilesView(model: model)) < 5_000)
        // Duplicates filter: every 10th file has a copy; filter + regroup per render.
        model.duplicateGroups = stride(from: 0, to: count - 1, by: 10).map { [model.files[$0].url, model.files[$0 + 1].url] }
        model.duplicatesOnly = true
        #expect(timed("largeFiles \(count) duplicates filter + grouped") {
            _ = model.groupedByDuplicates(model.sorted(model.visibleFiles, using: byName))
        } < 2_000)
        model.duplicatesOnly = false
    }

    /// Finding duplicates on real temporary files: 40 files of ~8 MB, 10 of one size (5 identical pairs), the
    /// rest of distinct sizes, so only the 10 are read. The second run answers from the cache.
    @Test func duplicateHashing() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CleanMatePerfDup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let size = 8_000_000
        var urls: [URL] = []
        for i in 0..<40 {
            let url = root.appending(path: "f\(i).bin")
            var data = Data(repeating: i < 10 ? 0 : UInt8(i), count: i < 10 ? size : size + i)
            if i < 10 { data[0] = UInt8(i / 2) } // pairs (0,1), (2,3)… share content
            try data.write(to: url)
            urls.append(url)
        }
        let start = ContinuousClock.now
        let first = try await DuplicateFinder.find(urls)
        let ms = (ContinuousClock.now - start) / .milliseconds(1)
        print("PERF " + "duplicates 40×8 MB, 10 same size".padding(toLength: 44, withPad: " ", startingAt: 0)
              + String(format: "%9.3f ms", ms) + " (hashed \(first.hashedCount))")
        #expect(first.hashedCount == 10 && first.groups.count == 5)
        #expect(ms < 5_000)
        let again = ContinuousClock.now
        let cached = try await DuplicateFinder.find(urls, cache: first.hashes)
        let cachedMs = (ContinuousClock.now - again) / .milliseconds(1)
        print("PERF " + "duplicates again (cached)".padding(toLength: 44, withPad: " ", startingAt: 0) + String(format: "%9.3f ms", cachedMs))
        #expect(cached.hashedCount == 0 && cached.groups == first.groups)
    }

    /// One app with ~2k data items (icon + SizeBar per row, bar max computed once per list).
    @Test func uninstallerEntries() {
        let app = InstalledApp(url: URL(fileURLWithPath: "/System/Applications/Calculator.app"), name: "Calculator",
                               bundleID: "com.example.calculator", version: "1.0", lastUsed: nil)
        let library = Self.sample.appending(path: "Library")
        let data = (0..<2_000).map {
            AppDataEntry(url: library.appending(path: "Caches/com.example.calculator/item\($0)"), size: Int64($0 % 900 + 1) * 4_096)
        }
        let model = UninstallerModel()
        model.appData = { _, _, _ in data }
        model.apps = [app]
        model.appSizes = [app.url: 45_000_000]
        model.hiddenItems = [] // never scans the real home
        model.extensionItems = []
        model.selection = .app(app.url)
        model.entries = data
        model.checked = Set(data.map(\.url))
        #expect(timed("uninstaller 2000 entries checkedSize") { _ = model.checkedSize } < 50)
        #expect(timed("uninstaller row icon lookup x30", runs: 5) {
            for entry in data.prefix(30) { _ = NSWorkspace.shared.icon(forFile: entry.url.path) }
        } < 500)
        #expect(render("uninstaller 2000 entries view render", UninstallerView(model: model)) < 5_000)
    }

    /// ~500 launch agents, each row with its owner's icon.
    @Test func loginItems() async {
        let agents = (0..<500).map {
            LaunchAgent(url: Self.sample.appending(path: "LaunchAgents/com.example.agent\($0).plist"), label: "com.example.agent\($0)",
                        scope: [.user, .systemAgent, .systemDaemon][$0 % 3], program: "/Applications/Example.app/agent\($0)",
                        programMissing: $0 % 7 == 0, owner: $0 % 2 == 0 ? URL(fileURLWithPath: "/System/Applications/Calculator.app") : nil,
                        state: .loaded)
        }
        let model = LaunchAgentsModel()
        model.scan = { agents }
        await model.load()
        #expect(render("loginItems 500 agents view render", LaunchAgentsView(model: model)) < 5_000)
    }

    /// A folder with 3k subfolders: listing + measuring every child, until `measuring` ends.
    @Test func spaceLens() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "CleanMatePerf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        for index in 0..<3_000 {
            try FileManager.default.createDirectory(at: folder.appending(path: "d\(index)"), withIntermediateDirectories: true)
        }
        let model = SpaceLensModel()
        model.hasFullDiskAccess = { true }
        let start = ContinuousClock.now
        model.start(at: folder)
        while model.measuring { try await Task.sleep(for: .milliseconds(5)) }
        let ms = (ContinuousClock.now - start) / .milliseconds(1)
        print("PERF " + "spaceLens 3000 subfolders measured".padding(toLength: 44, withPad: " ", startingAt: 0) + String(format: "%9.3f ms", ms))
        #expect(model.items.count == 3_000)
        #expect(model.items.allSatisfy { $0.size != nil })
        let sortOrder = [KeyPathComparator(\SpaceItem.sortSize, order: .reverse)]
        timed("spaceLens 3000 items sorted") { _ = model.items.sorted(using: sortOrder) }
        // ⌘A: the view checks the policy once per selection change, not per item per render.
        let all = Set(model.items.map(\.url))
        let policy = SafetyPolicy(home: folder.deletingLastPathComponent().deletingLastPathComponent(), temp: URL(fileURLWithPath: "/nonexistent"))
        #expect(policy.allowedSpaceLensItems(all).count == 3_000)
        #expect(timed("spaceLens ⌘A 3000 items policy check", runs: 5) { _ = policy.allowedSpaceLensItems(all) } < 2_000)
        #expect(render("spaceLens 3000 items view render", SpaceLensView(model: model)) < 5_000)
    }
}
