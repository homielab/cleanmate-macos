import Foundation
import Testing
@testable import CleanMate

/// Old Vagrant box versions in a fake home; the real home is never read.
final class VagrantBoxesTests {
    let fm = FileManager.default
    let root = TestTemp.url("CleanMateVagrant")
    var home: URL { root.appending(path: "home") }
    deinit { try? FileManager.default.removeItem(at: root) }

    func policy() -> SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }

    func box(_ vagrantHome: String, _ name: String, _ versions: [String], provider: String = "virtualbox") throws {
        for version in versions {
            let file = home.appending(path: "\(vagrantHome)/boxes/\(name)/\(version)/\(provider)/box.vmdk")
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4096).write(to: file)
        }
    }

    func index(_ vagrantHome: String, _ text: String) throws {
        let url = home.appending(path: "\(vagrantHome)/data/machine-index/index")
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func listed() async -> [String] {
        let scan = await Scanner.scan(VagrantBoxes.item(sizes: FolderSizeCache(file: nil)), policy: policy(), openPaths: { _ in [] })
        return scan.entries.compactMap { $0.url.path.components(separatedBy: "/home/").last }.sorted()
    }

    @Test func itemInTheDeveloperGroup() throws {
        let item = try #require(CleanerGroup.developer.items.first { $0.id == VagrantBoxes.id })
        #expect(item.mode == .delete && !item.selectedByDefault && item.selectableEntries && !item.showsWhenEmpty)
        #expect(item.runningBlocker(apps: [], processes: ["zsh", "vagrant"]) == "vagrant")
        #expect(item.runningBlocker(apps: [], processes: ["zsh", "ruby"]) == nil)
    }

    /// Old versions are listed; the newest (compared part by part: 1.10 > 1.9) and the one a machine uses are not.
    @Test func listsOldVersionsOnly() async throws {
        try box(".vagrant.d", "hashicorp-VAGRANTSLASH-bionic64", ["1.0.1", "1.9.0", "1.10.0"])
        try box(".vagrant.d", "generic-VAGRANTSLASH-alpine", ["4.2.0", "4.3.0", "4.10.0"], provider: "parallels")
        try box(".vagrant.d", "single", ["0"])
        try index(".vagrant.d", """
        {"version":1,"machines":{"abc":{"name":"default","provider":"virtualbox",
         "extra_data":{"box":{"name":"hashicorp/bionic64","provider":"virtualbox","version":"1.0.1"}}}}}
        """)
        #expect(await listed() == [".vagrant.d/boxes/generic-VAGRANTSLASH-alpine/4.2.0",
                                   ".vagrant.d/boxes/generic-VAGRANTSLASH-alpine/4.3.0",
                                   ".vagrant.d/boxes/hashicorp-VAGRANTSLASH-bionic64/1.9.0"])
        let entry = home.appending(path: ".vagrant.d/boxes/generic-VAGRANTSLASH-alpine/4.2.0")
        #expect(VagrantBoxes.label(of: entry)?.title == "generic/alpine 4.2.0 (parallels)")
        #expect(VagrantBoxes.allows(entry, policy: policy()))
        #expect(!VagrantBoxes.allows(home.appending(path: ".vagrant.d/boxes/generic-VAGRANTSLASH-alpine/4.10.0"), policy: policy()))
        #expect(!VagrantBoxes.allows(home.appending(path: ".vagrant.d/boxes/hashicorp-VAGRANTSLASH-bionic64/1.0.1"), policy: policy()))
    }

    @Test func brokenIndexListsNothing() async throws {
        try box(".vagrant.d", "old", ["1.0", "2.0"])
        try index(".vagrant.d", "{not json")
        #expect(await listed().isEmpty)
        #expect(!VagrantBoxes.allows(home.appending(path: ".vagrant.d/boxes/old/1.0"), policy: policy()))
    }

    @Test func noIndexListsOldVersions() async throws {
        try box(".vagrant.d", "old", ["1.0", "2.0"])
        #expect(await listed() == [".vagrant.d/boxes/old/1.0"])
    }

    @Test func readsVagrantHomeFromTheShellProfile() async throws {
        try box("vm/vagrant", "old", ["1.0", "2.0"])
        try "export VAGRANT_HOME=$HOME/vm/vagrant\n".write(to: home.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        #expect(await listed() == ["vm/vagrant/boxes/old/1.0"])
    }

    @Test func hiddenWhenAbsent() async throws {
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        #expect(await listed().isEmpty)
    }
}
