import Foundation

/// iOS/iPadOS/iPod software updates (`*.ipsw`, 5–8 GB each) downloaded by Finder or Apple Configurator.
nonisolated enum DeviceFirmware {
    /// Where Finder (and iTunes before it) keeps downloaded updates.
    static let finderFolders = ["iPhone", "iPad", "iPod"].map { "~/Library/iTunes/\($0) Software Updates" }
    /// Apple Configurator's firmware cache: an Apple group container, so it needs Full Disk Access.
    static let configuratorFolder = "~/Library/Group Containers/K36BKF7T3D.group.com.apple.configurator/Library/Caches/Firmware"
    static let configuratorBundleID = "com.apple.configurator.ui"
    /// Finder's device processes (backup and restore/update) and the updater it launches.
    static let processNames = MobileBackups.processNames + ["MobileDeviceUpdater"]

    /// "iPhone15,2_18.1_22B83_Restore.ipsw" → "iPhone · 18.1 (22B83)"; nil when the name has no version and build.
    static func label(fileName: String) -> String? {
        let parts = fileName.split(separator: "_").map(String.init)
        guard let device = parts.first?.prefix(while: \.isLetter), !device.isEmpty,
              let i = parts.indices.dropFirst(2).first(where: { isBuild(parts[$0]) && isVersion(parts[$0 - 1]) })
        else { return nil }
        return "\(device) · \(parts[i - 1]) (\(parts[i]))"
    }

    static func label(of url: URL) -> (title: String, date: Date?)? {
        label(fileName: url.lastPathComponent).map { ($0, nil) }
    }

    private static func isVersion(_ s: String) -> Bool {
        s.contains(".") && s.allSatisfy { $0.isNumber || $0 == "." }
    }
    /// Build numbers look like 22B83, 21A5291h: digits, one letter, digits, an optional letter.
    private static func isBuild(_ s: String) -> Bool {
        s.range(of: #"^[0-9]+[A-Z][0-9]+[a-z]?$"#, options: .regularExpression) != nil
    }
}
