import Foundation

/// Simulators' content, one entry per available device, erased with `simctl erase <udid>` for the ticked ones (the
/// device stays, empty as new); and the device clones Xcode makes to run tests in parallel, left in
/// `~/Library/Developer/XCTestDevices`, removed one by one. Both unticked and skipped while Xcode, Simulator or
/// xcodebuild runs. Devices are never deleted and runtimes never touched here.
nonisolated enum SimulatorDevices {
    static let dataID = "simulator-data"
    static let clonesID = "xctest-devices"
    static let devicesFolder = "~/Library/Developer/CoreSimulator/Devices"
    static let clonesFolder = "~/Library/Developer/XCTestDevices"
    static let bundleIDs = ["com.apple.dt.Xcode", "com.apple.iphonesimulator"]
    /// `xcodebuild test` boots and clones simulators, also without Xcode open.
    static let processNames = ["xcodebuild"]
    /// `state` in a device's `device.plist` when it is off; any other (creating, booting, booted, shutting down) locks it.
    static let shutdownState = 1

    /// The Smart Scan item for simulators' content. `xcrun` (a stand-in in tests) lists the available devices and
    /// erases them; `sizes` keeps each device folder's size between scans: CoreSimulator rewrites `device.plist` at
    /// every boot, shutdown and erase, which changes the folder's date, and a device's data only changes while booted.
    static func dataItem(xcrun: String = "/usr/bin/xcrun", sizes: FolderSizeCache = .shared) -> CleanerItem {
        var item = CleanerItem(
            id: dataID, title: "Simulator data",
            note: "Erases the apps and data of each ticked simulator (simctl erase); the simulators stay, empty as new",
            paths: [devicesFolder], selectedByDefault: false,
            probe: SizeProbe(command: ShellCommand(executable: xcrun, arguments: ["simctl", "list", "devices", "available", "-j"],
                                                   timeout: .seconds(30)),
                             parse: { DeveloperTools.simulatorIDs(in: $0, available: true).map(SizeProbe.Result.only) }),
            showsWhenEmpty: false, runningAppBundleIDs: bundleIDs, runningProcessNames: processNames,
            entryLabel: label(of:), selectableEntries: true, entrySizes: sizes)
        item.entryCommand = { url in
            // Only a device folder's own name: a UDID, never `all` or an option.
            guard let udid = UUID(uuidString: url.lastPathComponent) else { return nil }
            return ShellCommand(executable: xcrun, arguments: ["simctl", "erase", udid.uuidString], timeout: .seconds(120))
        }
        // Not shut down first: a device someone runs is kept, and `simctl erase` refuses one booted since this check.
        item.locksEntry = {
            let reason = String(localized: "This simulator is running. Shut it down and scan again")
            return { isRunning($0) ? reason : nil }
        }
        return item
    }

    /// The Smart Scan item for test device clones: each real folder in `XCTestDevices` (not a symlink, not
    /// `device_set.plist`), removed whole; a clone with a file open (booted) is kept.
    static func clonesItem() -> CleanerItem {
        CleanerItem(id: clonesID, title: "Test device clones",
                    note: "Copies of simulators Xcode makes to run tests in parallel, made again by the next parallel test run",
                    paths: [clonesFolder], selectedByDefault: false, showsWhenEmpty: false,
                    runningAppBundleIDs: bundleIDs, runningProcessNames: processNames, skipsOpenFiles: true,
                    skipsEntry: { { !isFolder($0) } }, entryLabel: cloneLabel(of:), selectableEntries: true)
    }

    /// `device.plist` of a device folder; nil when missing or unreadable.
    static func info(_ device: URL) -> [String: Any]? {
        (try? Data(contentsOf: device.appending(path: "device.plist")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
    }

    /// The device is not off (its `device.plist` says so); an unreadable one is not locked: `simctl erase` refuses a
    /// booted device anyway.
    static func isRunning(_ device: URL) -> Bool {
        guard let state = info(device)?["state"] as? Int else { return false }
        return state != shutdownState
    }

    /// "iPhone 17 Pro (iOS 26.0)" and when it was last used (`lastUsedAt`, else the date of its `data` folder).
    static func label(of device: URL) -> (title: String, date: Date?)? {
        guard let info = info(device), let name = info["name"] as? String else { return nil }
        let runtime = (info["runtime"] as? String).flatMap(runtimeName)
        return (runtime.map { "\(name) (\($0))" } ?? name, info["lastUsedAt"] as? Date ?? modified(device.appending(path: "data")))
    }

    /// A clone's device name ("Clone 1 of iPhone 17 Pro"), else its UDID (the folder's name).
    static func cloneLabel(of clone: URL) -> (title: String, date: Date?)? {
        let info = info(clone)
        return (info?["name"] as? String ?? clone.lastPathComponent,
                info?["lastUsedAt"] as? Date ?? modified(clone.appending(path: "data")))
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-26-0" → "iOS 26.0" (`xrOS` → "visionOS"); nil when not of that form.
    static func runtimeName(_ identifier: String) -> String? {
        guard let match = identifier.wholeMatch(of: /com\.apple\.CoreSimulator\.SimRuntime\.([A-Za-z]+)-(\d+(?:-\d+)*)/)
        else { return nil }
        let platform = match.1 == "xrOS" ? "visionOS" : String(match.1)
        return platform + " " + match.2.replacingOccurrences(of: "-", with: ".")
    }

    /// A folder itself, not a symlink to one nor a file.
    static func isFolder(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
