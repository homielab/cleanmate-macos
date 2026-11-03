import AppKit
import Testing
@testable import CleanMate

/// The module and window frame kept across launches.
@MainActor
struct WindowStateTests {
    let suite = TestDefaults.suite("CleanMateWindowStateTests")
    var defaults: UserDefaults { UserDefaults(suiteName: suite)! }

    @Test func opensOnTheLastModule() {
        defer { TestDefaults.remove(suite) }
        #expect(ContentView.lastModule(defaults: defaults) == .overview) // first launch
        ContentView.remember(.largeFiles, defaults: defaults)
        #expect(ContentView.lastModule(defaults: defaults) == .largeFiles)
        ContentView.remember(nil, defaults: defaults) // nothing selected: keeps the last one
        #expect(ContentView.lastModule(defaults: defaults) == .largeFiles)
        defaults.set("removedModule", forKey: Preferences.lastModule)
        #expect(ContentView.lastModule(defaults: defaults) == .overview)
    }

    static let main = CGRect(x: 0, y: 0, width: 1440, height: 875)
    static let side = CGRect(x: 1440, y: 0, width: 1920, height: 1055)

    @Test func savedFrameComesBackOnTheScreenItWasOn() {
        let frame = CGRect(x: 1600, y: 100, width: 1200, height: 800)
        #expect(WindowFrameKeeperView.restoredFrame(NSStringFromRect(frame), screens: [Self.main, Self.side]) == frame)
    }

    @Test func savedFrameIsMovedAndShrunkToFitItsScreen() {
        let frame = CGRect(x: 600, y: -50, width: 1000, height: 1000) // mostly on the main screen, partly off it
        let restored = WindowFrameKeeperView.restoredFrame(NSStringFromRect(frame), screens: [Self.main, Self.side])
        #expect(restored == CGRect(x: 440, y: 0, width: 1000, height: 875))
    }

    @Test func frameOfADisconnectedScreenIsCentredOnTheMainScreen() {
        let frame = CGRect(x: 5000, y: 0, width: 1000, height: 600)
        let restored = WindowFrameKeeperView.restoredFrame(NSStringFromRect(frame), screens: [Self.main])
        #expect(restored == CGRect(x: 220, y: 137.5, width: 1000, height: 600))
    }

    @Test func nothingUsableSavedKeepsTheDefaultSize() {
        #expect(WindowFrameKeeperView.restoredFrame(nil, screens: [Self.main]) == nil)
        #expect(WindowFrameKeeperView.restoredFrame("garbage", screens: [Self.main]) == nil)
        #expect(WindowFrameKeeperView.restoredFrame(NSStringFromRect(CGRect(x: 0, y: 0, width: 800, height: 600)), screens: []) == nil)
    }
}
