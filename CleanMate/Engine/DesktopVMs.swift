import Foundation

/// Desktop virtual machines of Parallels Desktop (`.pvm`), VMware Fusion (`.vmwarevm`), UTM (`.utm`) and
/// VirtualBox (`~/VirtualBox VMs` and the machines its registry names), often 20–100 GB each. One row per machine,
/// unticked, moved to the Trash: removing one loses everything inside it — its disks, its snapshots, the apps
/// installed in it — and the hypervisor can only make an empty new machine, so a machine is listed only after it has
/// been unused for 90 days (`idleAge`); one that runs is a locked row.
///
/// Only files are read: no hypervisor is ever run and no machine is stopped. A machine's last use is the latest
/// change to its bundle and the files at its top (its disks are written while it runs). Parallels' machines are read
/// from the default folder `~/Parallels` only: the folder the app's own preferences name is not a documented key, so
/// it is never guessed at — a folder on another volume would be refused by the safety policy anyway.
nonisolated enum DesktopVMs {
    static let id = "desktop-vms"
    /// A machine is listed for removal only after unused this long (re-downloading or restoring one is expensive).
    static let idleAge: TimeInterval = 90 * 86_400
    /// Largest settings file read (VirtualBox's registry): a real one is a few KB.
    static let fileLimit = 1 << 20

    enum App: CaseIterable, Sendable {
        case parallels, vmware, utm, virtualbox

        /// Where its machines are, below the home folder.
        var folder: String {
            switch self {
            case .parallels: "Parallels"
            case .vmware: "Virtual Machines.localized"
            case .utm: "Library/Containers/com.utmapp.UTM/Data/Documents"
            case .virtualbox: "VirtualBox VMs"
            }
        }

        var name: String {
            switch self {
            case .parallels: "Parallels Desktop"
            case .vmware: "VMware Fusion"
            case .utm: "UTM"
            case .virtualbox: "VirtualBox"
            }
        }

        /// The bundle extension of its machines; empty for VirtualBox, whose machine is the folder holding the
        /// `.vbox` description.
        var bundleExtension: String {
            switch self {
            case .parallels: "pvm"
            case .vmware: "vmwarevm"
            case .utm: "utm"
            case .virtualbox: ""
            }
        }
    }

    /// One machine: `url` is its row (a bundle folder, or VirtualBox's folder holding the `.vbox`), which is also
    /// what goes to the Trash — everything of the machine sits inside it.
    struct Machine: Equatable, Sendable {
        let url: URL
        let app: App
        let name: String
        let parts: [URL]
    }

    // MARK: - Listing

    static func root(_ app: App, home: URL) -> URL { home.appending(path: app.folder) }

    /// The machines of `app` in the home folder `home`.
    static func machines(_ app: App, home: URL) -> [Machine] {
        let root = root(app, home: home)
        switch app {
        case .parallels, .vmware, .utm:
            return children(of: root).compactMap { name in
                let url = root.appending(path: name)
                guard bundle(name: name, of: app), isFolder(url) else { return nil }
                return Machine(url: url, app: app, name: String(name.dropLast(app.bundleExtension.count + 1)),
                               parts: [url])
            }
        case .virtualbox:
            var seen = Set<String>()
            return (children(of: root).compactMap { name in
                let url = root.appending(path: name)
                guard isFolder(url), children(of: url).contains(where: { $0.lowercased().hasSuffix(".vbox") }) else {
                    return nil
                }
                return Machine(url: url, app: app, name: name, parts: [url])
            } + registeredMachines(xml: home.appending(path: "Library/VirtualBox/VirtualBox.xml"))).filter {
                seen.insert($0.url.standardizedFileURL.path).inserted
            }
        }
    }

    /// `name` is a machine bundle of `app` (`Windows 11.pvm`), matched without case like APFS.
    private static func bundle(name: String, of app: App) -> Bool {
        !app.bundleExtension.isEmpty && name.lowercased().hasSuffix("." + app.bundleExtension)
    }

    /// The machines VirtualBox's registry `~/Library/VirtualBox/VirtualBox.xml` names, wherever they sit: the folder
    /// holding each `.vbox` description. `src` is absolute, or relative to the registry's folder (VirtualBox 4).
    static func registeredMachines(xml: URL) -> [Machine] {
        guard let document = try? XMLDocument(contentsOf: xml, options: []), isFolder(xml.deletingLastPathComponent())
        else { return [] }
        var entries: [XMLElement] = []
        func collect(_ element: XMLNode) {
            guard let element = element as? XMLElement else { return }
            if element.name == "MachineEntry" { entries.append(element) }
            element.children?.forEach(collect)
        }
        guard let root = document.rootElement() else { return [] }
        collect(root)
        return entries.compactMap { entry in
            guard var source = entry.attribute(forName: "src")?.stringValue else { return nil }
            if !source.hasPrefix("/") { source = xml.deletingLastPathComponent().appending(path: source).path }
            let vbox = URL(fileURLWithPath: source).standardizedFileURL
            let folder = vbox.deletingLastPathComponent()
            guard isFile(vbox), isFolder(folder) else { return nil }
            return Machine(url: folder, app: .virtualbox, name: folder.lastPathComponent, parts: [folder])
        }
    }

    /// The machines in the home folder of the policy, allowed with all their parts: listed only when unused for
    /// longer than `idleAge`, so an everyday machine is never offered for removal.
    static func find(policy: SafetyPolicy) -> [URL] {
        let home = policy.homeURL
        return App.allCases.flatMap { machines($0, home: home) }
            .filter { $0.parts.allSatisfy(policy.allows) && idle($0) }
            .map(\.url)
    }

    /// The machine whose row is `url`, listed now in the policy's home folder; nil otherwise.
    static func machine(at url: URL, policy: SafetyPolicy) -> Machine? {
        machine(at: url, home: policy.homeURL)
    }

    private static func machine(at url: URL, home: URL?) -> Machine? {
        guard let home else { return nil }
        let path = url.standardizedFileURL.path
        return App.allCases.lazy.flatMap { machines($0, home: home) }.first { $0.url.standardizedFileURL.path == path }
    }

    static func allows(_ url: URL, policy: SafetyPolicy) -> Bool {
        machine(at: url, policy: policy)?.parts.allSatisfy(policy.allows) == true
    }

    /// A machine is idle when the latest change to its bundle and its top-level files is longer than `idleAge` ago;
    /// one whose dates cannot be read is never listed.
    static func idle(_ machine: Machine, now: Date = Date()) -> Bool {
        guard let run = lastRun(machine.parts) else { return false }
        return now.timeIntervalSince(run) > idleAge
    }

    /// The latest change to the machine's parts and the files at their top (the disks a run writes), shared with
    /// `ContainerVMs`.
    static func lastRun(_ parts: [URL]) -> Date? { ContainerVMs.lastRun(parts) }

    // MARK: - Labels

    /// `Windows 11 (Parallels Desktop)`, dated when the machine was last used.
    static func label(of url: URL) -> (title: String, date: Date?)? {
        guard let machine = machine(at: url, home: home(of: url)) else { return nil }
        return ("\(machine.name) (\(machine.app.name))", lastRun(machine.parts))
    }

    /// The home folder `url` belongs to, read from where it is below it.
    private static func home(of url: URL) -> URL? {
        let path = url.standardizedFileURL.path
        for app in App.allCases {
            guard let range = path.range(of: "/" + app.folder + "/") else { continue }
            return URL(fileURLWithPath: String(path[..<range.lowerBound]))
        }
        return nil
    }

    // MARK: - Running

    /// What runs now: every process's working folder and arguments, and the files open below the home folder.
    typealias Activity = ContainerVMs.Activity

    static func activity(home: URL) -> Activity { ContainerVMs.activity(home: home) }

    /// The machine runs: a live pid in one of its `*.pid` files, a process naming one of its parts, or a file open
    /// in it.
    static func isRunning(_ machine: Machine, activity: Activity) -> Bool {
        if machine.parts.contains(where: ContainerVMs.hasLivePID) { return true }
        let parts = machine.parts.map { RunningProcesses.withoutPrivate($0.standardizedFileURL.path) }
        if parts.contains(where: { part in activity.arguments.contains { ContainerVMs.names($0, part) } }) { return true }
        return machine.parts.contains { RunningProcesses.holdsOpenFile($0, openPaths: activity.openPaths) }
    }

    // MARK: - Item

    /// `running` is injected by tests; the default reads the processes once per check, only when there is a machine.
    static func item(running: @escaping @Sendable (URL) -> Activity = activity(home:)) -> CleanerItem {
        var item = CleanerItem(id: id, title: "Desktop virtual machines not in use",
                               note: "Machines Parallels Desktop, VMware Fusion, UTM and VirtualBox keep, often 20–100 GB each. A machine is listed after 90 days unused. Moved to the Trash",
                               // UTM's folder is left out of the paths: it sits in ~/Library/Containers, which
                               // only Full Disk Access may read — its machines are still listed when readable.
                               paths: App.allCases.filter { $0 != .utm }.map { "~/" + $0.folder }, mode: .trash,
                               selectedByDefault: false,
                               showsWhenEmpty: false,
                               runningProcessNames: ["prl_vm_app", "vmware-vmx", "QEMULauncher", "VBoxHeadless",
                                                     "VirtualBoxVM"],
                               skipNote: "A virtual machine that is running, or one used in the last 90 days",
                               entryLabel: label(of:), selectableEntries: true,
                               findEntries: { _, policy in find(policy: policy) },
                               allowsEntry: { policy, url in allows(url, policy: policy) },
                               about: "The virtual machine a desktop hypervisor keeps: its disks, its snapshots and the apps installed inside it. Removing one is final — the app can only make an empty new machine, so a machine is offered after 90 days unused.",
                               afterClean: "Moved to the Trash. The app makes an empty new machine; everything the machine held — disks, snapshots, installed apps — is gone.")
        item.locksEntry = {
            let reason = String(localized: "This virtual machine is running. Stop it and scan again")
            let read = Locked<[String: Activity]>([:])
            return { url in
                guard let home = home(of: url), let machine = machine(at: url, home: home) else { return nil }
                let activity = read.withLock { cached in
                    if let known = cached[home.path] { return known }
                    let now = running(home)
                    cached[home.path] = now
                    return now
                }
                return isRunning(machine, activity: activity) ? reason : nil
            }
        }
        return item
    }

    // MARK: - Files

    private static func children(of url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// A real folder (not a symlink).
    private static func isFolder(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// A regular file (not a symlink).
    private static func isFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }
}
