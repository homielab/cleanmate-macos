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
        #expect(minikube.mode == .delete && !minikube.selectedByDefault && minikube.paths == ["~/.minikube/cache"])
        #expect(minikube.runningProcessNames.contains("minikube"))
        #expect(helm.mode == .delete && helm.selectedByDefault && helm.paths == ["~/Library/Caches/helm"])
        #expect(helm.runningProcessNames == ["helm"])
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

    @Test func readsPluginCacheDirFromTheCLIConfig() {
        let text = """
        plugin_cache_dir = "/Users/me/tf-cache"
        # plugin_cache_dir = "/nope"
        disable_checkpoint = true
        """
        #expect(StaleTerraform.pluginCacheDirs(in: text) == ["/Users/me/tf-cache"])
    }
}
