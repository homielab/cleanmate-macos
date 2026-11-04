import Foundation
import Testing
@testable import CleanMate

/// Overview and Space Lens say why a folder has no size: "Not readable" (macOS won't list it), "Cancelled" (Stop came
/// first, Measure Again measures it), "Couldn’t measure" (anything else); a folder gone since the listing is dropped.
/// None of them counts in the totals.
@Suite(.timeLimit(.minutes(2)))
struct MeasureFailureTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "CleanMateMeasureFailure-\(UUID().uuidString)")
    var home: URL { root.appending(path: "home") }

    func file(_ path: String, bytes: Int = 10) throws {
        let url = home.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
    }

    /// Runs until cancelled (at most a minute), checking for cancellation like `SpaceLens.measure`.
    @Sendable static func untilCancelled() async throws {
        for _ in 0..<60_000 {
            try Task.checkCancellation()
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func failuresAreClassifiedFromTheErrorAndTheFolder() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try file("open/x.bin")
        try file("locked/x.bin")
        let open = home.appending(path: "open"), locked = home.appending(path: "locked")
        #expect(chmod(locked.path, 0) == 0)
        defer { chmod(locked.path, 0o755) }
        typealias Failure = SpaceLens.MeasureFailure
        #expect(Failure(CancellationError(), at: open) == .cancelled)
        #expect(Failure(Failure.notFound, at: open) == .notFound)
        #expect(Failure(CocoaError(.fileReadUnknown), at: home.appending(path: "gone")) == .notFound)
        #expect(Failure(CocoaError(.fileReadUnknown), at: locked) == .notReadable)
        #expect(Failure(POSIXError(.EACCES), at: open) == .notReadable)
        #expect(Failure(POSIXError(.EPERM), at: open) == .notReadable)
        #expect(Failure(CocoaError(.fileReadUnknown), at: open) == .other)
    }

    // MARK: Overview

    @MainActor func overview(_ measure: @escaping @Sendable (URL) async throws -> Int64) -> OverviewModel {
        let model = OverviewModel(center: NotificationCenter())
        model.home = home
        model.hasFullDiskAccess = { true }
        model.readDisks = { [] }
        model.measure = { url, _, _ in (try await measure(url), [:]) }
        return model
    }

    /// A chmod 000 folder is "Not readable", never measured nor counted; nothing says "Couldn’t measure" or "Cancelled".
    @MainActor @Test func overviewSaysAFolderIsNotReadable() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try file("Open/x.bin")
        try file("Locked/x.bin")
        let locked = home.appending(path: "Locked")
        #expect(chmod(locked.path, 0) == 0)
        defer { chmod(locked.path, 0o755) }
        let measured = Locked([String]())
        let model = overview { url in
            measured.withLock { $0.append(url.lastPathComponent) }
            return 4_000
        }
        model.startIfNeeded()
        try await eventually("the measure to end") { !model.measuring }
        #expect(model.unreadableFolders == ["Locked"])
        #expect(model.unmeasuredFolders.isEmpty && model.cancelledFolders == nil)
        #expect(measured.withLock { $0 } == ["Open"] && model.homeSize == 4_000)
    }

    /// A measure failing with a permission error is "Not readable"; any other error is "Couldn’t measure"; neither counts.
    @MainActor @Test func overviewTellsPermissionErrorsFromOthers() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Good", "Denied", "Broken"] { try file("\(name)/x.bin") }
        let model = overview { url in
            switch url.lastPathComponent {
            case "Denied": throw POSIXError(.EACCES)
            case "Broken": throw CocoaError(.fileReadUnknown)
            default: return 4_000
            }
        }
        model.startIfNeeded()
        try await eventually("the measure to end") { !model.measuring }
        #expect(model.unreadableFolders == ["Denied"] && model.unmeasuredFolders == ["Broken"])
        #expect(model.cancelledFolders == nil && model.homeSize == 4_000)
        #expect(model.folders.map(\.name) == ["Good"])
    }

    /// Stop lists the folders not measured yet as "Cancelled" (not "Couldn’t measure"); Measure Again measures them.
    @MainActor @Test func overviewStopSaysCancelledAndMeasureAgainFinishes() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try file("Fast/x.bin")
        try file("Slow/x.bin")
        let slow = Locked(true)
        let model = overview { url in
            if url.lastPathComponent == "Slow", slow.withLock({ $0 }) { try await Self.untilCancelled() }
            return url.lastPathComponent == "Slow" ? 7_000 : 3_000
        }
        model.startIfNeeded()
        try await eventually("Fast to be measured") { model.progress?.done == 1 }
        model.cancel()
        #expect(!model.measuring && model.cancelledFolders == ["Slow"])
        #expect(model.unmeasuredFolders.isEmpty && model.unreadableFolders.isEmpty)

        slow.withLock { $0 = false }
        model.measureAgain()
        #expect(model.measuring && model.cancelledFolders == nil)
        try await eventually("the measure to end") { !model.measuring }
        #expect(model.cancelledFolders == nil && model.unmeasuredFolders.isEmpty)
        #expect(model.folders.map(\.name) == ["Slow", "Fast"] && model.homeSize == 10_000)
    }

    /// Stop before any folder is measured: "Cancelled" for all of them.
    @MainActor @Test func overviewStopBeforeAnyFolderListsThemAll() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try file("A/x.bin")
        try file("B/x.bin")
        let entered = SignalCount()
        let model = overview { _ in
            entered.add()
            try await Self.untilCancelled()
            return 1
        }
        model.startIfNeeded()
        await entered.reach(2)
        model.cancel()
        #expect(model.cancelledFolders?.sorted() == ["A", "B"])
    }

    // MARK: Space Lens

    /// Stop marks the folders not measured yet "Cancelled" with Measure Again; it measures only those, keeping the
    /// sizes already found.
    @MainActor @Test func spaceLensStopSaysCancelledAndMeasureAgainFinishes() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try file("A/Fast/x.bin")
        try file("A/Slow/x.bin")
        let slow = Locked(true), calls = Locked([String]())
        let model = SpaceLensModel(center: NotificationCenter())
        model.disk = home.appending(path: "A")
        model.hasFullDiskAccess = { true }
        model.measure = { url, _, _ in
            calls.withLock { $0.append(url.lastPathComponent) }
            if url.lastPathComponent == "Slow", slow.withLock({ $0 }) { try await Self.untilCancelled() }
            return (url.lastPathComponent == "Slow" ? 7_000 : 3_000, [:])
        }
        model.start(at: home.appending(path: "A"))
        func item(_ name: String) -> SpaceItem? { model.items.first { $0.url.lastPathComponent == name } }
        try await eventually("Fast to be measured") { item("Fast")?.size != nil }
        #expect(!model.hasCancelled)
        model.cancel()
        #expect(item("Slow")?.isCancelled == true && item("Slow")?.size == nil)
        #expect(item("Fast")?.size == 3_000 && item("Fast")?.failure == nil)
        #expect(model.hasCancelled && !model.measuring)

        slow.withLock { $0 = false }
        model.measureAgain()
        try await eventually("the measure to end") { !model.measuring }
        #expect(item("Slow")?.size == 7_000 && item("Fast")?.size == 3_000 && !model.hasCancelled)
        #expect(calls.withLock { $0 }.sorted() == ["Fast", "Slow", "Slow"])
    }

    /// Space Lens: a permission error is "Not Readable", any other error "Couldn’t Measure"; neither is "Cancelled".
    @MainActor @Test func spaceLensTellsPermissionErrorsFromOthers() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Good", "Denied", "Broken"] { try file("A/\(name)/x.bin") }
        let model = SpaceLensModel(center: NotificationCenter())
        model.disk = home.appending(path: "A")
        model.hasFullDiskAccess = { true }
        model.measure = { url, _, _ in
            switch url.lastPathComponent {
            case "Denied": throw POSIXError(.EPERM)
            case "Broken": throw CocoaError(.fileReadUnknown)
            default: return (4_000, [:])
            }
        }
        model.start(at: home.appending(path: "A"))
        try await eventually("the measure to end") { !model.measuring }
        func item(_ name: String) -> SpaceItem? { model.items.first { $0.url.lastPathComponent == name } }
        #expect(item("Denied")?.isUnreadable == true && item("Broken")?.failure == .other)
        #expect(item("Good")?.size == 4_000 && !model.hasCancelled)
        #expect(model.total == 4_000)
    }
}
