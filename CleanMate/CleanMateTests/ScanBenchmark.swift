import AppKit
import Darwin
import Foundation
import Testing
@testable import CleanMate

/// Read-only speed benchmark on the REAL home folder. Skipped unless `CLEANMATE_BENCH=1` reaches the test runner:
///   TEST_RUNNER_CLEANMATE_BENCH=1 xcodebuild … test -only-testing:CleanMateTests/ScanBenchmark
/// (xcodebuild passes `TEST_RUNNER_X` to the test process as `X`). `CLEANMATE_BENCH_ROOT=<folder>` makes Large Files and
/// Space Lens start there instead of the home folder. Without Full Disk Access for the test host, a root or ~/Library
/// folder that is (inside) a `ProtectedFolders` folder is not read — `BENCH skipped <name> (cần Full Disk Access)` —
/// so the bench never raises a macOS access dialog; protected children of the home are skipped like the app does.
/// It only calls the scanners (`Scanner.scan`, `LargeFileScanner.scan`, `SpaceLens.list/measure`) — never `Cleaner.clean`,
/// trash or erase. The only commands a scan runs are size probes (`xcrun simctl list`, `docker system df`) and
/// `sqlite3` record counts; item `command`s (the cleaning tools) are never run by a scan.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CLEANMATE_BENCH"] == "1"))
struct ScanBenchmark {
    let policy = SafetyPolicy.current
    var root: URL { ProcessInfo.processInfo.environment["CLEANMATE_BENCH_ROOT"].map(URL.init(fileURLWithPath:)) ?? policy.homeURL }

    func report(_ label: String, _ seconds: Double, _ bytes: Int64) {
        print("BENCH " + label.padding(toLength: 36, withPad: " ", startingAt: 0)
              + String(format: "%8.2fs %10.1f MB", seconds, Double(bytes) / 1e6))
    }

    func timed<T>(_ work: () async throws -> T) async rethrows -> (T, Double) {
        let start = ContinuousClock.now
        let value = try await work()
        let elapsed = ContinuousClock.now - start
        return (value, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    }

    /// Peak memory while `work` runs: `phys_footprint` (Activity Monitor's "Memory") sampled every 2 ms,
    /// printed as `BENCH memory <label> peak … MB (start … MB)`. A per-test sample, not the process-lifetime peak.
    func peakMemory<T>(_ label: String, _ work: () async throws -> T) async rethrows -> T {
        func footprint() -> UInt64 {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
            }
            return result == KERN_SUCCESS ? info.phys_footprint : 0
        }
        let start = footprint(), peak = Locked(start)
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .milliseconds(2))
        timer.setEventHandler { let now = footprint(); peak.withLock { $0 = max($0, now) } }
        timer.resume()
        defer {
            timer.cancel()
            let top = peak.withLock { max($0, footprint()) }
            print(String(format: "BENCH memory %@ peak %.0f MB (start %.0f MB)", label, Double(top) / 1e6, Double(start) / 1e6))
        }
        return try await work()
    }

    /// Each item alone (to find the slow ones), then all in parallel like `SmartScanModel`.
    /// Every entry each item would clean is also written to `$TMPDIR/cleanmate-entries-<name>.tsv` (for a safety
    /// review; never in the repo): item, mode, selected by default, bytes, records, entry label and its date
    /// (empty when the item has no `entryLabel`), path. A probe-measured item has one row with an empty path.
    func scanItems(_ name: String, _ groups: [CleanerGroup]) async {
        let items = groups.flatMap(\.items)
        var tsv = "item\tmode\tselected\tbytes\trecords\ttitle\tdate\tpath\n"
        for item in items {
            let (scan, seconds) = await timed { await Scanner.scan(item, policy: policy) }
            report("\(name)/\(item.id)", seconds, scan.size)
            let rows = scan.entries.map { ($0.size, $0.records, $0.title ?? "", $0.date.map { $0.formatted(.iso8601) } ?? "", $0.url.path) }
                + (scan.measuredSize.map { [($0, nil, "", "", "")] } ?? [])
            for (bytes, records, title, date, path) in rows {
                tsv += "\(item.id)\t\(item.mode)\t\(item.selectedByDefault)\t\(bytes)\t\(records.map(String.init) ?? "")\t\(title)\t\(date)\t\(path)\n"
            }
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cleanmate-entries-\(name).tsv")
        do { try tsv.write(to: file, atomically: true, encoding: .utf8); print("BENCH entries -> \(file.path)") }
        catch { print("BENCH entries NOT written: \(error)") }
        // Also when each item finished inside the parallel run: the last ones are the scan's critical path.
        let start = ContinuousClock.now
        let (finished, seconds) = await timed { await peakMemory("\(name) parallel") {
            await withTaskGroup(of: (String, Int64, Duration).self) { group in
                for item in items {
                    group.addTask { (item.id, await Scanner.scan(item, policy: policy).size, start.duration(to: .now)) }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
        } }
        for (id, _, at) in finished.sorted(by: { $0.2 > $1.2 }).prefix(8) {
            report("\(name) parallel done \(id)", at / .seconds(1), 0)
        }
        report("\(name) TOTAL (parallel)", seconds, finished.reduce(0) { $0 + $1.1 })
    }

    @Test func smartScan() async {
        print("BENCH home = \(policy.homeURL.path), root = \(root.path)")
        let (open, seconds) = await timed { RunningProcesses.openPaths() }
        report("open files in $TMPDIR (\(open.count))", seconds, 0)
        let (cached, cachesSeconds) = await timed { RunningProcesses.openPaths(under: policy.expand("~/Library/Caches").path) }
        report("open files in Caches (\(cached.count))", cachesSeconds, 0)
        await scanItems("smart", CleanerGroup.smartScan)
    }

    /// Stale node_modules as if every project were stale (a clock 10 years ahead, no node running): finding and
    /// measuring all of them alone, then a whole Smart Scan with that item instead of the real one — the cost on a
    /// machine full of old projects. Only scans, like the rest of this suite.
    @Test func staleNodeModulesWorstCase() async {
        let later: @Sendable () -> Date = { .now.addingTimeInterval(3650 * 86_400) }
        let all = [StaleNodeModules.item(running: { [] }, now: later), StaleBuildFolders.item(running: { [] }, now: later)]
        for item in all {
            let (scan, seconds) = await timed { await Scanner.scan(item, policy: policy) }
            report("\(item.id) all (\(scan.entries.count))", seconds, scan.size)
        }
        await scanItems("smart-all-stale", CleanerGroup.smartScan.map { group in
            CleanerGroup(id: group.id, title: group.title, systemImage: group.systemImage,
                         items: group.items.map { item in all.first { $0.id == item.id } ?? item })
        })
    }

    /// What the build folders item adds to a scan: node_modules alone, then both items at once as in Smart Scan
    /// (they share one walk), alternated `runs` times (`CLEANMATE_BENCH_RUNS`, 5 by default); medians.
    @Test func staleBuildFoldersCost() async {
        let runs = ProcessInfo.processInfo.environment["CLEANMATE_BENCH_RUNS"].flatMap(Int.init) ?? 5
        var alone: [Double] = [], both: [Double] = []
        for _ in 0..<runs {
            try? await Task.sleep(for: StaleProjects.reuseTime) // no walk reused from the previous run
            alone.append(await timed { await Scanner.scan(StaleNodeModules.item(), policy: policy) }.1)
            try? await Task.sleep(for: StaleProjects.reuseTime)
            both.append(await timed {
                async let modules = Scanner.scan(StaleNodeModules.item(), policy: policy)
                async let builds = Scanner.scan(StaleBuildFolders.item(), policy: policy)
                return await (modules.size, builds.size)
            }.1)
        }
        report("stale node_modules alone (median)", alone.sorted()[runs / 2], 0)
        report("stale node_modules + build (median)", both.sorted()[runs / 2], 0)
    }

    /// Entry label review: every real DerivedData / DeviceSupport folder and every `~/.claude/projects` folder,
    /// whatever its age, labelled like the scan does and checked against the source: DerivedData title = project name
    /// (+ `info.plist` WorkspacePath when there is one), DeviceSupport title has a version, a Claude Code path exists
    /// and encodes back to the folder name. Prints counts only (no private paths). Only reads.
    @Test func entryLabels() async {
        let fm = FileManager.default
        func children(_ path: String) -> [URL] {
            ((try? fm.contentsOfDirectory(atPath: policy.expand(path).path)) ?? []).filter { !$0.hasPrefix(".") }
                .map { policy.expand(path).appending(path: $0) }
        }
        var counts: [String: (total: Int, ok: Int, empty: Int)] = [:]
        func check(_ kind: String, _ urls: [URL], _ label: (URL) -> (title: String, date: Date?)?, _ isRight: (URL, String) -> Bool) {
            let (result, seconds) = { () -> ([(URL, String?)], Double) in
                let start = ContinuousClock.now
                let labels = urls.map { ($0, label($0)?.title) }
                let d = ContinuousClock.now - start
                return (labels, Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
            }()
            for (url, title) in result {
                let trimmed = title?.trimmingCharacters(in: .whitespaces) ?? ""
                counts[kind, default: (0, 0, 0)].total += 1
                if trimmed.isEmpty { counts[kind]!.empty += 1 } else if isRight(url, trimmed) { counts[kind]!.ok += 1 }
            }
            let c = counts[kind] ?? (0, 0, 0)
            print("BENCH labels \(kind): total=\(c.total) right=\(c.ok) empty=\(c.empty) wrong=\(c.total - c.ok - c.empty)"
                  + String(format: " %.3fs", seconds))
        }
        check("derived-data", children("~/Library/Developer/Xcode/DerivedData"), XcodeData.derivedDataLabel(of:)) { url, title in
            guard let project = XcodeData.projectName(fileName: url.lastPathComponent) else { return title.hasSuffix("shared by all projects") }
            let info = (try? Data(contentsOf: url.appending(path: "info.plist")))
                .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
            guard let workspace = info?["WorkspacePath"] as? String else { return title == project }
            return title == project + " · " + (workspace as NSString).abbreviatingWithTildeInPath
                && (workspace.hasSuffix("/" + project + ".xcodeproj") || workspace.hasSuffix("/" + project + ".xcworkspace"))
        }
        let support = children("~/Library/Developer/Xcode").filter { $0.lastPathComponent.hasSuffix("DeviceSupport") }.flatMap { children($0.path) }
        check("device-support", support, XcodeData.deviceSupportLabel(of:)) { url, title in
            title.contains(" (") && url.lastPathComponent.contains(title.split(separator: " ").dropFirst().joined(separator: " "))
        }
        // One session file per project folder is enough: the label depends on the folder only.
        let sessions = children("~/.claude/projects").compactMap { children($0.path).first }
        check("claude-code", sessions, AISessions.claudeLabel(of:)) { url, title in
            // The folder name itself is the documented fallback when the project folder no longer exists.
            if title == url.deletingLastPathComponent().lastPathComponent { return true }
            let path = (title as NSString).expandingTildeInPath
            return fm.fileExists(atPath: path) && AISessions.claudeFolderName(path) == url.deletingLastPathComponent().lastPathComponent
        }
    }

    @Test func privacy() async {
        await scanItems("privacy", CleanerGroup.privacy)
    }

    /// Like the app: without Full Disk Access the TCC-protected folders are not entered (no access dialogs).
    var skipping: Set<String> { ProtectedFolders.skipped(home: policy.homeURL, hasFullDiskAccess: FullDiskAccess.isGranted) }

    /// Pure decision: may the bench list `folder`? Not when it is, or is inside, a protected folder and Full
    /// Disk Access is missing — listing it would raise a macOS access dialog.
    static func mayRead(_ folder: URL, home: URL, hasFullDiskAccess: Bool) -> Bool {
        !ProtectedFolders.contains(ProtectedFolders.skipped(home: home, hasFullDiskAccess: hasFullDiskAccess), folder)
    }

    /// `mayRead` with the real Full Disk Access state; prints why a folder is skipped.
    func mayRead(_ name: String, _ folder: URL) -> Bool {
        if Self.mayRead(folder, home: policy.homeURL, hasFullDiskAccess: FullDiskAccess.isGranted) { return true }
        print("BENCH skipped \(name) (cần Full Disk Access)")
        return false
    }

    /// `CLEANMATE_BENCH_MINSIZE=<bytes>` (default 50 MB) scans at another threshold (1 MB in a folder); the scan
    /// is timed again without Spotlight to show what its last-used lookups cost.
    @Test func largeFiles() async throws {
        guard mayRead("large-files \(root.path)", root) else { return }
        let skipping = skipping
        let minSize = ProcessInfo.processInfo.environment["CLEANMATE_BENCH_MINSIZE"].flatMap(Int64.init) ?? 50_000_000
        let (files, seconds) = try await timed { try await peakMemory("large-files") {
            try await LargeFileScanner.scan(root: root, minSize: minSize, policy: policy, skipping: skipping)
        } }
        report("large-files ≥\(minSize / 1_000_000)MB (\(files.count) files)", seconds, files.reduce(0) { $0 + $1.size })
        let (_, plain) = try await timed {
            try await LargeFileScanner.scan(root: root, minSize: minSize, policy: policy, skipping: skipping, spotlightLastUsed: { _ in nil })
        }
        report("large-files no Spotlight", plain, 0)
        // Duplicates: reads same-size files to hash them, nothing else. Clones = files counted once.
        let urls = files.map(\.url)
        let (found, hashing) = try await timed { try await peakMemory("dupes") { try await DuplicateFinder.find(urls) } }
        let clones = Dictionary(grouping: urls.compactMap(DuplicateFinder.cloneID), by: { $0 }).values.reduce(0) { $0 + $1.count - 1 }
        let extra = found.groups.reduce(Int64(0)) { sum, group in
            sum + Int64(group.count - 1) * (files.first { $0.url == group[0] }?.size ?? 0)
        }
        report("dupes \(found.groups.count)g \(found.hashedCount)read \(clones)clone", hashing, extra)
    }

    /// The home level as `SpaceLensModel` loads it: list, then every folder measured in parallel.
    @Test func spaceLensHome() async throws {
        guard mayRead("space-lens \(root.path)", root) else { return }
        let skipping = skipping
        let (total, seconds) = try await timed { try await peakMemory("space-lens") {
            let links = SpaceLens.HardLinks()
            let listed = await SpaceLens.list(root, links: links)
            return try await withThrowingTaskGroup(of: (Int64, [String: Int64]).self) { group in
                for item in listed {
                    group.addTask {
                        guard item.size == nil, !skipping.contains(item.url.standardizedFileURL.path) else { return (item.size ?? 0, [:]) }
                        let (result, seconds) = try await timed {
                            try await SpaceLens.measure(item.url, links: links, skipping: skipping)
                        }
                        if seconds > 1 { report("space-lens/\(item.name)", seconds, result.size) }
                        return result
                    }
                }
                return try await group.reduce(into: (Int64(0), [String: Int64]())) { $0.0 += $1.0; $0.1.merge($1.1) { a, _ in a } }
            }
        } }
        report("space-lens TOTAL (parallel)", seconds, total.0)
        // Exact numbers to compare runs: bytes, items listed, folders remembered for drilling in and their sum.
        print("BENCH space-lens exact bytes=\(total.0) folders=\(total.1.count) folderBytes=\(total.1.values.reduce(0, +))")
    }

    /// Uninstaller review: for EVERY app in the Uninstaller list, the ~/Library entries and config items in ~ and ~/.config
    /// it would list, written to `$TMPDIR/cleanmate-uninstall-matches.tsv` (never in the repo): app, bundle id, folder,
    /// entry, kind (data = ticked, suggested / config = listed unticked), reason. Same inputs as `UninstallerModel` (other
    /// bundle ids incl. Apple's and nested apps; other app names) but without running apps. Only lists folders — never
    /// sizes, trash or remove.
    @Test func uninstallerMatches() async {
        let apps = await Uninstaller.installedApps(policy: policy)
        for folder in SafetyPolicy.appDataFolders {
            _ = mayRead("uninstall Library/\(folder)", policy.homeURL.appending(path: "Library/\(folder)"))
        }
        let skipped = ProtectedFolders.skipped(home: policy.homeURL, hasFullDiskAccess: FullDiskAccess.isGranted)
        let all = Uninstaller.allBundleIDs(policy: policy).union(apps.map(\.bundleID))
        let matches = await Uninstaller.classifiedMatches(of: apps, otherBundleIDs: all, skipped: skipped,
                                                          allApps: Uninstaller.allAppURLs(policy: policy), policy: policy)
        var tsv = "app\tbundle_id\tfolder\tentry\tkind\treason\n", count = 0
        for app in apps {
            for (url, kind) in matches[app.url] ?? [] {
                let name = url.lastPathComponent, folder = url.deletingLastPathComponent().lastPathComponent
                let id = AppMatcher.identifier(name, in: folder)
                let reason = kind == .config ? "config" : kind == .suggested ? "prefix of name"
                    : id == app.bundleID.lowercased() ? "bundle id" : AppMatcher.belongs(id, to: app.bundleID) ? "prefix" : "name"
                tsv += "\(app.name)\t\(app.bundleID)\t\(folder)\t\(name)\t\(kind)\t\(reason)\n"
                count += 1
            }
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cleanmate-uninstall-matches.tsv")
        do { try tsv.write(to: file, atomically: true, encoding: .utf8); print("BENCH uninstall matches -> \(file.path)") }
        catch { print("BENCH uninstall matches NOT written: \(error)") }
        print("BENCH uninstall apps=\(apps.count) matches=\(count)")
    }

    /// Uninstaller list sizes, exactly as the app does it: app bundles, then every app's ~/Library data (one
    /// listing, each entry measured once). Without Full Disk Access Containers / Group Containers are not listed.
    /// Only reads — never trashes or removes.
    @MainActor @Test func uninstallerAppDataTotals() async {
        for folder in ["Containers", "Group Containers"] {
            _ = mayRead("app data Library/\(folder)", policy.homeURL.appending(path: "Library/\(folder)"))
        }
        // Phases alone, to see which one is slow.
        let (listed, listSeconds) = await timed { await Uninstaller.installedApps(policy: policy) }
        print(String(format: "BENCH uninstaller list (%d apps) %.3fs", listed.count, listSeconds))
        let ids = Uninstaller.allBundleIDs(policy: policy).union(listed.map(\.bundleID))
        let skipped = ProtectedFolders.skipped(home: policy.homeURL, hasFullDiskAccess: FullDiskAccess.isGranted)
        let (matched, matchSeconds) = await timed {
            await Uninstaller.dataMatches(of: listed, otherBundleIDs: ids, skipped: skipped,
                                          allApps: Uninstaller.allAppURLs(policy: policy), policy: policy)
        }
        print(String(format: "BENCH uninstaller matching (%d entries) %.3fs", matched.values.map(\.count).reduce(0, +), matchSeconds))
        let model = UninstallerModel()
        let (_, appSeconds) = await timed { await peakMemory("uninstaller app sizes") { await model.loadApps() } }
        report("uninstaller app sizes (\(model.apps.count) apps)", appSeconds, model.appSizes.values.reduce(0, +))
        let (_, dataSeconds) = await timed { await peakMemory("uninstaller app data") { await model.measureAppData() } }
        report("uninstaller app data (\(model.appDataSizes.count) apps)", dataSeconds, model.appDataSizes.values.reduce(0, +))
        let (_, againSeconds) = await timed { await model.measureAppData() }
        print(String(format: "BENCH uninstaller app data again (cached) %.3fs", againSeconds))
        for app in UninstallerModel.sorted(model.apps, by: .size, sizes: model.totalSizes).prefix(5) {
            print("BENCH top \(app.name): app \(model.appSizes[app.url] ?? 0) data \(model.appDataSizes[app.url] ?? 0)")
        }
    }

    /// Leftovers review: every ~/Library entry "Leftovers of removed apps" would list, with the same inputs as
    /// `UninstallerModel` (all bundle ids + running apps, CLI tools, LaunchServices), written to
    /// `$TMPDIR/cleanmate-leftovers.tsv`: verdict (LEFTOVER or why kept), folder, entry, vendor. Only lists names — never sizes, trash or remove.
    @Test func uninstallerLeftovers() async {
        let installed = Uninstaller.allBundleIDs(policy: policy).union(SmartScanModel.currentRunningApps())
        let tools = Uninstaller.commandLineTools(home: policy.homeURL, folders: Uninstaller.userToolFolders)
        let agents = policy.homeURL.appending(path: "Library/LaunchAgents")
        let registered: (String) -> Bool = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        var tsv = "verdict\tfolder\tentry\tvendor\n", count = 0
        for folder in SafetyPolicy.appDataFolders {
            let dir = policy.homeURL.appending(path: "Library/\(folder)")
            guard mayRead("leftovers Library/\(folder)", dir) else { continue }
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            where policy.allowsAppData(dir.appending(path: name)) && !SafetyPolicy.isApple(name) {
                let id = AppMatcher.identifier(name, in: folder), vendor = AppMatcher.vendor(id)
                guard AppMatcher.isBundleIDShaped(id) else { continue }
                // Why an entry is kept (not a leftover), checked in `isLeftover`'s order; "LEFTOVER" is what the app lists.
                let verdict = tools.contains(String(id.split(separator: ".").last!)) ? "tool"
                    : AppMatcher.sharedVendors.contains(vendor) ? "shared vendor"
                    : installed.contains { AppMatcher.vendor($0) == vendor } ? "vendor installed"
                    : registered(id) ? "registered"
                    : folder == "LaunchAgents" && Uninstaller.agentIsActive(agents.appending(path: name)) ? "agent active"
                    : "LEFTOVER"
                tsv += "\(verdict)\t\(folder)\t\(name)\t\(vendor)\n"
                if verdict == "LEFTOVER" { count += 1 }
            }
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cleanmate-leftovers.tsv")
        do { try tsv.write(to: file, atomically: true, encoding: .utf8); print("BENCH leftovers -> \(file.path)") }
        catch { print("BENCH leftovers NOT written: \(error)") }
        print("BENCH leftovers installed=\(installed.count) tools=\(tools.count) entries=\(count)")
    }

    /// Login items review: every non-Apple plist the Login Items screen lists, with what the app shows (label,
    /// program, owner, state, missing) and the raw plist fields to check it against (ProgramArguments,
    /// AssociatedBundleIdentifiers), written to `$TMPDIR/cleanmate-launch-agents.tsv`. Only reads `launchctl list` /
    /// `print-disabled` like the app — never bootout, disable, enable or trash.
    @Test func launchAgents() async {
        let agents = await LaunchAgents.scan(appForID: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }, policy: policy)
        var tsv = "scope\tlabel\tprogram\towner\tstate\tmissing\targuments\tassociated\n"
        for agent in agents {
            let dict = LaunchAgents.read(agent.url) ?? [:]
            let args = (dict["ProgramArguments"] as? [String])?.joined(separator: " ") ?? ""
            let clean = { (s: String) in s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
            tsv += "\(agent.scope)\t\(agent.label)\t\(agent.program ?? "")\t\(agent.owner?.path ?? "")\t\(agent.state)\t"
                + "\(agent.programMissing)\t\(clean(args))\t\(LaunchAgents.associatedIDs(dict).joined(separator: ","))\n"
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cleanmate-launch-agents.tsv")
        do { try tsv.write(to: file, atomically: true, encoding: .utf8); print("BENCH launch agents -> \(file.path)") }
        catch { print("BENCH launch agents NOT written: \(error)") }
        print("BENCH launch agents=\(agents.count) missing=\(agents.filter(\.programMissing).count) owned=\(agents.filter { $0.owner != nil }.count)")
    }

    /// Extensions review: lists ~/Library extensions like the Uninstaller (running apps included) and asks
    /// `allowsUserExtension` about each. Written to `$TMPDIR/cleanmate-extensions.tsv`: name, kind, bundle id, owner,
    /// appRemoved, trashable (checkbox), allowed. Only reads — never trash.
    @Test func extensions() async {
        let running = NSWorkspace.shared.runningApplications.compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
        let items = await Extensions.list(policy: policy, running: Dictionary(running) { first, _ in first })
        var tsv = "name\tkind\tbundleID\towner\tappRemoved\ttrashable\tallowed\n"
        for item in items {
            tsv += "\(item.url.lastPathComponent)\t\(item.kind)\t\(item.bundleID ?? "")\t\(item.owner ?? "")\t\(item.appRemoved)\t"
                + "\(item.trashable)\t\(policy.allowsUserExtension(item.url))\n"
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cleanmate-extensions.tsv")
        do { try tsv.write(to: file, atomically: true, encoding: .utf8); print("BENCH extensions -> \(file.path)") }
        catch { print("BENCH extensions NOT written: \(error)") }
        print("BENCH extensions=\(items.count) removed=\(items.filter(\.appRemoved).count) owned=\(items.filter { $0.owner != nil }.count)")
    }

    /// Space Lens / Large Files review: walks the real home (breadth-first, depth ≤ 4, ≤ 300 000 entries, never
    /// through a symlink or into another volume, nor into `skipping`) and asks `allowsSpaceLensItem` / `allowsUserFile`
    /// about every entry. Each entry gets a category from an independent check (first match): symlink, library, hidden,
    /// in-package, other-volume, excluded, top-folder, plain. Anything but plain must be refused (a plain folder is still
    /// refused by `allowsUserFile`). Written to `$TMPDIR/cleanmate-user-items.tsv`: category, kind, spaceLens, userFile,
    /// path. Only reads metadata — never trash or remove.
    @Test func userItemPolicy() {
        let fm = FileManager.default, home = policy.homeURL.standardizedFileURL, skipping = skipping
        // The user's exclusions plus one real second-level folder, so the excluded rule is checked on a real tree too.
        let visible = { (dir: URL) in ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
            .filter { $0.hasDirectoryPath && !skipping.contains($0.standardizedFileURL.path) }.sorted { $0.path < $1.path } }
        let picked = visible(home).filter { $0.lastPathComponent != "Library" }.lazy.compactMap { visible($0).first }.first
        let policy = SafetyPolicy(home: policy.homeURL, temp: policy.tempURL, excluded: policy.excluded + (picked.map { [$0.path] } ?? []))
        let excluded = policy.excluded.map { $0.lowercased() }
        let homeDevice = SafetyPolicy.deviceID(home.path)
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .isPackageKey]
        var tsv = "category\tkind\tspaceLens\tuserFile\tpath\n", counts: [String: [Int]] = [:], wrong = 0, seen = 0
        // (folder, depth of its children, a folder above is a package)
        var queue: [(URL, Int, Bool)] = [(home, 1, false)]
        while !queue.isEmpty, seen < 300_000 {
            let (dir, depth, inPackage) = queue.removeFirst()
            for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? [] where seen < 300_000 {
                seen += 1
                let values = try? url.resourceValues(forKeys: Set(keys))
                let link = values?.isSymbolicLink == true, isDir = !link && values?.isDirectory == true
                let rel = url.path.dropFirst(home.path.count + 1), parts = rel.split(separator: "/")
                let otherVolume = SafetyPolicy.deviceID(url.path).map { $0 != homeDevice } ?? false
                let isExcluded = excluded.contains { url.path.lowercased() == $0 || url.path.lowercased().hasPrefix($0 + "/") || $0.hasPrefix(url.path.lowercased() + "/") }
                let category = link ? "symlink" : parts.first?.lowercased() == "library" ? "library"
                    : parts.contains { $0.hasPrefix(".") } ? "hidden" : inPackage ? "in-package"
                    : otherVolume ? "other-volume" : isExcluded ? "excluded" : isDir && depth == 1 ? "top-folder" : "plain"
                let kind = link ? "link" : isDir ? (values?.isPackage == true ? "package" : "dir") : values?.isRegularFile == true ? "file" : "other"
                let sl = policy.allowsSpaceLensItem(url), uf = policy.allowsUserFile(url)
                if category != "plain" && (sl || uf) || uf && kind != "file" || (sl || uf) && kind == "other" { wrong += 1 }
                counts[category, default: [0, 0, 0]][0] += 1
                if sl { counts[category]![1] += 1 }
                if uf { counts[category]![2] += 1 }
                tsv += "\(category)\t\(kind)\t\(sl)\t\(uf)\t\(url.path)\n"
                if isDir, depth < 4, !otherVolume, !skipping.contains(url.standardizedFileURL.path) {
                    queue.append((url, depth + 1, inPackage || values?.isPackage == true))
                }
            }
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cleanmate-user-items.tsv")
        do { try tsv.write(to: file, atomically: true, encoding: .utf8); print("BENCH user items -> \(file.path)") }
        catch { print("BENCH user items NOT written: \(error)") }
        for (category, c) in counts.sorted(by: { $0.key < $1.key }) {
            print("BENCH user items \(category): total=\(c[0]) spaceLensAllowed=\(c[1]) userFileAllowed=\(c[2])")
        }
        print("BENCH user items excluded=\(policy.excluded.count) seen=\(seen) wrong=\(wrong) fullDiskAccess=\(skipping.isEmpty)")
        #expect(wrong == 0)
    }
}

/// Always runs (no real folder is read): the bench's protected-folder decision.
struct ScanBenchmarkGuardTests {
    let home = URL(fileURLWithPath: "/Users/someone")

    @Test func protectedRootsAreNotReadWithoutFullDiskAccess() {
        for path in ["Downloads", "Documents/Projects", "Library/Containers", "Library/Group Containers/x"] {
            #expect(!ScanBenchmark.mayRead(home.appending(path: path), home: home, hasFullDiskAccess: false), "\(path)")
            #expect(ScanBenchmark.mayRead(home.appending(path: path), home: home, hasFullDiskAccess: true), "\(path)")
        }
        // The home itself and unprotected folders are read; the scanners skip protected children themselves.
        for path in ["", "Developer", "Library/Caches", "DownloadsOld"] {
            #expect(ScanBenchmark.mayRead(home.appending(path: path), home: home, hasFullDiskAccess: false), "\(path)")
        }
    }
}
