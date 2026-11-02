import Foundation

/// Old Vagrant box versions: `<VAGRANT_HOME or ~/.vagrant.d>/boxes/<name>/<version>/<provider>/`, the name with `/`
/// written `-VAGRANTSLASH-`. Each `vagrant box update` leaves the previous version (0.5–2 GB). One entry per box and
/// version, unticked, deleted whole (downloaded again with `vagrant box add`). Kept, never listed (checked at scan and
/// again right before removal): the newest version of each box (numbers compared part by part, like Vagrant), a folder
/// whose name is no version, and every version a machine uses in `data/machine-index/index`. When that index exists
/// but can't be read, nothing is listed. Only files are read, `vagrant` is never run; projects' `.vagrant` folders
/// are never touched. Skipped while `vagrant` runs.
nonisolated enum VagrantBoxes {
    typealias Version = AndroidSDKComponents.Version

    static let id = "vagrant-old-boxes"
    static let path = "~/.vagrant.d/boxes"
    static let shellFolders = ["VAGRANT_HOME": ["boxes"]]
    /// Largest machine index read: a real one is a few KB per machine.
    static let indexLimit = 4 * 1024 * 1024

    struct BoxVersion: Hashable { let name: String; let version: String }

    /// The box name of a folder in `boxes` (`hashicorp-VAGRANTSLASH-bionic64` → `hashicorp/bionic64`).
    static func boxName(folder: String) -> String { folder.replacingOccurrences(of: "-VAGRANTSLASH-", with: "/") }

    /// The box versions machines use; empty when there is no index, nil when it can't be read.
    static func used(boxes root: URL) -> Set<BoxVersion>? {
        let index = root.deletingLastPathComponent().appending(path: "data/machine-index/index")
        guard FileManager.default.fileExists(atPath: index.path) else { return [] }
        guard let size = (try? index.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= indexLimit,
              let data = try? Data(contentsOf: index) else { return nil }
        return used(in: data)
    }

    static func used(in data: Data) -> Set<BoxVersion>? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let machines = json["machines"] as? [String: Any] else { return nil }
        var found = Set<BoxVersion>()
        for case let machine as [String: Any] in machines.values {
            guard let extra = machine["extra_data"] as? [String: Any], let box = extra["box"] as? [String: Any] else { continue }
            guard let name = box["name"] as? String, let version = box["version"] as? String else { return nil }
            found.insert(BoxVersion(name: name, version: version))
        }
        return found
    }

    /// The version folders of the box folder `box` that are listed: all but the newest, those without a version and
    /// those machines use.
    static func old(in box: URL, used: Set<BoxVersion>, policy: SafetyPolicy) -> [URL] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: box.path)) ?? []).sorted()
            .filter { !$0.hasPrefix(".") && OldRuntimes.isVersionFolder(box.appending(path: $0), policy: policy) }
        let versions = names.compactMap { name in Version(name).flatMap { v in v.suffix.isEmpty ? (name, v) : nil } }
        guard let newest = versions.max(by: { $0.1 < $1.1 }) else { return [] }
        let name = boxName(folder: box.lastPathComponent)
        return versions.map(\.0).filter { $0 != newest.0 && !used.contains(BoxVersion(name: name, version: $0)) }
            .map { box.appending(path: $0) }
    }

    static func roots(_ policy: SafetyPolicy) -> Set<String> {
        ToolVersionManagers.installRoots(path: path, shellFolders: shellFolders, policy: policy)
    }

    static func find(in roots: [URL], policy: SafetyPolicy) -> [URL] {
        let allowed = Self.roots(policy)
        var seen = Set<String>(), found: [URL] = []
        for root in roots.map(\.standardizedFileURL) where allowed.contains(root.path) && seen.insert(root.path).inserted {
            guard let used = used(boxes: root) else { continue }
            let boxes = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted().filter { !$0.hasPrefix(".") }
            for box in boxes { found += old(in: root.appending(path: box), used: used, policy: policy) }
        }
        return found
    }

    /// `url` is `<boxes>/<box>/<version>`, still an old version no machine uses.
    static func allows(_ url: URL, policy: SafetyPolicy) -> Bool {
        let url = url.standardizedFileURL, box = url.deletingLastPathComponent(), root = box.deletingLastPathComponent()
        guard roots(policy).contains(root.path), let used = used(boxes: root) else { return false }
        return old(in: box, used: used, policy: policy).contains { $0.standardizedFileURL.path == url.path }
    }

    /// `hashicorp/bionic64 1.0.282 (virtualbox)`, dated when it was downloaded.
    static func label(of url: URL) -> (title: String, date: Date?)? {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let providers = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        let title = boxName(folder: url.deletingLastPathComponent().lastPathComponent) + " " + url.lastPathComponent
        return (providers.isEmpty ? title : title + " (" + providers.joined(separator: ", ") + ")", date)
    }

    /// `sizes` is injected by tests.
    static func item(sizes: FolderSizeCache = .shared) -> CleanerItem {
        CleanerItem(id: id, title: "Old Vagrant boxes",
                    note: "Box versions other than the newest and those a Vagrant machine uses, downloaded again with vagrant box add",
                    paths: [path], selectedByDefault: false, shellFolders: shellFolders, showsWhenEmpty: false,
                    runningProcessNames: ["vagrant"], entryLabel: label(of:), selectableEntries: true,
                    findEntries: { roots, policy in find(in: roots, policy: policy) },
                    allowsEntry: { policy, url in allows(url, policy: policy) },
                    entrySizes: sizes)
    }
}
