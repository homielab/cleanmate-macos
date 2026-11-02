import Foundation
import Testing
@testable import CleanMate

/// Terraform providers of stale projects and the infrastructure tool caches: a fake home in a throwaway folder and a
/// fake Trash; the real home is never read.
struct StaleTerraformTests {
    let fm = FileManager.default
    let root = FileManager.default.temporaryDirectory.appending(path: "CleanMateTerraform-\(UUID().uuidString)")
    var home: URL { root.appending(path: "home") }
    var developer: URL { home.appending(path: "Developer") }
    let old = Date.now.addingTimeInterval(-100 * 86_400)

    func policy() -> SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }
    func item(running: [String] = []) -> CleanerItem {
        StaleTerraform.item(home: home, hasFullDiskAccess: { true }, running: { running })
    }

    func write(_ url: URL, bytes: Int = 4096, date: Date? = nil) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        if let date { try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
    }

    /// A Terraform project at `path` with providers, modules and state, everything dated 100 days ago.
    func terraform(_ path: String) throws {
        let project = developer.appending(path: path)
        for (file, size) in ["main.tf": 100, ".terraform.lock.hcl": 100, "terraform.tfstate": 500,
                             ".terraform/terraform.tfstate": 300, ".terraform/environment": 10,
                             ".terraform/providers/registry.terraform.io/hashicorp/aws/5.0.0/darwin_arm64/terraform-provider-aws": 90_000,
                             ".terraform/modules/vpc/main.tf": 2_000, ".terraform/modules/modules.json": 100] {
            try write(project.appending(path: file), bytes: size, date: old)
        }
        for folder in [".terraform/providers", ".terraform/modules", ".terraform"] {
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: project.appending(path: folder).path)
        }
    }

    @Test func itemsInTheDeveloperGroup() throws {
        let items = CleanerGroup.developer.items
        let index = try #require(items.firstIndex { $0.id == "stale-terraform-providers" })
        #expect(items[index - 1].id == "stale-build-dirs")
        let stale = items[index]
        #expect(stale.mode == .trash && !stale.selectedByDefault && stale.selectableEntries && stale.findEntries != nil)
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let plugins = try #require(byID["terraform-plugin-cache"]), minikube = try #require(byID["minikube-cache"])
        let helm = try #require(byID["helm-cache"])
        #expect(plugins.mode == .delete && !plugins.selectedByDefault && plugins.paths == ["~/.terraform.d/plugin-cache"])
        #expect(plugins.runningProcessNames.contains("tofu") && plugins.shellFolders["TF_PLUGIN_CACHE_DIR"] == [""])
        #expect(plugins.included == ["[!.]*.*"] && plugins.skipsEntry != nil && plugins.configFolders != nil)
        #expect(minikube.mode == .delete && !minikube.selectedByDefault && minikube.paths == ["~/.minikube/cache"])
        #expect(minikube.runningProcessNames.contains("minikube"))
        #expect(helm.mode == .delete && helm.selectedByDefault && helm.paths == ["~/Library/Caches/helm"])
        #expect(helm.runningProcessNames == ["helm"] && helm.included == ["repository", "content"])
        #expect(StaleTerraform.isTool("terraform") && StaleTerraform.isTool("tofu")
                && StaleTerraform.isTool("terraform-provider-aws_v5.0.0") && !StaleTerraform.isTool("node"))
    }

    /// Only `.terraform/providers` and `.terraform/modules` of an old project are listed, never state files; a
    /// project changed recently or one Terraform runs in is not.
    @Test func listsOnlyProvidersAndModulesOfStaleProjects() async throws {
        defer { try? fm.removeItem(at: root) }
        try terraform("infra")
        try terraform("recent")
        try write(developer.appending(path: "recent/main.tf"), bytes: 100, date: .now.addingTimeInterval(-5 * 86_400))
        try terraform("busy")
        try write(developer.appending(path: "no-tf/.terraform/providers/x"), date: old) // no *.tf file next to it

        let scan = await Scanner.scan(item(running: [developer.appending(path: "busy").path]), policy: policy(),
                                      openPaths: EndToEndCleanTests.ownOpenPaths)
        let expected = ["infra/.terraform/providers", "infra/.terraform/modules"].map { developer.appending(path: $0).path }
        #expect(Set(scan.entries.map(\.url.path)) == Set(expected))
        #expect(Set(scan.entries.compactMap(\.title))
                == ["~/Developer/infra — .terraform/providers/", "~/Developer/infra — .terraform/modules/"])

        let trash = root.appending(path: "Trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let report = await Cleaner.clean(item(), scan: scan, policy: policy(), trash: { url in
            let target = trash.appending(path: UUID().uuidString)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }, openPaths: EndToEndCleanTests.ownOpenPaths)
        #expect(report.trashed.count == 2 && report.skipped == 0)
        for kept in ["main.tf", "terraform.tfstate", ".terraform.lock.hcl", ".terraform/terraform.tfstate", ".terraform/environment"] {
            #expect(fm.fileExists(atPath: developer.appending(path: "infra/" + kept).path))
        }
        #expect(!fm.fileExists(atPath: developer.appending(path: "infra/.terraform/providers").path))
    }

    @Test func policyAllowsOnlyProvidersAndModules() throws {
        defer { try? fm.removeItem(at: root) }
        try terraform("infra")
        let policy = policy()
        func allows(_ path: String) -> Bool { policy.allowsTerraformFolder(developer.appending(path: path)) }
        #expect(allows("infra/.terraform/providers") && allows("infra/.terraform/modules"))
        #expect(!allows("infra/.terraform") && !allows("infra/.terraform/terraform.tfstate") && !allows("infra"))
        #expect(!allows("infra/.terraform/modules/vpc"))
        #expect(!policy.allowsBuildFolder(developer.appending(path: "infra/.terraform/providers")))
        try fm.removeItem(at: developer.appending(path: "infra/main.tf"))
        #expect(!allows("infra/.terraform/providers"))
    }

    /// A plugin cache folder set to the wrong place (here a project folder named in ~/.terraformrc) lists only its
    /// registry host folders; its files, other folders, hidden folders and symlinks are never listed nor removed.
    @Test func pluginCacheListsOnlyRegistryHostFolders() async throws {
        defer { try? fm.removeItem(at: root) }
        let plugins = try #require(CleanerGroup.developer.items.first { $0.id == "terraform-plugin-cache" })
        let configured = home.appending(path: "work/infra")
        let provider = "hashicorp/aws/5.0.0/darwin_arm64/terraform-provider-aws"
        try write(home.appending(path: ".terraform.d/plugin-cache/registry.terraform.io/\(provider)"))
        try write(home.appending(path: ".terraform.d/plugin-cache/notes.txt"))
        try write(configured.appending(path: "registry.opentofu.org/\(provider)"))
        let kept = try ["main.tf", "report.pdf", "README", "docs/guide.md", "backup.d/state.json", ".git/HEAD",
                        ".cache.d/x"].map { name in
            let url = configured.appending(path: name)
            try write(url)
            return url
        }
        try write(home.appending(path: "elsewhere/x"))
        try fm.createSymbolicLink(at: configured.appending(path: "mirror.example.com"),
                                  withDestinationURL: home.appending(path: "elsewhere"))
        try "plugin_cache_dir = \"\(configured.path)\"\n".write(to: home.appending(path: ".terraformrc"),
                                                                  atomically: true, encoding: .utf8)
        let noOpenFiles: OpenPaths = { _ in [] }
        let scan = await Scanner.scan(plugins, policy: policy(), openPaths: noOpenFiles)
        #expect(Set(scan.entries.map(\.url.lastPathComponent)) == ["registry.terraform.io", "registry.opentofu.org"])

        // Entries the scan never lists are refused at clean too.
        let forged = ItemScan(entries: (kept + [configured.appending(path: "mirror.example.com")]).map {
            ScanEntry(url: $0.deletingLastPathComponent() == configured ? $0 : $0.deletingLastPathComponent(), size: 1)
        } + scan.entries)
        _ = await Cleaner.clean(plugins, scan: forged, policy: policy(), openPaths: noOpenFiles)
        #expect(kept.allSatisfy { fm.fileExists(atPath: $0.path) })
        #expect(fm.fileExists(atPath: home.appending(path: "elsewhere/x").path))
        #expect(!fm.fileExists(atPath: configured.appending(path: "registry.opentofu.org").path))
        #expect(!fm.fileExists(atPath: home.appending(path: ".terraform.d/plugin-cache/registry.terraform.io").path))
        #expect(fm.fileExists(atPath: home.appending(path: ".terraform.d/plugin-cache/notes.txt").path))
    }

    /// Helm: only `repository` and `content` of its cache, also when `HELM_CACHE_HOME` names another folder; the
    /// sources of plugins installed from git (`plugins`) and unrelated files are never listed.
    @Test func helmCacheListsOnlyRepositoryAndContent() async throws {
        defer { try? fm.removeItem(at: root) }
        let helm = try #require(CleanerGroup.developer.items.first { $0.id == "helm-cache" })
        for file in ["Library/Caches/helm/repository/bitnami-index.yaml", "Library/Caches/helm/plugins/abc/plugin.yaml",
                     "work/helm/content/sha256/x", "work/helm/notes.txt", "work/helm/charts/app/Chart.yaml"] {
            try write(home.appending(path: file))
        }
        try "export HELM_CACHE_HOME=$HOME/work/helm\n".write(to: home.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        let scan = await Scanner.scan(helm, policy: policy(), openPaths: { _ in [] })
        let listed = scan.entries.map(\.url.path)
        #expect(listed.count == 2 && listed.contains { $0.hasSuffix("/home/Library/Caches/helm/repository") }
                && listed.contains { $0.hasSuffix("/home/work/helm/content") }, "\(listed)")
    }

    @Test func readsPluginCacheDirFromTheCLIConfig() {
        let text = """
        plugin_cache_dir = "/Users/me/tf-cache"
        # plugin_cache_dir = "/nope"
        disable_checkpoint = true
        """
        #expect(StaleTerraform.pluginCacheDirs(in: text) == ["/Users/me/tf-cache"])
    }
}
