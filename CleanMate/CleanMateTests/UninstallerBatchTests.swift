import Foundation
import Testing
@testable import CleanMate

/// Uninstalling several ticked apps at once, with a fake Trash: nothing real is moved or uninstalled.
@MainActor
struct UninstallerBatchTests {
    static func app(_ name: String) -> InstalledApp {
        InstalledApp(url: URL(filePath: "/nonexistent/\(name).app"), name: name, bundleID: "com.test.batch.\(name.lowercased())",
                     version: nil, lastUsed: nil)
    }

    static let library = URL(filePath: "/nonexistent/home/Library")

    /// Each app has data surely its own, a "Possibly related" folder and config in the home folder.
    static func entries(of app: InstalledApp) -> [AppDataEntry] {
        [AppDataEntry(url: library.appending(path: "Caches/\(app.bundleID)"), size: 10),
         AppDataEntry(url: library.appending(path: "Application Support/\(app.name)Extra"), size: 20, kind: .suggested),
         AppDataEntry(url: URL(filePath: "/nonexistent/home/.config/\(app.name.lowercased())"), size: 30, kind: .config)]
    }

    /// A model listing `apps` whose fake Trash remembers each call (app, data) and fails as `errors` says.
    @MainActor final class Fake {
        var calls: [(URL?, [URL])] = []
        var errors: [URL: Uninstaller.AppTrashError] = [:]
        var dataLoads = 0

        func model(_ apps: [InstalledApp], running: Set<String> = []) -> UninstallerModel {
            let model = UninstallerModel()
            model.apps = apps
            model.appSizes = Dictionary(uniqueKeysWithValues: apps.map { ($0.url, 100) })
            model.runningApps = running
            model.appBundleIDs = { running }
            model.appData = { app, _, _ in
                self.dataLoads += 1
                return UninstallerBatchTests.entries(of: app)
            }
            model.trash = { app, data throws(Uninstaller.AppTrashError) in
                self.calls.append((app, data.map(\.url)))
                if let app, let error = self.errors[app] { throw error }
                return CleanReport(freed: 100 + data.reduce(0) { $0 + $1.size })
            }
            return model
        }
    }

    /// 3 apps ticked, 1 open: the 2 others go with their `.data` only, the open one stays with its reason.
    @Test func openAppIsSkippedOthersGoWithTheirDataOnly() async throws {
        let (a, b, c) = (Self.app("Alpha"), Self.app("Bravo"), Self.app("Charlie"))
        let fake = Fake()
        let model = fake.model([a, b, c], running: [b.bundleID])
        model.appTicks = [a.url, b.url, c.url]
        await model.loadBatch()
        #expect(model.batchSize == Int64(2 * 110)) // the open app is not counted
        await model.removeBatch()
        #expect(fake.calls.map(\.0) == [a.url, c.url])
        #expect(fake.calls[0].1 == [Self.library.appending(path: "Caches/\(a.bundleID)")])
        #expect(fake.calls[1].1 == [Self.library.appending(path: "Caches/\(c.bundleID)")])
        guard case .batch(let result)? = model.outcome else { Issue.record("no batch outcome"); return }
        #expect(result.removed.map(\.url) == [a.url, c.url])
        #expect(result.skipped.map(\.app.url) == [b.url] && result.skipped.map(\.reason) == [.running])
        #expect(result.report.freed == 220)
        #expect(model.apps == [b] && model.appTicks == [b.url])
        #expect(!model.working && !model.batchMode)
        let message = UninstallerView.batchMessage(result)
        #expect(message.contains("Bravo"))
    }

    /// An app locked in Finder or refused by the Trash doesn't stop the next one; each keeps its reason.
    @Test func aFailingAppDoesNotStopTheOthers() async {
        let (a, b, c) = (Self.app("Alpha"), Self.app("Bravo"), Self.app("Charlie"))
        let fake = Fake()
        fake.errors = [a.url: .locked, b.url: .notTrashed]
        let model = fake.model([a, b, c])
        model.appTicks = [a.url, b.url, c.url]
        await model.removeBatch() // data not loaded yet: loaded on the way, still only `.data`
        #expect(fake.calls.map(\.0) == [a.url, b.url, c.url])
        #expect(fake.calls.allSatisfy { $0.1.count == 1 })
        guard case .batch(let result)? = model.outcome else { Issue.record("no batch outcome"); return }
        #expect(result.removed.map(\.url) == [c.url])
        #expect(result.skipped.map(\.reason) == [.locked, .notTrashed])
        #expect(model.apps == [a, b] && model.appTicks == [a.url, b.url])
    }

    /// Ticks survive changing the selection; a second tick replaces an app's detail with the batch panel;
    /// one tick keeps the usual detail.
    @Test func ticksAndBatchMode() {
        let (a, b) = (Self.app("Alpha"), Self.app("Bravo"))
        let model = Fake().model([a, b])
        model.selection = .app(a.url)
        model.appTicks.insert(a.url)
        #expect(!model.batchMode && model.selection == .app(a.url))
        model.appTicks.insert(b.url)
        #expect(model.batchMode && model.selection == nil)
        model.selection = .app(b.url) // "Show Files" of one app keeps the ticks
        #expect(model.appTicks == [a.url, b.url] && model.selection == .app(b.url))
        model.selection = .leftovers
        #expect(model.appTicks == [a.url, b.url])
    }

    /// The header checkbox ticks and unticks the listed apps only; ticks of apps the search hides stay.
    @Test func headerTicksListedApps() {
        let (a, b, c) = (Self.app("Alpha"), Self.app("Bravo"), Self.app("Charlie"))
        let model = Fake().model([a, b, c])
        model.appTicks = [c.url]
        model.search = "alpha"
        model.tickListed(true)
        #expect(model.appTicks == [a.url, c.url])
        model.tickListed(false)
        #expect(model.appTicks == [c.url])
        #expect(model.tickedApps == [c])
    }

    /// Nothing ticked or busy: nothing moves.
    @Test func nothingTickedMovesNothing() async {
        let fake = Fake()
        let model = fake.model([Self.app("Alpha")])
        await model.removeBatch()
        #expect(fake.calls.isEmpty && model.outcome == nil)
    }
}
