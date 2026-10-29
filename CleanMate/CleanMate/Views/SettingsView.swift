import SwiftUI
import Combine
import UniformTypeIdentifiers

enum FullDiskAccess {
    /// ~/.Trash is only readable with Full Disk Access on recent macOS.
    nonisolated static var isGranted: Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/.Trash")) != nil
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct SettingsView: View {
    static let exclusionsTab = "exclusions"
    /// Remembered, and set by a blocked Smart Scan row to open on Exclusions.
    @AppStorage(Preferences.settingsTab) private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            SmartScanSettings().tabItem { Label("Scan Groups", systemImage: "sparkles") }.tag("groups")
            ExclusionSettings().tabItem { Label("Exclusions", systemImage: "nosign") }.tag(Self.exclusionsTab)
            ActivitySettings().tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }.tag("activity")
        }
        .frame(width: 520, height: 780)  // tallest tab (General) fits without scrolling in EN/VI
    }
}

struct GeneralSettings: View {
    @State private var granted = FullDiskAccess.isGranted
    @AppStorage(Preferences.oldLogsDays) private var logsDays = CleanupAges.default.logs
    @AppStorage(Preferences.tempFilesDays) private var tempDays = CleanupAges.default.temp
    @AppStorage(Preferences.sessionDays) private var sessionDays = CleanupAges.default.sessions
    @AppStorage(Preferences.showMenuBarExtra) private var showMenuBarExtra = false
    @State private var confirmingReset = false
    /// The pressed button disappears when the inline confirmation swaps in: keyboard focus follows it.
    @FocusState private var resetFocus: Bool?

    var body: some View {
        Form {
            Section {
                Toggle("Show free space in the menu bar", isOn: $showMenuBarExtra)
            } footer: {
                Text("CleanMate keeps running in the menu bar after its window is closed. It does not start at login.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Full Disk Access") {
                    granted ? Text("Granted") : Text("Not granted")
                }
                Button("Open Privacy Settings…") { FullDiskAccess.openSettings() }
            } footer: {
                Text("Needed to empty the Trash and read Safari data. CleanMate only cleans inside your user account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Smart Scan") {
                Stepper("Old logs: not modified for \(logsDays) days", value: $logsDays, in: 1...90)
                Stepper("Temporary files: not modified for \(tempDays) days", value: $tempDays, in: 1...30)
                Stepper("AI sessions: not modified for \(sessionDays) days",
                        onIncrement: { sessionDays = CleanupAges.sessionStep(from: sessionDays, up: true) },
                        onDecrement: { sessionDays = CleanupAges.sessionStep(from: sessionDays, up: false) })
                LabeledContent("Remembered choices") {
                    // Asks inline first: it forgets every tick changed by hand, with no Undo.
                    if confirmingReset {
                        HStack {
                            Button("Cancel") { confirmingReset = false; resetFocus = false }
                                .focused($resetFocus, equals: true)
                            Button("Reset Choices", role: .destructive) {
                                UserDefaults.standard.removeObject(forKey: Preferences.selectionOverrides)
                                confirmingReset = false
                                resetFocus = false
                                AccessibilityNotification.Announcement(Self.resetDone()).post()
                            }
                        }
                        .onAppear { resetFocus = true }
                    } else {
                        Button("Reset…") { confirmingReset = true }
                            .focused($resetFocus, equals: false)
                    }
                }
            }
            UpdateSettings(updater: .shared)
            Section {
                LabeledContent("Language") { Text("Same as your Mac") }
            } footer: {
                Text("To use another language for CleanMate only, open System Settings > General > Language & Region > Applications and add CleanMate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { granted = FullDiskAccess.isGranted }
        // Granting access happens in System Settings: refresh when the user comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            granted = FullDiskAccess.isGranted
        }
    }
}

extension GeneralSettings {
    /// Read by VoiceOver after "Reset Choices": the row only swaps back to "Reset…", which says nothing happened.
    nonisolated static func resetDone(locale: Locale = .current) -> String {
        String(localized: LocalizedStringResource("Remembered choices reset", locale: locale))
    }
}

/// Settings › Smart Scan: groups turned off here are never scanned nor shown. Privacy has no such switch:
/// its few per-browser groups are already unticked by default and quick to scan.
struct SmartScanSettings: View {
    @AppStorage(Preferences.disabledScanGroups) private var disabledText = ""
    private let groups = CleanerGroup.smartScan

    var body: some View {
        Form {
            Section {
                ForEach(groups) { group in
                    Toggle(isOn: binding(group.id)) {
                        Label { Text(group.title) } icon: { Image(systemName: group.systemImage) }
                    }
                }
            } header: {
                Text("Scan These Groups")
            } footer: {
                Text("Groups turned off are not scanned nor shown, so Smart Scan finishes sooner.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { !Preferences.disabledGroups(text: disabledText).contains(id) }, set: { on in
            var off = Preferences.disabledGroups(text: disabledText)
            if on { off.remove(id) } else { off.insert(id) }
            disabledText = off.sorted().joined(separator: "\n")
        })
    }
}

struct ExclusionSettings: View {
    @State private var folders = Preferences.excluded
    @State private var selection: Set<String> = []
    @State private var choosing = false
    /// Folders waiting for "Add Anyway": one of them is broad.
    @State private var pending: [URL] = []
    @FocusState private var cancelFocused: Bool

    var body: some View {
        Form {
            Section {
                List(folders, id: \.self, selection: $selection) { path in
                    // A file excluded with "Never Clean This" gets a document icon.
                    Label((path as NSString).abbreviatingWithTildeInPath,
                          systemImage: URL(fileURLWithPath: path).hasDirectoryPath ? "folder" : "doc")
                }
                .frame(minHeight: 220)
                .dropDestination(for: URL.self) { urls, _ in
                    // The saved list, not `folders`: a "Never Clean This" not yet shown here must not be dropped.
                    let saved = Preferences.excluded
                    guard Preferences.addingExcluded(urls, to: saved) != saved else { return false }
                    add(urls)
                    return true
                }
                .overlay {
                    if folders.isEmpty { Text("No excluded folders").foregroundStyle(.secondary) }
                }
                if let broad = pending.first(where: { Preferences.isBroad($0) }) {
                    // Inline, not an alert.
                    HStack {
                        Label(Self.broadWarning(broad), systemImage: "exclamationmark.triangle.fill")
                        Spacer()
                        Button("Cancel") { pending = [] }.focused($cancelFocused)
                        Button("Add Anyway") {
                            save(Preferences.addingExcluded(pending, to: Preferences.excluded))
                            pending = []
                        }
                    }
                }
                HStack {
                    Button("Add Folder…", systemImage: "plus") { choosing = true }
                    Button("Remove", systemImage: "minus") { save(Preferences.excluded.filter { !selection.contains($0) }) }
                        .disabled(selection.isEmpty)
                }
            } footer: {
                Text("Nothing inside these folders, nor these files, is ever listed or removed by any module. Drag folders from Finder into the list to add them, or choose Never Clean This on a row.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // "Never Clean This" adds while this pane is open: re-read, so a later save doesn't drop it.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let saved = Preferences.excluded
            if saved != folders { folders = saved }
        }
        // The row appears after a drop or the folder picker, away from where VoiceOver and the keyboard are.
        .onChange(of: pending) {
            guard let broad = pending.first(where: { Preferences.isBroad($0) }) else { return }
            AccessibilityNotification.Announcement(Self.broadWarning(broad)).post()
            cancelFocused = true
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            guard let urls = try? result.get() else { return }
            add(urls)
        }
    }

    /// Shown and read by VoiceOver when a broad folder waits for "Add Anyway".
    nonisolated static func broadWarning(_ url: URL, locale: Locale = .current) -> String {
        let path = (url.path as NSString).abbreviatingWithTildeInPath
        return String(localized: LocalizedStringResource("Excluding \(path) means CleanMate cleans nothing inside it.", locale: locale))
    }

    /// Saves `urls` now, or waits for the confirmation row when one is broad.
    private func add(_ urls: [URL]) {
        if urls.contains(where: { Preferences.isBroad($0) }) { pending = urls } else {
            save(Preferences.addingExcluded(urls, to: Preferences.excluded))
        }
    }

    private func save(_ paths: [String]) {
        folders = paths
        selection = []
        UserDefaults.standard.set(paths, forKey: Preferences.excludedFolders)
    }
}

/// Settings › Activity: activity.log as a table, newest first. `home` lets UISnapshots inject a sample log.
struct ActivitySettings: View {
    /// The Kind column's icon and its text, read by VoiceOver and shown as the tooltip.
    static func kindLabel(_ kind: String, locale: Locale = .current) -> (title: String, systemImage: String) {
        func text(_ resource: LocalizedStringResource) -> String {
            var resource = resource
            resource.locale = locale // picks the language too, as in CleanerItemRow.sizeText
            return String(localized: resource)
        }
        switch kind {
        case "deleted": return (text("Deleted"), "xmark.circle")
        case "trashed": return (text("Trashed"), "trash")
        case "restored": return (text("Put back"), "arrow.uturn.backward")
        default: return (kind, "questionmark")
        }
    }

    /// Rows matching the Module picker ("" = all) and the search text on the item name or path.
    static func filter(_ entries: [ActivityLog.Entry], module: String, search: String) -> [ActivityLog.Entry] {
        let search = search.trimmingCharacters(in: .whitespaces)
        return entries.filter {
            (module.isEmpty || $0.moduleKey == module) && (search.isEmpty || $0.item.localizedStandardContains(search))
        }
    }

    /// Picker choices: one per module key in the log, shown translated, sorted by the shown name.
    static func modules(_ entries: [ActivityLog.Entry]) -> [(key: String, title: String)] {
        Dictionary(entries.map { ($0.moduleKey, $0.module) }, uniquingKeysWith: { first, _ in first })
            .map { (key: $0.key, title: $0.value) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var home = SafetyPolicy.current.homeURL
    /// "Last 30 days" ends here; nil = the time of each reload. UISnapshots pins it so the picture never moves.
    var now: Date?
    @Environment(\.locale) private var locale
    @State private var entries: [ActivityLog.Entry] = []
    @State private var recent: (deleted: Int64, trashed: Int64, since: Date?) = (0, 0, nil)
    @State private var total: (deleted: Int64, trashed: Int64, since: Date?) = (0, 0, nil)
    @State private var module = ""
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading) {
            if let since = total.since {
                let date = since.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
                // Trashed items still take space until the Trash is emptied, so they are never added to "Freed".
                Text("Freed: \(recent.deleted, format: .fileSize) in the last 30 days · \(total.deleted, format: .fileSize) since \(date)")
                Text("Moved to the Trash: \(recent.trashed, format: .fileSize) in the last 30 days · \(total.trashed, format: .fileSize) since \(date). Empty the Trash to free that space.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Picker("Module", selection: $module) {
                    Text("All Modules").tag("")
                    ForEach(Self.modules(entries), id: \.key) { Text($0.title).tag($0.key) }
                }
                .fixedSize()
                TextField("Search Items", text: $search).textFieldStyle(.roundedBorder)
            }
            // Filters only the table, in memory; the Freed lines above always count the whole log.
            let shown = Self.filter(entries, module: module, search: search)
            Table(shown) {
                TableColumn("Date") { entry in
                    // Year only in the tooltip: the 520 pt Settings window has no room for it.
                    Text(entry.date?.formatted(.dateTime.month(.defaultDigits).day().hour().minute().locale(locale)) ?? entry.dateText)
                        .monospacedDigit().foregroundStyle(.secondary)
                        .help(entry.date?.formatted(Date.FormatStyle(date: .long, time: .standard).locale(locale)) ?? entry.dateText)
                }
                .width(100)
                // Item gets the room: paths show their file name (full path in the tooltip), module as a second line.
                TableColumn("Item") { entry in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.item.hasPrefix("/") ? URL(fileURLWithPath: entry.item).lastPathComponent : entry.item)
                            .lineLimit(1).truncationMode(.middle)
                        Text(entry.module).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .help(entry.item)
                }
                .width(min: 120)  // takes the rest
                TableColumn("Size") { entry in
                    Group {
                        if let bytes = entry.bytes { Text(bytes, format: .fileSize) } else { Text(entry.size) }
                    }
                    .sizeColumnStyle(emphasized: entry.kind == "deleted")
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(70)
                TableColumn("Kind") { entry in
                    // Icon only to leave room for Item; the label is the tooltip and VoiceOver text.
                    let kind = Self.kindLabel(entry.kind, locale: locale)
                    Label(kind.title, systemImage: kind.systemImage).help(kind.title)
                        .labelStyle(.iconOnly).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
                .width(40)
            }
            .overlay {
                if entries.isEmpty {
                    Text("Nothing has been removed yet").foregroundStyle(.secondary)
                } else if shown.isEmpty {
                    Text("No matching items").foregroundStyle(.secondary)
                }
            }
            HStack {
                Group {
                    if module.isEmpty && search.isEmpty {
                        Text("Newest first. Every removed item is recorded with its size and date.")
                    } else {
                        Text("Filtered. The totals above still count every entry.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Reveal in Finder") {
                    let url = ActivityLog.url(home: home)
                    if FileManager.default.fileExists(atPath: url.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } else {
                        NSWorkspace.shared.open(url.deletingLastPathComponent().deletingLastPathComponent())
                    }
                }
            }
        }
        .padding()
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in load() }
        // record() may post off the main thread; hop to main before touching @State. A clean records every item:
        // reload once after the burst, not once per item.
        .onReceive(NotificationCenter.default.publisher(for: ActivityLog.didRecord)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)) { _ in load() }
    }

    private func load() {
        entries = ActivityLog.readAll(home: home).split(separator: "\n").reversed().enumerated()
            .map { ActivityLog.entry($1, id: $0, locale: locale) }
        // A module gone from the log (rotated or edited) would leave the picker blank and the table empty.
        if !entries.contains(where: { $0.moduleKey == module }) { module = "" }
        recent = ActivityLog.freed(after: (now ?? .now).addingTimeInterval(-30 * 86_400), home: home)
        total = ActivityLog.freed(home: home)
    }
}
