import AppKit
import Combine
import SwiftUI
import Testing
@testable import CleanMate

/// Dynamic Reduce Motion tracking across screens (Overview, Smart Scan and Privacy results):
/// Views read `@Environment(\.accessibilityReduceMotion)` at animation runtime rather than caching at init.
/// When Reduce Motion is turned on while a screen is already open, any running animation ends immediately at its final
/// state; subsequent displays show still content with no motion.
@MainActor
struct ReduceMotionTests {
    final class MotionHostState: ObservableObject {
        @Published var reduceMotion = false
        @Published var displayID = UUID()
        @Published var capturedGrown: Bool?
        @Published var capturedCounting: Bool?
        @Published var capturedRevealed: Bool?
    }

    struct GrowsInTestView: View {
        @ObservedObject var state: MotionHostState

        var body: some View {
            GrowsIn(animates: true, onGrownChange: { state.capturedGrown = $0 }) { _ in
                Color.clear
            }
            .id(state.displayID)
            .environment(\._accessibilityReduceMotion, state.reduceMotion)
        }
    }

    struct CountingBytesTestView: View {
        @ObservedObject var state: MotionHostState
        let value: Int64

        var body: some View {
            CountingBytes(value, countsUp: true, onCountingChange: { state.capturedCounting = $0 })
                .id(state.displayID)
                .environment(\._accessibilityReduceMotion, state.reduceMotion)
        }
    }

    struct DoneScreenTestView: View {
        @ObservedObject var state: MotionHostState
        @ObservedObject var model: SmartScanModel
        let module: Module
        let report: CleanReport

        var body: some View {
            DoneScreen(model: model, module: module, report: report, onRevealedChange: { state.capturedRevealed = $0 }) {
                EmptyView()
            }
            .id(state.displayID)
            .environment(\._accessibilityReduceMotion, state.reduceMotion)
        }
    }

    private func mount<V: View>(_ view: V) -> (NSWindow, NSHostingView<V>) {
        let size = CGSize(width: 400, height: 300)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    // MARK: - GrowsIn

    @Test func growsInWithInjectedReduceMotionIsGrownFromStart() {
        let state = MotionHostState()
        state.reduceMotion = true
        let (window, host) = mount(GrowsInTestView(state: state))
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        #expect(state.capturedGrown == true)
    }

    @Test func growsInTogglingReduceMotionWhileOpenSnapsToGrown() async throws {
        let state = MotionHostState()
        state.reduceMotion = false
        let (window, host) = mount(GrowsInTestView(state: state))
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        #expect(state.capturedGrown == true)

        state.reduceMotion = true
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        #expect(state.capturedGrown == true)

        // Subsequent display
        state.displayID = UUID()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        #expect(state.capturedGrown == true)
    }

    // MARK: - CountingBytes

    @Test func countingBytesWithInjectedReduceMotionDoesNotCountUp() {
        let state = MotionHostState()
        state.reduceMotion = true
        let (window, host) = mount(CountingBytesTestView(state: state, value: 5_000_000))
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        #expect(state.capturedCounting == false)
    }

    @Test func countingBytesTogglingReduceMotionWhileOpenEndsCountUp() async throws {
        let state = MotionHostState()
        state.reduceMotion = false
        let (window, host) = mount(CountingBytesTestView(state: state, value: 5_000_000))
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        #expect(state.capturedCounting == true)

        // Turn on Reduce Motion while open / counting
        state.reduceMotion = true
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        #expect(state.capturedCounting == false)

        // Next display: no animation
        state.displayID = UUID()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        #expect(state.capturedCounting == false)
    }

    // MARK: - DoneScreen (Smart Scan / Privacy)

    @Test func smartScanDoneScreenWithReduceMotionIsRevealedFromStart() {
        let model = SmartScanModel(module: .smartScan) { [] }
        model.revealsDone = true
        let state = MotionHostState()
        state.reduceMotion = true
        let report = CleanReport(freed: 1_000_000)
        let (window, host) = mount(DoneScreenTestView(state: state, model: model, module: .smartScan, report: report))
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        #expect(state.capturedRevealed == true)
    }

    @Test func smartScanDoneScreenTogglingReduceMotionWhileOpenSnapsToRevealed() async throws {
        let model = SmartScanModel(module: .smartScan) { [] }
        model.revealsDone = true
        let state = MotionHostState()
        state.reduceMotion = false
        let report = CleanReport(freed: 1_000_000)
        let (window, host) = mount(DoneScreenTestView(state: state, model: model, module: .smartScan, report: report))
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        #expect(state.capturedRevealed == true)

        // Turn on Reduce Motion while open
        state.reduceMotion = true
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        #expect(state.capturedRevealed == true)

        // Next clean / display with Reduce Motion
        model.revealsDone = true
        state.displayID = UUID()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        #expect(state.capturedRevealed == true)
    }

    @Test func privacyDoneScreenWithReduceMotionIsRevealedFromStart() {
        let model = SmartScanModel(module: .privacy) { [] }
        model.revealsDone = true
        let state = MotionHostState()
        state.reduceMotion = true
        let report = CleanReport(freed: 0)
        let (window, host) = mount(DoneScreenTestView(state: state, model: model, module: .privacy, report: report))
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        #expect(state.capturedRevealed == true)
    }
}
