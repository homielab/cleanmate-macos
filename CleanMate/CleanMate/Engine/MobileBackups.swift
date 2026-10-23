import Foundation

/// iPhone/iPad backups made by Finder: one folder per device in ~/Library/Application Support/MobileSync/Backup.
nonisolated enum MobileBackups {
    static let folder = "~/Library/Application Support/MobileSync/Backup"
    /// Processes that write a backup: the backup tool and the helper that drives it.
    static let processNames = ["AppleMobileBackup", "AppleMobileDeviceHelper"]

    /// Device and last backup date from a backup's `Info.plist`; nil when it is not a property list or names no device.
    /// Title = "Device Name (Product Type)", e.g. "Minh's iPhone (iPhone14,2)".
    static func label(fromInfoPlist data: Data) -> (title: String, date: Date?)? {
        guard let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        func text(_ key: String) -> String? {
            (info[key] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        let product = text("Product Type")
        guard let name = text("Device Name") ?? text("Display Name") ?? product else { return nil }
        return (product.map { $0 == name ? name : "\(name) (\($0))" } ?? name, info["Last Backup Date"] as? Date)
    }

    /// The label of the backup folder at `url`, read from its `Info.plist`.
    static func label(of url: URL) -> (title: String, date: Date?)? {
        (try? Data(contentsOf: url.appending(path: "Info.plist"))).flatMap(label(fromInfoPlist:))
    }
}
