import Foundation
import Testing
@testable import CleanMate

/// Desktop virtual machines: a fake home in a throwaway folder with the bundles Parallels Desktop, VMware Fusion,
/// UTM and VirtualBox keep (a small sparse disk each), VirtualBox's registry, and injected running processes.
final class DesktopVMsTests {
    let fm = FileManager.default
    let root = TestTemp.url("CleanMateDesktopVMs")
    var home: URL { root.appending(path: "home") }
    var trash: URL { root.appending(path: "Trash") }
    var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }
    let reason = String(localized: "This virtual machine is running. Stop it and scan again")
    static let written = 65_536
    static let old = Date().addingTimeInterval(-120 * 86_400)

    deinit { try? FileManager.default.removeItem(at: root) }

    /// A sparse disk at `path` below the home folder, dated `old` like an unused machine's.
    @discardableResult
    func disk(_ path: String) throws -> URL {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: Self.written).write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 1 << 30)
        try handle.close()
        try fm.setAttributes([.modificationDate: Self.old], ofItemAtPath: url.path)
        return url
    }

    func file(_ path: String, _ text: String = "x", date: Date? = nil) throws {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: false, encoding: .utf8)
        if let date { try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
    }

    /// A machine bundle of `app` (Parallels, VMware or UTM): a folder named `name.<ext>` holding a sparse disk.
    @discardableResult
    func machine(_ name: String, _ app: DesktopVMs.App, date: Date? = DesktopVMsTests.old) throws -> URL {
        let bundle = DesktopVMs.root(app, home: home).appending(path: name + "." + app.bundleExtension)
        let sparse = try disk(bundle.appending(path: "disk.img").path)
        if let date {
            for url in [bundle, sparse] { try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
        }
        return bundle
    }

    /// A VirtualBox machine `name`: a folder in `~/VirtualBox VMs` holding the `.vbox` and a sparse disk.
    @discardableResult
    func vbox(_ name: String, date: Date? = DesktopVMsTests.old) throws -> URL {
        let folder = DesktopVMs.root(.virtualbox, home: home).appending(path: name)
        try file(folder.appending(path: name + ".vbox").path, "<VirtualBox/>", date: date)
        try disk(folder.appending(path: "disk.vdi").path)
        if let date { try fm.setAttributes([.modificationDate: date], ofItemAtPath: folder.path) }
        return folder
    }

    func item(arguments: [String] = [], openPaths: Set<String> = []) -> CleanerItem {
        DesktopVMs.item(running: { _ in DesktopVMs.Activity(arguments: arguments, openPaths: openPaths) })
    }

    func scan(_ item: CleanerItem) async -> ItemScan {
        await Scanner.scan(item, policy: policy, openPaths: EndToEndCleanTests.ownOpenPaths)
    }

    var moveToFakeTrash: @Sendable (URL) throws -> URL? {
        let trash = trash
        return { url in
            let target = trash.appending(path: UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
    }

    @Test func inDeveloperUntickedToTheTrash() throws {
        let items = CleanerGroup.developer.items
        let index = try #require(items.firstIndex { $0.id == DesktopVMs.id })
        #expect(items[index - 1].id == ContainerVMs.id)
        let vms = items[index]
        #expect(vms.mode == .trash && !vms.selectedByDefault && vms.selectableEntries && !vms.showsWhenEmpty)
        #expect(vms.locksEntry != nil && !vms.skipsOpenFiles
                && vms.runningProcessNames == ["prl_vm_app", "vmware-vmx", "QEMULauncher", "VBoxHeadless", "VirtualBoxVM"])
    }

    /// One row per machine of each app, named after the machine and its app, measured as the bytes on disk of the
    /// sparse disks, dated by the latest change to its files.
    @Test func listsEachAppsMachinesWithAllocatedSize() async throws {
        try machine("Windows 11", .parallels)
        try machine("Ubuntu", .vmware)
        try machine("macOS Sonoma", .utm)
        try vbox("Debian")
        let result = await scan(item())
        let titles = result.entries.compactMap(\.title).sorted()
        #expect(titles == ["Debian (VirtualBox)", "macOS Sonoma (UTM)", "Ubuntu (VMware Fusion)",
                           "Windows 11 (Parallels Desktop)"].sorted())
        #expect(result.entries.allSatisfy { $0.lockReason == nil && $0.date != nil })
        for entry in result.entries {
            #expect(entry.size >= Int64(Self.written) && entry.size < 1 << 20, "\(entry.url.path): \(entry.size)")
        }
    }

    /// Never listed: a folder without the bundle extension, a symlinked bundle, a bundle used in the last 90 days,
    /// a VirtualBox folder without a `.vbox`; files next to the machines are not machines.
    @Test func skipsWhatIsNoIdleMachine() async throws {
        try machine("Windows 11", .parallels)
        try file("Parallels/keep.txt")
        try file("Virtual Machines.localized/notes.md")
        let recent = try machine("Fresh", .parallels, date: Date().addingTimeInterval(-10 * 86_400))
        let upper = try machine("Upper", .parallels) // matched without case: renamed to a capital extension
        try fm.moveItem(at: upper, to: upper.deletingLastPathComponent().appending(path: "Ubuntu Backup.PVM"))
        let real = try vbox("Debian")
        try fm.createSymbolicLink(at: DesktopVMs.root(.virtualbox, home: home).appending(path: "link"),
                                  withDestinationURL: real)
        try file("VirtualBox VMs/empty/readme.txt")
        let listed = await scan(item()).entries.map(\.url.lastPathComponent).sorted()
        #expect(listed == ["Debian", "Ubuntu Backup.PVM", "Windows 11.pvm"], "was: \(listed)")
        #expect(fm.fileExists(atPath: recent.path))
    }

    /// VirtualBox's registry names machines wherever they sit, absolute or relative to the registry folder; one that
    /// the folder scan found already is listed once, one without its `.vbox` is not listed.
    @Test func virtualBoxRegistryMachines() async throws {
        try vbox("Debian")
        let sparse = try disk("VMs/other/disk.vdi")
        let otherVbox = sparse.deletingLastPathComponent().appending(path: "other.vbox")
        try file(otherVbox.path, "<VirtualBox/>", date: Self.old)
        try fm.setAttributes([.modificationDate: Self.old],
                             ofItemAtPath: sparse.deletingLastPathComponent().path)
        try file("Library/VirtualBox/VirtualBox.xml", """
            <?xml version="1.0"?>
            <VirtualBox xmlns="http://www.virtualbox.org/" version="1.17-macos">
              <MachineRegistry>
                <MachineEntry uuid="{aaaa}" src="\(otherVbox.path)"/>
                <MachineEntry uuid="{bbbb}" src="VirtualBox VMs/Debian/Debian.vbox"/>
                <MachineEntry uuid="{cccc}" src="VirtualBox VMs/gone/gone.vbox"/>
              </MachineRegistry>
            </VirtualBox>
            """)
        let listed = await scan(item()).entries.map(\.url.lastPathComponent).sorted()
        #expect(listed == ["Debian", "other"])
    }

    /// A machine that runs is a locked row, by a process naming its disk or a file open in it; skipped at clean.
    @Test func runningMachineIsLockedAndKept() async throws {
        let windows = try machine("Windows 11", .parallels)
        let ubuntu = try machine("Ubuntu", .vmware)
        let running = item(arguments: ["/usr/bin/vmware-vmx", "#!vm=!:\(ubuntu.path)/disk.img"],
                           openPaths: [windows.appending(path: "disk.img").path])
        let result = await scan(running)
        #expect(result.entries.count == 2 && result.entries.allSatisfy { $0.lockReason == reason })

        let report = await Cleaner.clean(running, scan: result, policy: policy, trash: moveToFakeTrash,
                                         openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(report.skipped == 2 && report.trashed.isEmpty)
        for url in [windows, ubuntu] { #expect(fm.fileExists(atPath: url.path)) }
    }

    /// A lookalike path (another machine whose name starts the same) doesn't lock it.
    @Test func lookalikeDoesNotLock() async throws {
        let windows = try machine("Windows 11", .parallels)
        try machine("Windows 11-dev", .parallels)
        let lookalike = item(arguments: [windows.path + "-dev/disk.img", windows.path + ".old"])
        #expect(await scan(lookalike).entries.map(\.lockReason) == [nil, nil])
    }

    /// To the (fake) Trash whole, put back where it was by Undo; files next to the machines stay.
    @Test func trashedAndPutBack() async throws {
        let windows = try machine("Windows 11", .parallels)
        try file("Parallels/keep.txt")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let result = await scan(item())
        #expect(result.entries.count == 1)

        let report = await Cleaner.clean(item(), scan: result, policy: policy, trash: moveToFakeTrash,
                                         openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(report.skipped == 0 && report.trashed.count == 1 && report.freed == result.size)
        #expect(!fm.fileExists(atPath: windows.path))
        #expect(fm.fileExists(atPath: home.appending(path: "Parallels/keep.txt").path))
        #expect(await scan(item()).entries.isEmpty)

        let undo = await TrashUndo.restore(report.trashed, module: "Smart Scan", home: home)
        #expect(undo == TrashUndo.Result(restored: 1, skipped: 0))
        #expect(fm.fileExists(atPath: windows.appending(path: "disk.img").path))
        #expect(await scan(item()).entries.count == 1)
    }

    /// Checked again right before removal: what isn't a machine now (the bundle deleted) is kept, and another
    /// home's machine is never allowed.
    @Test func checkedAgainBeforeRemoval() async throws {
        let windows = try machine("Windows 11", .parallels)
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let result = await scan(item())
        try fm.removeItem(at: windows)
        let report = await Cleaner.clean(item(), scan: result, policy: policy, trash: moveToFakeTrash,
                                         openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(report.skipped == 1 && report.trashed.isEmpty)
        #expect(!DesktopVMs.allows(windows, policy: policy))
        let other = SafetyPolicy(home: root.appending(path: "other"), temp: root.appending(path: "tmp"))
        #expect(!DesktopVMs.allows(home.appending(path: "Parallels/Again.pvm"), policy: other))
    }

    /// Dated by the latest change to its files: the date the Overview's suggestion reads.
    @Test func datedByItsLatestFile() async throws {
        let windows = try machine("Windows 11", .parallels)
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        for url in [windows, windows.appending(path: "disk.img")] {
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        #expect(await scan(item()).entries.first?.date == old)
    }
}
