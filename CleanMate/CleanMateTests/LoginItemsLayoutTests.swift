import AppKit
import SwiftUI
import Testing
@testable import CleanMate

/// The header note once made Login Items' ideal height explode, which blanked the sidebar and pushed the screen off
/// the window. Sample agents only; nothing real is scanned or changed.
@MainActor
struct LoginItemsLayoutTests {
    @Test func loginItemsFitsTheMinimumWindow() async throws {
        let agents = (0..<12).map { i in
            LaunchAgent(url: URL(fileURLWithPath: "/Users/Shared/Sample/LaunchAgents/com.example.\(i).plist"), label: "com.example.\(i)",
                        scope: i < 8 ? .user : .systemDaemon, program: "/usr/local/bin/tool\(i)", programMissing: false, owner: nil, state: .loaded)
        }
        let model = LaunchAgentsModel()
        model.scan = { agents }
        let host = NSHostingView(rootView: NavigationSplitView {
            List(Module.allCases) { Text($0.title) }
        } detail: {
            LaunchAgentsView(model: model)
        })
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 512), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        // Lay out until the sample agents are shown (≥ 30 s on a busy machine), then let the list settle.
        for _ in 0..<150 where model.agents.count < agents.count { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(200)) }
        #expect(model.agents.count == agents.count)
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(200)) }
        // Broken: the window grew to ~2170 pt to fit a ~2115 pt minimum height.
        #expect(host.fittingSize.height < 700, "Login Items needs \(host.fittingSize.height) pt of height")
        window.close()
    }
}
