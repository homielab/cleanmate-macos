import Foundation
import Testing
@testable import CleanMate

/// Simulators erased one by one through a stand-in `xcrun`, and the test device clones in XCTestDevices, in a
/// throwaway fake home: no real simulator is listed, erased or shut down.
final class SimulatorDevicesTests {
    private let root = TestTemp.url("CleanMateSimulators")
    private var home: URL { root.appending(path: "home") }
    private var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }
    private var devices: URL { home.appending(path: "Library/Developer/CoreSimulator/Devices") }
    private var clones: URL { home.appending(path: "Library/Developer/XCTestDevices") }
    private var xcrun: String { root.appending(path: "xcrun").path }
    private let lastUsed = Date(timeIntervalSince1970: 1_790_000_000)

    /// A shut down, a booted and an unavailable simulator (its runtime removed).
    private let shutDown = "11111111-1111-1111-1111-111111111111"
    private let booted = "22222222-2222-2222-2222-222222222222"
    private let unavailable = "33333333-3333-3333-3333-333333333333"

    /// Every call of the stand-in `xcrun`, one line each.
    private var calls: [String] {
        ((try? String(contentsOf: root.appending(path: "calls.log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    init() throws {
        for dir in ["home", "tmp"] { try FileManager.default.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true) }
        // Logs its arguments; `simctl list` prints list.json, `simctl erase` succeeds without touching anything.
        try """
            #!/bin/sh
            dir="$(dirname "$0")"
            echo "$*" >> "$dir/calls.log"
            case "$2" in
              list) cat "$dir/list.json" ;;
            esac
            """.write(to: URL(filePath: xcrun), atomically: true, encoding: .utf8)
        chmod(xcrun, 0o755)
        try list([(shutDown, true), (booted, true), (unavailable, false)])
        try device(shutDown, name: "iPhone 17 Pro", state: 1)
        try device(booted, name: "iPad Air", state: 3)
        try device(unavailable, name: "iPhone 15", state: 1)
        try Data(repeating: 1, count: 100).write(to: devices.appending(path: "device_set.plist"))
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func list(_ udids: [(String, Bool)]) throws {
        let devices = udids.map { #"{"udid":"\#($0.0)","isAvailable":\#($0.1),"name":"x"}"# }.joined(separator: ",")
        try #"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-0":[\#(devices)]}}"#
            .write(to: root.appending(path: "list.json"), atomically: true, encoding: .utf8)
    }

    private func plist(_ info: [String: Any], in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: folder.appending(path: "device.plist"))
    }

    private func device(_ udid: String, name: String, state: Int) throws {
        let folder = devices.appending(path: udid)
        try plist(["UDID": udid, "name": name, "state": state, "lastUsedAt": lastUsed,
                   "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-26-0"], in: folder)
        let app = folder.appending(path: "data/Containers/Data/Application/A")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 200_000).write(to: app.appending(path: "cache.db"))
    }

    private func dataItem() -> CleanerItem { SimulatorDevices.dataItem(xcrun: xcrun, sizes: FolderSizeCache(file: nil)) }

    @Test func listsAvailableSimulatorsAndLocksBootedOnes() async throws {
        let scan = await Scanner.scan(dataItem(), policy: policy)
        #expect(Set(scan.entries.map(\.url.lastPathComponent)) == [shutDown, booted])
        let off = try #require(scan.entries.first { $0.url.lastPathComponent == shutDown })
        let on = try #require(scan.entries.first { $0.url.lastPathComponent == booted })
        #expect(off.title == "iPhone 17 Pro (iOS 26.0)" && off.date == lastUsed && off.lockReason == nil)
        #expect(off.size >= 200_000)
        #expect(on.title == "iPad Air (iOS 26.0)" && on.lockReason != nil)
        #expect(calls == ["simctl list devices available -j"])
    }

    /// Only the ticked simulator is erased, by simctl (its folder is not deleted); a booted one is skipped.
    @Test func cleaningErasesOnlyTheTickedSimulator() async throws {
        let item = dataItem()
        let scan = await Scanner.scan(item, policy: policy)
        let report = await Cleaner.clean(item, scan: scan, policy: policy)
        let off = try #require(scan.entries.first { $0.url.lastPathComponent == shutDown })
        #expect(report.skipped == 1 && report.freed == off.size)
        #expect(calls.dropFirst() == ["simctl erase \(shutDown)"])
        for udid in [shutDown, booted, unavailable] {
            #expect(FileManager.default.fileExists(atPath: devices.appending(path: "\(udid)/data/Containers/Data/Application/A/cache.db").path))
        }

        var one = scan
        one.entries = scan.entries.filter { $0.url.lastPathComponent == booted }
        #expect(await Cleaner.clean(item, scan: one, policy: policy).skipped == 1)
        #expect(calls.count == 2)
    }

    /// Booted between the scan and the clean: kept.
    @Test func simulatorBootedSinceTheScanIsKept() async throws {
        let item = dataItem()
        var scan = await Scanner.scan(item, policy: policy)
        scan.entries = scan.entries.filter { $0.url.lastPathComponent == shutDown }
        try device(shutDown, name: "iPhone 17 Pro", state: 3)
        let report = await Cleaner.clean(item, scan: scan, policy: policy)
        #expect(report.skipped == 1 && report.freed == 0)
        #expect(!calls.contains { $0.contains("erase") })
    }

    /// Only a folder named by a UDID is erased: never `all` or anything simctl would read as an option.
    @Test func onlyUDIDFoldersAreErased() async throws {
        try list([("all", true), ("--help", true)])
        for name in ["all", "--help"] { try device(name, name: name, state: 1) }
        let item = dataItem()
        let scan = await Scanner.scan(item, policy: policy)
        #expect(scan.entries.count == 2)
        let report = await Cleaner.clean(item, scan: scan, policy: policy)
        #expect(report.skipped == 2 && report.freed == 0)
        #expect(!calls.contains { $0.contains("erase") })
    }

    /// simctl failing (no Xcode): nothing listed.
    @Test func nothingListedWithoutSimctl() async {
        let item = SimulatorDevices.dataItem(xcrun: root.appending(path: "missing").path, sizes: FolderSizeCache(file: nil))
        #expect(await Scanner.scan(item, policy: policy).entries.isEmpty)
    }

    @Test func clonesListedAndRemovedOneByOne() async throws {
        let first = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", second = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        try plist(["name": "Clone 1 of iPhone 17 Pro", "lastUsedAt": lastUsed], in: clones.appending(path: first))
        try FileManager.default.createDirectory(at: clones.appending(path: "\(second)/data"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 50_000).write(to: clones.appending(path: "\(second)/data/app.db"))
        try Data(repeating: 1, count: 100).write(to: clones.appending(path: "device_set.plist"))
        try FileManager.default.createSymbolicLink(at: clones.appending(path: "linked"), withDestinationURL: devices.appending(path: shutDown))

        let item = SimulatorDevices.clonesItem()
        let scan = await Scanner.scan(item, policy: policy, openPaths: { _ in [] })
        #expect(Set(scan.entries.map(\.url.lastPathComponent)) == [first, second])
        let named = try #require(scan.entries.first { $0.url.lastPathComponent == first })
        let unnamed = try #require(scan.entries.first { $0.url.lastPathComponent == second })
        #expect(named.title == "Clone 1 of iPhone 17 Pro" && named.date == lastUsed)
        #expect(unnamed.title == second)

        var one = scan
        one.entries = [unnamed]
        let report = await Cleaner.clean(item, scan: one, policy: policy, openPaths: { _ in [] })
        #expect(report.skipped == 0)
        #expect(!FileManager.default.fileExists(atPath: clones.appending(path: second).path))
        for kept in [first, "device_set.plist"] { #expect(FileManager.default.fileExists(atPath: clones.appending(path: kept).path)) }
        #expect(FileManager.default.fileExists(atPath: devices.appending(path: "\(shutDown)/device.plist").path))
    }

    @Test func runtimeNames() {
        #expect(SimulatorDevices.runtimeName("com.apple.CoreSimulator.SimRuntime.iOS-26-0") == "iOS 26.0")
        #expect(SimulatorDevices.runtimeName("com.apple.CoreSimulator.SimRuntime.watchOS-11-5") == "watchOS 11.5")
        #expect(SimulatorDevices.runtimeName("com.apple.CoreSimulator.SimRuntime.xrOS-2-0") == "visionOS 2.0")
        #expect(SimulatorDevices.runtimeName("iOS 26") == nil)
    }

    @Test func catalogItems() throws {
        let ids = CleanerGroup.developer.items.map(\.id)
        let data = try #require(ids.firstIndex(of: SimulatorDevices.dataID))
        #expect(ids[data + 1] == SimulatorDevices.clonesID)
        for item in CleanerGroup.developer.items[data...(data + 1)] {
            #expect(!item.selectedByDefault && !item.showsWhenEmpty && item.selectableEntries && item.command == nil, "\(item.id)")
            #expect(item.mode == .delete && item.note != nil, "\(item.id)")
        }
        let item = CleanerGroup.developer.items[data]
        #expect(item.entryCommand?(devices.appending(path: shutDown))?.arguments == ["simctl", "erase", shutDown])
        #expect(CleanerGroup.developer.items[data + 1].skipsOpenFiles)
    }

    @MainActor @Test func lockedWhileXcodeSimulatorOrTestsRun() throws {
        let model = SmartScanModel(module: .smartScan) { [] }
        model.runningApps = [] // not the apps running on this Mac
        let items = CleanerGroup.developer.items.filter { [SimulatorDevices.dataID, SimulatorDevices.clonesID].contains($0.id) }
        #expect(items.count == 2 && items.allSatisfy { !model.isRunning($0) })
        for app in SimulatorDevices.bundleIDs {
            model.runningApps = [app]
            #expect(items.allSatisfy { model.isRunning($0) }, "\(app)")
        }
        model.runningApps = []
        model.runningProcesses = ["xcodebuild"]
        #expect(items.allSatisfy { model.isRunning($0) })
    }
}
