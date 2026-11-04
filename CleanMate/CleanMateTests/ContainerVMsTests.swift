import Foundation
import Testing
@testable import CleanMate

/// Container VM disks: a fake home in a throwaway folder with the folders Colima, Lima, Rancher Desktop, Podman and
/// minikube write (small sparse disks), injected running processes, and a fake Trash.
final class ContainerVMsTests {
    let fm = FileManager.default
    let root = TestTemp.url("CleanMateContainerVMs")
    var home: URL { root.appending(path: "home") }
    var trash: URL { root.appending(path: "Trash") }
    var policy: SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }
    let reason = String(localized: "This virtual machine is running. Stop it and scan again")
    /// Logical size of each fake disk; only `written` bytes of it are allocated.
    static let logical: UInt64 = 1 << 30
    static let written = 65_536

    deinit { try? FileManager.default.removeItem(at: root) }

    /// A sparse disk at `path` below the home folder: `logical` bytes long, `written` of them allocated.
    @discardableResult
    func disk(_ path: String) throws -> URL {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: Self.written).write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: Self.logical)
        try handle.close()
        return url
    }

    func file(_ path: String, _ text: String = "x") throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: false, encoding: .utf8)
    }

    /// A Lima instance `name` in the Lima-based folder `base`.
    @discardableResult
    func lima(_ base: String, _ name: String) throws -> URL {
        try file("\(base)/\(name)/lima.yaml", "vmType: vz\n")
        try disk("\(base)/\(name)/diffdisk")
        return home.appending(path: "\(base)/\(name)")
    }

    /// A Podman machine `name` of `provider`: its disk image and its settings naming it and its ignition file.
    @discardableResult
    func podman(_ name: String, provider: String = "applehv") throws -> URL {
        let image = try disk(".local/share/containers/podman/machine/\(provider)/\(name)-arm64.raw")
        let config = home.appending(path: ".config/containers/podman/machine/\(provider)")
        try file(".config/containers/podman/machine/\(provider)/\(name).ign", "{}")
        let json = """
            {"Name": "\(name)", "ImagePath": {"Path": "\(image.path)"},
             "IgnitionFile": {"Path": "\(config.appending(path: name + ".ign").path)"}}
            """
        try file(".config/containers/podman/machine/\(provider)/\(name).json", json)
        return image
    }

    @discardableResult
    func minikube(_ name: String, driver: String = "qemu2") throws -> URL {
        try file(".minikube/machines/\(name)/config.json", #"{"DriverName": "\#(driver)", "Name": "\#(name)"}"#)
        try disk(".minikube/machines/\(name)/disk.qcow2")
        return home.appending(path: ".minikube/machines/\(name)")
    }

    func item(arguments: [String] = [], openPaths: Set<String> = []) -> CleanerItem {
        ContainerVMs.item(running: { _ in ContainerVMs.Activity(arguments: arguments, openPaths: openPaths) })
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
        let index = try #require(items.firstIndex { $0.id == ContainerVMs.id })
        #expect(items[index - 1].id == VagrantBoxes.id)
        let vms = items[index]
        #expect(vms.mode == .trash && !vms.selectedByDefault && vms.selectableEntries && !vms.showsWhenEmpty)
        #expect(vms.locksEntry != nil && vms.runningProcessNames.isEmpty && !vms.skipsOpenFiles)
    }

    /// One row per VM of each tool, named after the VM and its tool, measured as the bytes on disk of the sparse
    /// disks (not their logical size).
    @Test func listsEachToolsVMsWithAllocatedSize() async throws {
        try lima(".colima/_lima", "colima")
        try lima(".colima/_lima", "colima-work")
        try disk(".colima/_lima/_disks/colima/datadisk")
        try lima(".lima", "default")
        try lima("Library/Application Support/rancher-desktop/lima", "0")
        try podman("podman-machine-default")
        try minikube("minikube")
        let result = await scan(item())
        let titles = result.entries.compactMap(\.title).sorted()
        #expect(titles == ["Rancher Desktop", "work (Colima)", "default (Colima)",
                           "default (Lima)", "minikube (minikube)", "podman-machine-default (Podman)"].sorted())
        #expect(result.entries.allSatisfy { $0.lockReason == nil && $0.date != nil })
        for entry in result.entries {
            #expect(entry.size >= Int64(Self.written) && entry.size < 1 << 20, "\(entry.url.path): \(entry.size)")
        }
        // Colima's default VM counts its data disk too.
        let colima = try #require(result.entries.first { $0.title == "default (Colima)" })
        #expect(colima.size >= 2 * Int64(Self.written))
    }

    /// Never listed: Lima's own folders, a folder without `lima.yaml`, a Colima folder not named like an instance, a
    /// symlinked VM, a minikube machine whose driver keeps no disk there, a Podman disk no settings name.
    @Test func skipsWhatIsNoVM() async throws {
        try lima(".lima", "_config")
        try disk(".lima/_disks/data/datadisk")
        try disk(".lima/half/diffdisk")
        try lima(".colima/_lima", "other")
        let real = try lima(".lima", "real")
        try fm.createSymbolicLink(at: home.appending(path: ".lima/link"), withDestinationURL: real)
        try minikube("docker-one", driver: "docker")
        try disk(".local/share/containers/podman/machine/applehv/orphan-arm64.raw")
        // Settings naming a disk outside Podman's folder.
        try file(".config/containers/podman/machine/applehv/outside.json",
                 #"{"Name": "outside", "ImagePath": {"Path": "\#(home.appending(path: ".lima/real/diffdisk").path)"}}"#)
        #expect(await scan(item()).entries.map(\.url.lastPathComponent) == ["real"])
    }

    /// Colima's data disk is taken along only when it belongs to that instance.
    @Test func colimaDataDiskOnlyWhenItsOwn() throws {
        let base = home.appending(path: ".colima/_lima")
        try lima(".colima/_lima", "colima")
        try disk(".colima/_lima/_disks/colima/datadisk")
        let disk = base.appending(path: "_disks/colima")
        #expect(ContainerVMs.colimaDisk(of: "colima", root: base) == [disk])
        try fm.createSymbolicLink(atPath: disk.appending(path: "in_use_by").path, withDestinationPath: base.appending(path: "colima").path)
        #expect(ContainerVMs.colimaDisk(of: "colima", root: base) == [disk])
        try fm.removeItem(at: disk.appending(path: "in_use_by"))
        try fm.createSymbolicLink(atPath: disk.appending(path: "in_use_by").path, withDestinationPath: base.appending(path: "other").path)
        #expect(ContainerVMs.colimaDisk(of: "colima", root: base).isEmpty)
    }

    /// A running VM is a locked row, by its pid file, a process naming its disk, or a file open in it; skipped at clean.
    @Test func runningVMIsLockedAndKept() async throws {
        let colima = try lima(".colima/_lima", "colima")
        let vm = try lima(".lima", "dev")
        let image = try podman("podman-machine-default")
        let mk = try minikube("minikube")
        try "\(getpid())\n".write(to: colima.appending(path: "ha.pid"), atomically: false, encoding: .utf8)
        let running = item(arguments: ["/opt/homebrew/bin/vfkit", "--device", "virtio-blk,path=\(image.path),format=raw",
                                       "-drive", "file=\(mk.path)/disk.qcow2,if=virtio"],
                           openPaths: [vm.appending(path: "diffdisk").path])
        let result = await scan(running)
        #expect(result.entries.count == 4 && result.entries.allSatisfy { $0.lockReason == reason })

        let report = await Cleaner.clean(running, scan: result, policy: policy, trash: moveToFakeTrash,
                                         openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(report.skipped == 4 && report.trashed.isEmpty)
        for url in [colima, vm, image, mk] { #expect(fm.fileExists(atPath: url.path)) }
    }

    /// A lookalike path (another VM whose name starts the same) or a dead process doesn't lock it.
    @Test func lookalikeDoesNotLock() async throws {
        let vm = try lima(".colima/_lima", "colima")
        try lima(".colima/_lima", "colima-dev")
        let lookalike = item(arguments: ["file=\(vm.path)-old/diffdisk", vm.path + "x", vm.path + ".bak"])
        #expect(await scan(lookalike).entries.map(\.lockReason) == [nil, nil])
        // The other VM's disk locks that VM only.
        let other = await scan(item(arguments: ["file=\(vm.path)-dev/diffdisk,if=virtio"])).entries
        #expect(other.map { $0.url.lastPathComponent + ":" + ($0.lockReason == nil ? "free" : "locked") }.sorted()
                == ["colima-dev:locked", "colima:free"])
        #expect(ContainerVMs.names("file=\(vm.path)/diffdisk,if=virtio", vm.path))
        #expect(ContainerVMs.names(vm.path, vm.path))
        #expect(!ContainerVMs.names(vm.path + "-dev/diffdisk", vm.path))
        #expect(!ContainerVMs.names(vm.path + ".old", vm.path))
    }

    /// To the (fake) Trash with all its parts, put back where they were by Undo.
    @Test func trashedWithItsPartsAndPutBack() async throws {
        let colima = try lima(".colima/_lima", "colima")
        try disk(".colima/_lima/_disks/colima/datadisk")
        try file(".colima/default/colima.yaml", "cpu: 2\n")
        let image = try podman("podman-machine-default")
        let config = home.appending(path: ".config/containers/podman/machine/applehv")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let result = await scan(item())
        #expect(result.entries.count == 2)

        let report = await Cleaner.clean(item(), scan: result, policy: policy, trash: moveToFakeTrash,
                                         openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(report.skipped == 0 && report.trashed.count == 5 && report.freed == result.size)
        #expect(!fm.fileExists(atPath: colima.path) && !fm.fileExists(atPath: image.path))
        #expect(!fm.fileExists(atPath: home.appending(path: ".colima/_lima/_disks/colima").path))
        #expect(try fm.contentsOfDirectory(atPath: config.path).isEmpty)
        // Colima's settings stay.
        #expect(fm.fileExists(atPath: home.appending(path: ".colima/default/colima.yaml").path))
        #expect(await scan(item()).entries.isEmpty)

        let undo = await TrashUndo.restore(report.trashed, module: "Smart Scan", home: home)
        #expect(undo == TrashUndo.Result(restored: 5, skipped: 0))
        #expect(fm.fileExists(atPath: colima.appending(path: "diffdisk").path) && fm.fileExists(atPath: image.path))
        #expect(fm.fileExists(atPath: home.appending(path: ".colima/_lima/_disks/colima/datadisk").path))
        #expect(try Set(fm.contentsOfDirectory(atPath: config.path))
                == ["podman-machine-default.json", "podman-machine-default.ign"])
        #expect(await scan(item()).entries.count == 2)
    }

    /// Checked again right before removal: what isn't a VM now (its `lima.yaml` gone) is kept.
    @Test func checkedAgainBeforeRemoval() async throws {
        let vm = try lima(".lima", "default")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let result = await scan(item())
        try fm.removeItem(at: vm.appending(path: "lima.yaml"))
        let report = await Cleaner.clean(item(), scan: result, policy: policy, trash: moveToFakeTrash,
                                         openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(report.skipped == 1 && report.trashed.isEmpty && fm.fileExists(atPath: vm.path))
        #expect(!ContainerVMs.allows(vm, policy: policy))
        // Another home's VM is never allowed.
        let other = SafetyPolicy(home: root.appending(path: "other"), temp: root.appending(path: "tmp"))
        #expect(!ContainerVMs.allows(try lima(".lima", "again"), policy: other))
    }

    /// Dated by the latest change to its files: the date the Overview's suggestion reads.
    @Test func datedByItsLatestFile() async throws {
        let vm = try lima(".lima", "old")
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        for url in [vm, vm.appending(path: "lima.yaml"), vm.appending(path: "diffdisk")] {
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        #expect(await scan(item()).entries.first?.date == old)
    }
}
