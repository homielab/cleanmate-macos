import Foundation
import Testing
@testable import CleanMate

/// Haskell, Scala and OCaml package caches: a fake home in a throwaway folder; the real home is never read.
struct LanguagePackageCachesTests {
    let fm = FileManager.default
    let root = FileManager.default.temporaryDirectory.appending(path: "CleanMateLanguageCaches-\(UUID().uuidString)")
    var home: URL { root.appending(path: "home") }
    let ids = ["cabal-packages", "stack-cache", "ghcup-cache", "coursier-cache", "ivy-cache", "sbt-boot", "opam-download-cache"]

    func policy() -> SafetyPolicy { SafetyPolicy(home: home, temp: root.appending(path: "tmp")) }
    func item(_ id: String) throws -> CleanerItem { try #require(CleanerGroup.developer.items.first { $0.id == id }) }

    func write(_ path: String, bytes: Int = 4096) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
    }

    func listed(_ id: String) async throws -> [String] {
        let scan = await Scanner.scan(try item(id), policy: policy(), openPaths: { _ in [] })
        // `$TMPDIR` may be reached through /private: compare the part after the fake home.
        return scan.entries.compactMap { $0.url.path.components(separatedBy: "/home/").last }
    }

    @Test func itemsAreDeletedAndHiddenWhenEmpty() throws {
        for id in ids {
            let item = try item(id)
            #expect(item.mode == .delete && !item.showsWhenEmpty, "\(id)")
        }
        #expect(try !item("stack-cache").selectedByDefault && !item("coursier-cache").selectedByDefault)
        #expect(try item("cabal-packages").selectedByDefault && item("ivy-cache").selectedByDefault
                && item("sbt-boot").selectedByDefault && item("opam-download-cache").selectedByDefault)
    }

    /// Only the cache folders; compilers, installed tools, config, local publications and opam switches never.
    @Test func listsOnlyCacheFolders() async throws {
        defer { try? fm.removeItem(at: root) }
        for path in [".cabal/packages/hackage.haskell.org/aeson/aeson-2.2.tar.gz", ".cabal/bin/hlint", ".cabal/config",
                     ".cache/cabal/packages/hackage.haskell.org/01-index.tar",
                     ".stack/pantry/pantry.sqlite3", ".stack/snapshots/aarch64-osx/abc/lib/x", ".stack/programs/ghc-9.6/bin/ghc",
                     ".ghcup/cache/ghc-9.6.tar.xz", ".ghcup/ghc/9.6/bin/ghc", ".ghcup/bin/ghcup",
                     "Library/Caches/Coursier/v1/https/repo1.maven.org/x.jar",
                     ".ivy2/cache/org.scala-lang/scala-library/x.jar", ".ivy2/local/me/lib/1.0/x.jar",
                     ".sbt/boot/scala-2.12.18/lib/x.jar", ".sbt/1.0/global.sbt",
                     ".opam/download-cache/md5/ab/abc", ".opam/default/lib/x", ".opam/config"] {
            try write(path)
        }
        var all: [String] = []
        for id in ids {
            let entries = try await listed(id)
            #expect(!entries.isEmpty, "\(id)")
            all += entries
        }
        let roots = [".cabal/packages", ".cache/cabal/packages", ".stack/pantry", ".stack/snapshots", ".ghcup/cache",
                     "Library/Caches/Coursier", ".ivy2/cache", ".sbt/boot", ".opam/download-cache"]
        #expect(all.allSatisfy { path in roots.contains { path == $0 || path.hasPrefix($0 + "/") } }, "\(all)")
        for kept in [".cabal/bin", ".cabal/config", ".stack/programs", ".ghcup/ghc", ".ghcup/bin", ".ivy2/local",
                     ".sbt/1.0", ".opam/default", ".opam/config"] {
            #expect(!all.contains { $0 == kept || $0.hasPrefix(kept + "/") || kept.hasPrefix($0 + "/") }, "\(kept)")
        }
    }

    @Test func hiddenWhenAbsent() async throws {
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        for id in ids { #expect(try await listed(id).isEmpty, "\(id)") }
    }

    /// Folders moved with STACK_ROOT, CABAL_DIR, COURSIER_CACHE and OPAMROOT in the shell profile.
    @Test func readsFoldersFromTheShellProfile() async throws {
        defer { try? fm.removeItem(at: root) }
        for path in ["hs/stack/pantry/p", "hs/cabal/packages/hackage/x", "jvm/coursier/v1/x", "jvm/coursier/notes/x", "ml/opam/download-cache/x"] {
            try write(path)
        }
        let profile = "export STACK_ROOT=$HOME/hs/stack\nexport CABAL_DIR=$HOME/hs/cabal\n"
            + "export COURSIER_CACHE=$HOME/jvm/coursier\nexport OPAMROOT=$HOME/ml/opam\n"
        try profile.write(to: home.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        #expect(try await listed("stack-cache").contains { $0.hasPrefix("hs/stack/pantry") })
        #expect(try await listed("cabal-packages").contains { $0.hasPrefix("hs/cabal/packages") })
        let coursier = try await listed("coursier-cache")
        #expect(coursier.contains { $0.hasPrefix("jvm/coursier/v1") } && !coursier.contains { $0.hasPrefix("jvm/coursier/notes") })
        #expect(try await listed("opam-download-cache").contains { $0.hasPrefix("ml/opam/download-cache") })
    }

    @Test func skippedWhileItsToolRuns() throws {
        for (id, tool) in [("cabal-packages", "cabal"), ("stack-cache", "stack"), ("ghcup-cache", "ghc-9.6.4"),
                           ("coursier-cache", "cs"), ("ivy-cache", "sbt"), ("sbt-boot", "metals"), ("opam-download-cache", "opam")] {
            #expect(try item(id).runningBlocker(apps: [], processes: ["zsh", tool]) == tool, "\(id)")
            #expect(try item(id).runningBlocker(apps: [], processes: ["zsh", "node"]) == nil, "\(id)")
        }
        #expect(try item("opam-download-cache").runningBlocker(apps: [], processes: ["sbt"]) == nil)
    }
}
