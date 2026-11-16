import Foundation

/// Old Godot export templates: `~/Library/Application Support/Godot/export_templates/<version>` (`4.2.1.stable`,
/// `4.3.beta2`, `4.2.1.stable.mono`), 0.5–1 GB each; every editor version installs its own and none is removed when
/// a newer editor replaces it. One entry per version, unticked, deleted whole (installed again from the editor:
/// Editor › Manage Export Templates). Kept, never listed (checked at scan and again right before removal): the newest
/// version of each flavour (standard, .NET `mono`) and a folder whose name is no version. Skipped while Godot runs.
nonisolated enum GodotTemplates {
    static let id = "godot-old-export-templates"
    static let path = "~/Library/Application Support/Godot/export_templates"
    static let bundleIDs = ["org.godotengine.godot"]

    struct Version: Comparable {
        var numbers: [Int]
        /// dev/alpha < beta < rc < stable, then its number (`beta2`).
        var stage: Int
        var stageNumber: Int
        var mono: Bool

        static func < (a: Version, b: Version) -> Bool {
            let count = max(a.numbers.count, b.numbers.count)
            let x = a.numbers + Array(repeating: 0, count: count - a.numbers.count)
            let y = b.numbers + Array(repeating: 0, count: count - b.numbers.count)
            if x != y { return x.lexicographicallyPrecedes(y) }
            return (a.stage, a.stageNumber) < (b.stage, b.stageNumber)
        }
    }

    /// `4.2.1.stable` → 4.2.1 stable; `4.3.beta2.mono` → 4.3 beta 2, .NET. nil for any other name.
    static func version(_ name: String) -> Version? {
        guard let match = name.wholeMatch(of: /(\d+(?:\.\d+){1,3})\.(dev|alpha|beta|rc|stable)(\d*)(\.mono)?/) else { return nil }
        let stages = ["dev": 0, "alpha": 0, "beta": 1, "rc": 2, "stable": 3]
        return Version(numbers: match.1.split(separator: ".").compactMap { Int($0) }, stage: stages[String(match.2)] ?? 0,
                       stageNumber: Int(match.3) ?? 0, mono: match.4 != nil)
    }

    /// The version folders other than the newest of each flavour.
    static func stale(_ names: some Sequence<String>) -> Set<String> {
        let versions = names.compactMap { name in version(name).map { (name: name, version: $0) } }
        var stale = Set(versions.map(\.name))
        for mono in [false, true] {
            if let newest = versions.filter({ $0.version.mono == mono }).max(by: { $0.version < $1.version }) {
                stale.remove(newest.name)
            }
        }
        return stale
    }

    /// `url` is a real version folder in `export_templates`, older than the newest of its flavour there.
    static func allows(_ url: URL, policy: SafetyPolicy) -> Bool {
        guard OldRuntimes.isVersionFolder(url, policy: policy),
              let siblings = try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        else { return false }
        return stale(siblings).contains(url.lastPathComponent)
    }

    static func item() -> CleanerItem {
        CleanerItem(id: id, title: "Old Godot export templates",
                    note: "Export templates of Godot versions other than the newest, installed again from the editor (Manage Export Templates)",
                    paths: [path], selectedByDefault: false, showsWhenEmpty: false, runningAppBundleIDs: bundleIDs,
                    entryLabel: OldRuntimes.label("Godot"), selectableEntries: true,
                    allowsEntry: { policy, url in allows(url, policy: policy) })
    }
}
