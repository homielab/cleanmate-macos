import SwiftUI
import Combine
import Sparkle

/// Sparkle updates: CleanMate's only network connection. It downloads the appcast from GitHub Releases
/// (`SUFeedURL` in Info.plist) and, when the user asks or allows it, the signed update itself.
/// Automatic checks follow Sparkle's default: off on the first launch, the user is asked on the second.
/// No system profile and no extra parameters are ever sent.
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    private let delegate = Delegate()
    private let controller: SPUStandardUpdaterController
    private var observers: Set<AnyCancellable> = []
    private let environment: [String: String]
    /// Stays false under tests: they must never reach the network, nor show Sparkle's permission prompt.
    private(set) var isStarted = false
    @Published private(set) var canCheckForUpdates = false

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: nil)
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        // The settings below are stored by Sparkle (its own user defaults); refresh the views when they change,
        // including from Sparkle's permission prompt.
        Publishers.Merge3(updater.publisher(for: \.automaticallyChecksForUpdates).map { _ in () },
                          updater.publisher(for: \.automaticallyDownloadsUpdates).map { _ in () },
                          updater.publisher(for: \.allowsAutomaticUpdates).map { _ in () })
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &observers)
    }

    /// Called once the main window is up: SwiftUI opens no window at launch when one already exists,
    /// so Sparkle's permission prompt (second launch) shown earlier left the app with only that prompt.
    func start() {
        guard !isStarted, Self.startsUpdater(environment: environment) else { return }
        controller.startUpdater()
        isStarted = true
    }

    nonisolated static func startsUpdater(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] == nil
    }

    /// Settings › General. Setting it before Sparkle asked counts as the answer: it won't ask any more.
    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloads: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    /// False while automatic checks are off: downloading in the background needs them.
    var allowsAutomaticDownloads: Bool { controller.updater.allowsAutomaticUpdates }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    final class Delegate: NSObject, SPUUpdaterDelegate {
        /// Nothing about the Mac is added to the appcast request, even if system profiling were turned on.
        func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }
    }
}

/// App menu › Check for Updates…
struct CheckForUpdatesButton: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}

/// Settings › General › Updates.
struct UpdateSettings: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Section {
            Toggle("Automatically check for updates", isOn: $updater.automaticallyChecks)
            Toggle("Automatically download and install updates", isOn: $updater.automaticallyDownloads)
                .disabled(!updater.allowsAutomaticDownloads)
        } header: {
            Text("Updates")
        } footer: {
            Text("Checking for updates is CleanMate’s only network connection: it asks GitHub whether a new version is out. Nothing about you or your Mac is sent.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
