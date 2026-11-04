import Foundation

/// Disks of the virtual machines that Colima, Lima, Rancher Desktop, Podman and minikube run containers in (each one
/// 10–60 GB of `basedisk`/`diffdisk`/`.raw`/`.qcow2`, allocated sparse), one row per VM, unticked, moved to the Trash.
/// The containers, images and volumes inside the VM go with it, never the user's code; the tool makes a new VM at its
/// next start (`colima start`, `limactl start`, `podman machine init`, `minikube start`, Rancher Desktop by itself).
/// Only files are read: no tool is ever run, and a VM is never stopped.
///
/// Listed (at scan and again right before removal):
/// - Lima-based (`~/.colima/_lima`, `~/.lima`, `~/Library/Application Support/rancher-desktop/lima`): a real, not
///   hidden folder holding a regular `lima.yaml`, never `_config`, `_disks`, `_networks`. A Colima instance is
///   `colima` (profile `default`) or `colima-<profile>`; its data disk `_lima/_disks/<instance>` (Docker's images and
///   volumes) goes with it when it is a real folder no other instance uses (`in_use_by`). Colima's settings in
///   `~/.colima/<profile>` and Lima's own named disks are kept.
/// - Podman: the disk image `~/.local/share/containers/podman/machine/<provider>/<file>` that a machine's settings
///   `~/.config/containers/podman/machine/<provider>/<name>.json` name (`ImagePath`); the settings and the ignition
///   file go with it. A disk no settings name is not listed.
/// - minikube: `~/.minikube/machines/<name>` holding `config.json` whose driver keeps a disk there (not docker,
///   podman, none or ssh, whose machines live elsewhere). The profile (`~/.minikube/profiles`) is kept.
///
/// A VM that runs is a locked row: a live pid in one of its `*.pid` files, a process whose arguments or working
/// folder name it (qemu, vz, vfkit, krunkit, hyperkit), or a file open in it.
nonisolated enum ContainerVMs {
    static let id = "container-vms"
    /// Largest settings file read: a real one is a few KB.
    static let fileLimit = 1 << 20

    enum Tool: CaseIterable, Sendable {
        case colima, lima, rancher, podman, minikube

        /// Where its VMs are, below the home folder.
        var folder: String {
            switch self {
            case .colima: ".colima/_lima"
            case .lima: ".lima"
            case .rancher: "Library/Application Support/rancher-desktop/lima"
            case .podman: ".local/share/containers/podman/machine"
            case .minikube: ".minikube/machines"
            }
        }

        var name: String {
            switch self {
            case .colima: "Colima"
            case .lima: "Lima"
            case .rancher: "Rancher Desktop"
            case .podman: "Podman"
            case .minikube: "minikube"
            }
        }
    }

    /// Podman's machine settings, below the home folder.
    static let podmanConfig = ".config/containers/podman/machine"
    /// minikube drivers whose machine has no disk in `~/.minikube/machines`.
    static let diskless: Set<String> = ["docker", "podman", "none", "ssh", ""]

    /// One VM: `url` is its row (a folder, or Podman's disk file), `parts` what goes to the Trash, `url` first.
    struct Machine: Equatable, Sendable {
        let url: URL
        let tool: Tool
        let name: String
        let parts: [URL]
    }

    // MARK: - Listing

    static func root(_ tool: Tool, home: URL) -> URL { home.appending(path: tool.folder) }

    /// The VMs of `tool` in the home folder `home`.
    static func machines(_ tool: Tool, home: URL) -> [Machine] {
        let root = root(tool, home: home)
        switch tool {
        case .colima, .lima, .rancher:
            return children(of: root).compactMap { name in
                let url = root.appending(path: name)
                guard !name.hasPrefix("_"), isFolder(url), isFile(url.appending(path: "lima.yaml")) else { return nil }
                guard tool == .colima else { return Machine(url: url, tool: tool, name: name, parts: [url]) }
                let profile: String
                if name == "colima" { profile = "default" } else if name.hasPrefix("colima-"), name.count > 7 {
                    profile = String(name.dropFirst(7))
                } else { return nil }
                return Machine(url: url, tool: tool, name: profile, parts: [url] + colimaDisk(of: name, root: root))
            }
        case .podman:
            return podmanMachines(root: root, config: home.appending(path: podmanConfig))
        case .minikube:
            return children(of: root).compactMap { name in
                let url = root.appending(path: name)
                guard isFolder(url), let config = json(url.appending(path: "config.json")) as? [String: Any],
                      let driver = config["DriverName"] as? String, !diskless.contains(driver) else { return nil }
                return Machine(url: url, tool: tool, name: name, parts: [url])
            }
        }
    }

    /// Colima's data disk of `instance`, when it is a real folder used by no other instance.
    static func colimaDisk(of instance: String, root: URL) -> [URL] {
        let disk = root.appending(path: "_disks").appending(path: instance)
        guard isFolder(disk) else { return [] }
        let link = disk.appending(path: "in_use_by")
        var info = stat()
        if lstat(link.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFLNK,
                  let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path),
                  URL(fileURLWithPath: target).lastPathComponent == instance else { return [] }
        }
        return [disk]
    }

    /// Podman machines whose settings in `config/<provider>/*.json` name a disk image `root/<provider>/<file>`.
    static func podmanMachines(root: URL, config: URL) -> [Machine] {
        children(of: config).flatMap { provider -> [Machine] in
            let folder = config.appending(path: provider)
            guard isFolder(folder) else { return [] }
            return children(of: folder).filter { $0.hasSuffix(".json") }.compactMap { file in
                let settings = folder.appending(path: file)
                guard let json = json(settings) as? [String: Any],
                      let image = path(json["ImagePath"]).map(URL.init(fileURLWithPath:))?.standardizedFileURL,
                      image.deletingLastPathComponent().path == root.appending(path: provider).standardizedFileURL.path,
                      isFile(image), !image.lastPathComponent.hasPrefix(".") else { return nil }
                // Podman 5 writes `IgnitionFile`, Podman 4 `IgnitionFilePath`; kept unless it is in the settings folder.
                let ignition = (path(json["IgnitionFile"]) ?? path(json["IgnitionFilePath"]))
                    .map { URL(fileURLWithPath: $0).standardizedFileURL }
                    .flatMap { $0.deletingLastPathComponent().path == folder.standardizedFileURL.path && isFile($0) ? $0 : nil }
                let name = (json["Name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? String(file.dropLast(5))
                return Machine(url: image, tool: .podman, name: name, parts: [image, settings] + [ignition].compactMap { $0 })
            }
        }
    }

    /// The VMs in `roots` (the item's folders) of the policy's home folder, each allowed by the policy with all its parts.
    static func find(in roots: [URL], policy: SafetyPolicy) -> [URL] {
        let wanted = Set(roots.map(\.standardizedFileURL.path))
        return Tool.allCases.flatMap { tool -> [Machine] in
            let root = root(tool, home: policy.homeURL)
            guard wanted.contains(root.standardizedFileURL.path), !policy.rootThroughSymlink(root) else { return [] }
            return machines(tool, home: policy.homeURL)
        }.filter { $0.parts.allSatisfy(policy.allows) }.map(\.url)
    }

    /// The VM whose row is `url`, listed now in the policy's home folder; nil otherwise.
    static func machine(at url: URL, policy: SafetyPolicy) -> Machine? {
        let path = url.standardizedFileURL.path
        for tool in Tool.allCases {
            let root = root(tool, home: policy.homeURL)
            guard path.hasPrefix(root.standardizedFileURL.path + "/") else { continue }
            guard !policy.rootThroughSymlink(root) else { return nil }
            return machines(tool, home: policy.homeURL).first { $0.url.standardizedFileURL.path == path }
        }
        return nil
    }

    static func allows(_ url: URL, policy: SafetyPolicy) -> Bool {
        machine(at: url, policy: policy)?.parts.allSatisfy(policy.allows) == true
    }

    /// What goes to the Trash for the row `url`: the VM and the files and folders that belong to it alone.
    static func parts(of url: URL, policy: SafetyPolicy) -> [URL] {
        guard let machine = machine(at: url, policy: policy), machine.parts.allSatisfy(policy.allows) else { return [] }
        return machine.parts
    }

    // MARK: - Labels

    /// `default (Colima)`, dated when the VM last ran: the latest change to a file at the top of its parts (the disks,
    /// logs and pid files a run writes; Podman's settings record each start).
    static func label(of url: URL) -> (title: String, date: Date?)? {
        guard let machine = machine(at: url, home: home(of: url)) else { return nil }
        let title = machine.tool == .rancher && machine.name == "0" ? machine.tool.name : "\(machine.name) (\(machine.tool.name))"
        return (title, lastRun(machine.parts))
    }

    /// The home folder `url` belongs to, read from where it is below it.
    private static func home(of url: URL) -> URL? {
        let path = url.standardizedFileURL.path
        for tool in Tool.allCases {
            guard let range = path.range(of: "/" + tool.folder + "/") else { continue }
            return URL(fileURLWithPath: String(path[..<range.lowerBound]))
        }
        return nil
    }

    private static func machine(at url: URL, home: URL?) -> Machine? {
        guard let home else { return nil }
        let path = url.standardizedFileURL.path
        return Tool.allCases.lazy.flatMap { machines($0, home: home) }.first { $0.url.standardizedFileURL.path == path }
    }

    static func lastRun(_ parts: [URL]) -> Date? {
        var latest: Date?
        func note(_ path: String) {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG || info.st_mode & S_IFMT == S_IFDIR else { return }
            let date = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            if latest.map({ date > $0 }) ?? true { latest = date }
        }
        for part in parts {
            note(part.path)
            if isFolder(part) { for name in children(of: part) where isFile(part.appending(path: name)) { note(part.appending(path: name).path) } }
        }
        return latest
    }

    // MARK: - Running

    /// What runs now: every process's working folder and arguments, and the files open below the home folder.
    struct Activity: Sendable {
        var arguments: [String] = []
        var openPaths: Set<String> = []
    }

    static func activity(home: URL) -> Activity {
        Activity(arguments: RunningProcesses.workingFoldersAndArguments(),
                 openPaths: RunningProcesses.openPaths(under: home.path))
    }

    /// The VM runs: one of its `*.pid` files names a live process, or a process names or holds open one of its parts.
    static func isRunning(_ machine: Machine, activity: Activity) -> Bool {
        if machine.parts.contains(where: hasLivePID) { return true }
        let parts = machine.parts.map { RunningProcesses.withoutPrivate($0.standardizedFileURL.path) }
        if parts.contains(where: { part in activity.arguments.contains { names($0, part) } }) { return true }
        return machine.parts.contains { RunningProcesses.holdsOpenFile($0, openPaths: activity.openPaths) }
    }

    /// `argument` holds `path` as a whole path (`file=/…/diffdisk,if=virtio`, `/…/colima/ha.sock`), not as the start of
    /// another name (`/…/colima-dev`).
    static func names(_ argument: String, _ path: String) -> Bool {
        let argument = RunningProcesses.withoutPrivate(argument)
        var search = argument.startIndex..<argument.endIndex
        while let found = argument.range(of: path, range: search) {
            guard found.upperBound < argument.endIndex else { return true }
            let next = argument[found.upperBound]
            if !(next.isLetter || next.isNumber || next == "-" || next == "_" || next == ".") { return true }
            search = found.upperBound..<argument.endIndex
        }
        return false
    }

    /// A `*.pid` file at the top of the folder `url` holds the id of a process alive now.
    static func hasLivePID(_ url: URL) -> Bool {
        guard isFolder(url) else { return false }
        return children(of: url).filter { $0.hasSuffix(".pid") }.contains { name in
            let file = url.appending(path: name)
            guard isFile(file), let data = FileManager.default.contents(atPath: file.path), data.count <= 64,
                  let pid = Int32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
                  pid > 0 else { return false }
            return kill(pid, 0) == 0 || errno == EPERM
        }
    }

    // MARK: - Item

    /// `running` is injected by tests; the default reads the processes once per check, only when there is a VM.
    static func item(running: @escaping @Sendable (URL) -> Activity = activity(home:)) -> CleanerItem {
        var item = CleanerItem(id: id, title: "Container VMs not in use",
                               note: "Disks of the virtual machines Colima, Lima, Podman, minikube and Rancher Desktop run containers in. Moved to the Trash",
                               paths: Tool.allCases.map { "~/" + $0.folder }, mode: .trash, selectedByDefault: false,
                               showsWhenEmpty: false,
                               skipNote: "A virtual machine that is running",
                               entryLabel: label(of:), selectableEntries: true,
                               findEntries: { roots, policy in find(in: roots, policy: policy) },
                               allowsEntry: { policy, url in allows(url, policy: policy) },
                               entryParts: { policy, url in parts(of: url, policy: policy) },
                               about: "The disk of a virtual machine a container tool made to run Linux containers. Removing it loses the containers, images and volumes inside the VM, never your code or project files.",
                               afterClean: "Moved to the Trash. Make the VM again with colima start, limactl start, podman machine init or minikube start; Rancher Desktop makes a new one when it starts. Pull or build your images again.")
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

    /// A regular file of at most `fileLimit` parsed as JSON; nil otherwise.
    private static func json(_ url: URL) -> Any? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= fileLimit,
              let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// `{"Path": "/…"}` (Podman's `VMFile`) → its absolute path.
    private static func path(_ value: Any?) -> String? {
        guard let path = (value as? [String: Any])?["Path"] as? String, path.hasPrefix("/") else { return nil }
        return path
    }
}
