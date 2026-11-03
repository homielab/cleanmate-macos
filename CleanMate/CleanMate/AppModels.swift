import Foundation

/// The modules' models, owned by the app rather than by the main window: closing the window (menu bar only, ⌘W) keeps
/// the results shown and a running scan going, and reopening it shows them again.
final class AppModels {
    static let shared = AppModels()

    let overview: OverviewModel
    let smartScan: SmartScanModel
    let privacy: SmartScanModel
    let largeFiles: LargeFilesModel
    let uninstaller: UninstallerModel
    let spaceLens: SpaceLensModel
    let loginItems: LaunchAgentsModel
    let maintenance: MaintenanceModel

    /// Tests and the scan benchmark pass their own models; the rest are new ones.
    init(overview: OverviewModel = OverviewModel(), smartScan: SmartScanModel = SmartScanModel(module: .smartScan),
         privacy: SmartScanModel = SmartScanModel(module: .privacy), largeFiles: LargeFilesModel = LargeFilesModel(),
         uninstaller: UninstallerModel = UninstallerModel(), spaceLens: SpaceLensModel = SpaceLensModel(),
         loginItems: LaunchAgentsModel = LaunchAgentsModel(), maintenance: MaintenanceModel = MaintenanceModel()) {
        self.overview = overview
        self.smartScan = smartScan
        self.privacy = privacy
        self.largeFiles = largeFiles
        self.uninstaller = uninstaller
        self.spaceLens = spaceLens
        self.loginItems = loginItems
        self.maintenance = maintenance
        overview.spaceLens = spaceLens
        overview.uninstaller = uninstaller
    }

    /// Deleting, moving to the Trash, putting back or a launchctl change is under way: menu bar "Scan Now" waits.
    var isChanging: Bool {
        Self.isChanging(smartScan, privacy, largeFiles, uninstaller, spaceLens, loginItems)
    }

    /// `isChanging`, or a Maintenance task (brew upgrade) or snapshot deletion runs: quitting now would stop it partway.
    var isBusy: Bool { isChanging || maintenance.busy }

    static func isChanging(_ smartScan: SmartScanModel?, _ privacy: SmartScanModel?, _ largeFiles: LargeFilesModel?,
                           _ uninstaller: UninstallerModel?, _ spaceLens: SpaceLensModel?, _ loginItems: LaunchAgentsModel?) -> Bool {
        let cleaning = [smartScan, privacy].contains { if case .cleaning? = $0?.phase { true } else { $0?.undoing == true } }
        let trashingFiles = if case .trashing? = largeFiles?.phase { true } else { false }
        // Uninstaller `working` (also while waiting for an app to quit) and Space Lens `trashing` also cover their Undo.
        return cleaning || trashingFiles || largeFiles?.undoing == true || largeFiles?.similarPhotos.isChanging == true
            || uninstaller?.working == true
            || spaceLens?.trashing == true || loginItems?.working == true
    }
}
