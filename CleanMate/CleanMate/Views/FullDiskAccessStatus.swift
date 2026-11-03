import AppKit
import Combine

/// Full Disk Access as views show it. Read once, then again in the background each time the app becomes active
/// (access is granted in System Settings), so drawing a view never touches the disk.
final class FullDiskAccessStatus: ObservableObject {
    static let shared = FullDiskAccessStatus()

    @Published private(set) var granted: Bool
    /// The last background read; tests wait for it.
    private(set) var refreshTask: Task<Void, Never>?
    private let probe: @Sendable () -> Bool
    private var observer: AnyCancellable?

    /// Tests pass their own probe and notification center.
    init(granted: Bool = FullDiskAccess.isGranted, probe: @escaping @Sendable () -> Bool = { FullDiskAccess.refresh() },
         center: NotificationCenter = .default) {
        self.granted = granted
        self.probe = probe
        observer = center.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
    }

    /// Probes off the main thread, then publishes a change.
    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            let granted = await Self.read(self.probe)
            guard !Task.isCancelled, granted != self.granted else { return }
            self.granted = granted
        }
    }

    @concurrent private nonisolated static func read(_ probe: @Sendable () -> Bool) async -> Bool { probe() }
}
