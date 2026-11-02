import Foundation

/// Providers and modules Terraform or OpenTofu downloaded into projects nobody worked on for `StaleProjects.days` days:
/// only `<project>/.terraform/providers` and `.terraform/modules` next to a `*.tf` file, found by the walk the other
/// stale-project items share (`StaleProjects.projectFolders`). `terraform init` downloads them again: one entry per
/// folder labelled with its project's path, unticked, moved to the Trash. Never `.terraform/terraform.tfstate`,
/// `.terraform/environment`, nor the project's `*.tfstate`, lock file or code.
nonisolated enum StaleTerraform {
    static let folderNames: Set = ["providers", "modules"]
    /// Files that change when a project's providers change or work on it is committed (`.git/index`); its `*.tf` too
    /// (`lastWorkedOn`).
    static let markers = [".terraform.lock.hcl", "terraform.tfstate", ".git/index"]
    /// Terraform, OpenTofu and the provider plugins they start, run in the project.
    static func isTool(_ name: String) -> Bool {
        name == "terraform" || name == "tofu" || name.hasPrefix("terraform-provider-")
    }

    /// The Smart Scan item. `home`, `hasFullDiskAccess`, `running` (`RunningProcesses.folders`), `now` and `sizes`
    /// (sizes kept between scans) are injected by tests.
    static func item(home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                     hasFullDiskAccess: @escaping @Sendable () -> Bool = { FullDiskAccess.isGranted },
                     running: @escaping @Sendable () -> [String] = { RunningProcesses.folders(ofProcessesNamed: isTool) },
                     now: @escaping @Sendable () -> Date = { .now }, sizes: FolderSizeCache = .shared) -> CleanerItem {
        CleanerItem(id: "stale-terraform-providers", title: "Stale Terraform providers",
                    note: "Providers and modules in .terraform of Terraform and OpenTofu projects whose files and Git index were not modified for 90 days. Moved to the Trash; terraform init downloads them again. State files are kept",
                    paths: StaleProjects.folders, mode: .trash, selectedByDefault: false, showsWhenEmpty: false,
                    skipsOpenFiles: true,
                    skipsEntry: {
                        let busy = running(), cutoff = now().addingTimeInterval(-Double(StaleProjects.days) * 86_400)
                        return { url in
                            StaleProjects.isUsed(project(of: url), by: busy)
                                || lastWorkedOn(url, home: home).map { $0 >= cutoff } ?? true
                        }
                    },
                    entryLabel: { url in (label(url, home: home), lastWorkedOn(url, home: home)) },
                    selectableEntries: true,
                    findEntries: { roots, policy in
                        await StaleProjects.find(in: roots, policy: policy, hasFullDiskAccess: hasFullDiskAccess())
                            .filter { $0.deletingLastPathComponent().lastPathComponent == ".terraform" }
                    },
                    allowsEntry: { $0.allowsTerraformFolder($1) },
                    entrySizes: sizes)
    }

    static func project(of folder: URL) -> URL { folder.deletingLastPathComponent().deletingLastPathComponent() }

    /// `~/Developer/infra — .terraform/providers/`.
    static func label(_ folder: URL, home: URL) -> String {
        let project = project(of: folder).standardizedFileURL.path, homePath = home.standardizedFileURL.path
        let shown = project.hasPrefix(homePath + "/") ? "~" + project.dropFirst(homePath.count) : project
        return shown + " — .terraform/" + folder.lastPathComponent + "/"
    }

    /// Newest modification date of `folder`, the project's `*.tf` files and the `markers` of the project and each
    /// folder above it below `home`; nil when `folder` is gone. Not `.terraform`'s own date: trashing `providers`
    /// changes it, which would keep `modules` of the same project.
    static func lastWorkedOn(_ folder: URL, home: URL) -> Date? {
        guard var newest = StaleProjects.lastWorkedOn(folder, markers: markers, home: home) else { return nil }
        let project = project(of: folder).standardizedFileURL.path
        for name in StaleProjects.entries(of: project).keys where name.hasSuffix(".tf") || name.hasSuffix(".tofu") {
            var info = stat()
            guard lstat(project + "/" + name, &info) == 0 else { continue }
            newest = max(newest, Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) * 1e-9))
        }
        return newest
    }

    /// Plugin cache folders Terraform is told about: `TF_PLUGIN_CACHE_DIR` in this process's environment (the
    /// command line tool run from a shell) and `plugin_cache_dir = "<absolute path>"` in `~/.terraformrc`. Each is
    /// then checked like a shell folder (inside home, no symlink); the shell profile's variable is read by `shell:`.
    static func configuredPluginCaches(home: URL) -> [String] {
        var folders: [String] = []
        if let value = ProcessInfo.processInfo.environment["TF_PLUGIN_CACHE_DIR"], !value.isEmpty { folders.append(value) }
        if let text = try? String(contentsOf: home.appending(path: ".terraformrc"), encoding: .utf8) {
            folders += pluginCacheDirs(in: text)
        }
        return folders
    }

    /// Values of top-level `plugin_cache_dir = "…"` lines of a CLI config file.
    static func pluginCacheDirs(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == "plugin_cache_dir", parts[1].count > 2,
                  parts[1].hasPrefix("\""), parts[1].hasSuffix("\"") else { return nil }
            return String(parts[1].dropFirst().dropLast())
        }
    }
}
