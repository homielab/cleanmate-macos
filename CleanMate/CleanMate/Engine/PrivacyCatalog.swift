import Foundation

// Privacy module: browsing traces per browser and system/shell histories. Separate from Smart Scan.
// Every item is unticked by default and deleted permanently (the point is to erase traces).
// Never listed: saved passwords (Login Data, logins.json, key4.db), bookmarks (Bookmarks, Bookmarks.plist;
// Firefox's places.sqlite only has its history records erased), extensions, saved addresses/cards — see `privacyNeverTouchesCredentialsBookmarksExtensions`.

extension CleanerGroup {
    nonisolated static let privacy: [CleanerGroup] = [
        CleanerGroup(id: "privacy-safari", title: "Safari", systemImage: "safari", items: [
            safariHistory,
            trace("safari-downloads", "Download history", note: "The list of downloads; downloaded files are kept",
                  ["~/Library/Safari"], ["Downloads.plist"], bundle: "com.apple.Safari"),
            trace("safari-cookies", "Cookies", note: cookiesNote,
                  ["~/Library/Containers/com.apple.Safari/Data/Library/Cookies"], ["Cookies.binarycookies"],
                  bundle: "com.apple.Safari"),
            trace("safari-autofill", "Form autofill data", note: autofillNote, ["~/Library/Safari"], ["Form Values"],
                  bundle: "com.apple.Safari"),
        ]),
        chromium("chrome", "Google Chrome", support: "Google/Chrome", bundle: "com.google.Chrome"),
        chromium("edge", "Microsoft Edge", support: "Microsoft Edge", bundle: "com.microsoft.edgemac"),
        chromium("brave", "Brave", support: "BraveSoftware/Brave-Browser", bundle: "com.brave.Browser"),
        chromium("arc", "Arc", support: "Arc/User Data", bundle: "company.thebrowser.Browser"),
        firefox,
        chromium("opera", "Opera", support: "com.operasoftware.Opera", bundle: "com.operasoftware.Opera"),
        chromium("vivaldi", "Vivaldi", support: "Vivaldi", bundle: "com.vivaldi.Vivaldi"),
    ] + browserChannels.map { chromium($0.id, $0.name, support: $0.folder, bundle: $0.bundle) } + [
        CleanerGroup(id: "privacy-system", title: "System", systemImage: "desktopcomputer", items: [
            trace("recent-items", "Recent items",
                  note: "Recent documents, apps and servers in Finder, the Apple menu and apps",
                  ["~/Library/Application Support/com.apple.sharedfilelist"],
                  ["com.apple.LSSharedFileList.Recent*", "com.apple.LSSharedFileList.ApplicationRecentDocuments"]),
            CleanerItem(id: "quicklook-cache", title: "QuickLook thumbnail cache",
                        note: "Previews of files you have viewed. Size can't be measured (private to macOS)",
                        paths: [], selectedByDefault: false,
                        command: ShellCommand(executable: "/usr/bin/qlmanage", arguments: ["-r", "cache"]),
                        showsWhenEmpty: false),
            trace("shell-history", "Shell history", note: "zsh, bash and fish. Open terminal windows may save theirs again when closed",
                  ["~", "~/.local/share/fish"], [".zsh_history", ".zsh_sessions", ".bash_history", ".bash_sessions",
                                                  ".sh_history", "fish_history"]),
            trace("repl-history", "REPL history", note: "python, node, psql, mysql and sqlite",
                  ["~"], [".python_history", ".node_repl_history", ".psql_history", ".mysql_history", ".sqlite_history"]),
            trace("pager-editor-history", "less and Vim history", note: "Vim also forgets marks and registers",
                  ["~"], [".lesshst", ".viminfo"]),
            CleanerItem(id: "terminal-saved-state", title: "Terminal saved state",
                        note: terminalSavedStateNote,
                        paths: ["~/Library/Saved Application State/com.apple.Terminal.savedState"],
                        selectedByDefault: false, showsWhenEmpty: false,
                        runningAppBundleIDs: ["com.apple.Terminal"], skipsOpenFiles: true),
            CleanerItem(id: "iterm2-saved-state", title: "iTerm2 saved state",
                        note: terminalSavedStateNote,
                        paths: ["~/Library/Application Support/iTerm2/SavedState",
                                "~/Library/Saved Application State/com.googlecode.iterm2.savedState"],
                        selectedByDefault: false, showsWhenEmpty: false,
                        runningAppBundleIDs: ["com.googlecode.iterm2"], skipsOpenFiles: true),
        ]),
    ]

    /// History.db, -wal and -shm go together or not at all: a macOS service (history sync) may keep the
    /// database open after Safari quits, and removing only some of them, or under a writer, corrupts it. Checked at
    /// scan and again before each removal; RecentlyClosedTabs.plist is not a database and is always listed.
    nonisolated private static let safariHistory: CleanerItem = {
        var item = trace("safari-history", "Browsing history",
                         note: "Visited pages and recently closed tabs. If history syncs, other devices keep theirs. Kept while Safari or a macOS service still uses it: try again later",
                         ["~/Library/Safari"], ["History.db", "History.db-*", "RecentlyClosedTabs.plist"],
                         bundle: "com.apple.Safari")
        item.skipsEntry = { { historyInUse($0) } }
        return item
    }()

    /// Whether `url` is History.db* while any History.db* beside it is open; `openPaths` reads that folder's open
    /// files (tests: their own process only).
    nonisolated static func historyInUse(_ url: URL, openPaths: (String) -> Set<String> = { RunningProcesses.openPaths(under: $0) }) -> Bool {
        url.lastPathComponent.hasPrefix("History.db") && openPaths(url.deletingLastPathComponent().path)
            .contains { ($0 as NSString).lastPathComponent.hasPrefix("History.db") }
    }
    nonisolated private static let cookiesNote: LocalizedStringResource = "Signs you out of websites"
    nonisolated private static let autofillNote: LocalizedStringResource =
        "Text saved from web forms; passwords, addresses and cards are kept"
    nonisolated private static let terminalSavedStateNote: LocalizedStringResource =
        "Previous windows will not be restored on next launch; profiles and settings are kept"

    /// Chromium profiles: the data folder itself (Opera) and its profiles (Default, Profile 1…).
    nonisolated private static func chromium(_ id: String, _ name: String, support: String, bundle: String) -> CleanerGroup {
        let root = "~/Library/Application Support/" + support
        let profiles = [root, root + "/*"]
        return CleanerGroup(id: "privacy-" + id, title: LocalizedStringResource(String.LocalizationValue(name)),
                            systemImage: "globe", items: [
            // History also holds the download list (the item below): only its browsing tables are emptied.
            trace(id + "-history", "Browsing history", note: "Visited pages and typed URLs; the download list is kept",
                  profiles, ["History", "Visited Links", "Top Sites", "Top Sites-*",
                             "Shortcuts", "Shortcuts-*", "Network Action Predictor", "Network Action Predictor-*"],
                  bundle: bundle,
                  database: DatabaseErase(count: "SELECT count(*) FROM visits;",
                                          tables: ["visits", "visit_source", "keyword_search_terms", "segments", "segment_usage",
                                                   "content_annotations", "context_annotations", "cluster*", "visited_links", "urls",
                                                   // Journeys: AI summaries of history; journey_sync_metadata is sync bookkeeping, kept like history_sync_metadata.
                                                   "journeys", "journey_history_entries", "journey_continuation_queries"],
                                          file: "History")),
            trace(id + "-downloads", "Download history", note: "The list of downloads; downloaded files are kept",
                  profiles, ["History"], bundle: bundle,
                  // downloads_slices too: left behind, a later download reusing the id would inherit them.
                  database: DatabaseErase(count: "SELECT count(*) FROM downloads;",
                                          tables: ["downloads", "downloads_url_chains", "downloads_slices"])),
            trace(id + "-cookies", "Cookies", note: cookiesNote, profiles + profiles.map { $0 + "/Network" },
                  ["Cookies", "Cookies-*"], bundle: bundle),
            // Web Data also holds saved addresses, cards and search engines: only the form entries are erased.
            // Newer Chromium (Web Data v15x) keeps them in `autocomplete`; `autofill` is the older table.
            trace(id + "-autofill", "Form autofill data", note: autofillNote, profiles, ["Web Data"], bundle: bundle,
                  database: DatabaseErase(count: "", tables: ["autofill", "autocomplete"])),
        ])
    }

    /// History and downloads share places.sqlite with bookmarks: only visits, typed input, page metadata and
    /// download annotations are erased, then pages no bookmark, keyword or other annotation still uses.
    /// Plain SQL only: Firefox's own temp triggers and functions don't exist outside Firefox.
    /// Release/Beta/ESR (org.mozilla.firefox), Developer Edition and Nightly all share Firefox/Profiles.
    nonisolated static let firefoxBundleIDs = ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"]

    nonisolated private static let firefox: CleanerGroup = {
        let profiles = ["~/Library/Application Support/Firefox/Profiles/*"]
        let downloads = "SELECT id FROM moz_anno_attributes WHERE name LIKE 'downloads/%'"
        return CleanerGroup(id: "privacy-firefox", title: "Firefox", systemImage: "globe", items: [
            trace("firefox-history", "Browsing history and downloads",
                  note: "Visited pages and the download list; bookmarks and downloaded files are kept",
                  profiles, ["places.sqlite"], bundles: firefoxBundleIDs,
                  database: DatabaseErase(
                      count: "SELECT (SELECT count(*) FROM moz_historyvisits) + (SELECT count(*) FROM moz_annos WHERE anno_attribute_id IN (\(downloads)));",
                      erase: """
                          BEGIN;
                          DELETE FROM moz_historyvisits; DELETE FROM moz_inputhistory;
                          DELETE FROM moz_places_metadata; DELETE FROM moz_places_metadata_search_queries;
                          DELETE FROM moz_annos WHERE anno_attribute_id IN (\(downloads));
                          DELETE FROM moz_places WHERE id NOT IN (SELECT fk FROM moz_bookmarks WHERE fk NOT NULL)
                            AND id NOT IN (SELECT place_id FROM moz_keywords WHERE place_id NOT NULL)
                            AND id NOT IN (SELECT place_id FROM moz_annos);
                          UPDATE moz_places SET visit_count = 0, last_visit_date = NULL, typed = 0;
                          DELETE FROM moz_origins WHERE id NOT IN (SELECT origin_id FROM moz_places WHERE origin_id NOT NULL);
                          COMMIT;
                          """)),
            trace("firefox-cookies", "Cookies", note: cookiesNote, profiles, ["cookies.sqlite", "cookies.sqlite-*"],
                  bundles: firefoxBundleIDs),
            trace("firefox-autofill", "Form autofill data", note: autofillNote, profiles,
                  ["formhistory.sqlite", "formhistory.sqlite-*"], bundles: firefoxBundleIDs),
        ])
    }()

    nonisolated private static func trace(_ id: String, _ title: LocalizedStringResource, note: LocalizedStringResource,
                                          _ paths: [String], _ included: [String], bundle: String? = nil, bundles: [String] = [],
                                          database: DatabaseErase? = nil) -> CleanerItem {
        CleanerItem(id: id, title: title, note: note, paths: paths, included: included, database: database,
                    selectedByDefault: false, showsWhenEmpty: false, runningAppBundleIDs: bundles + (bundle.map { [$0] } ?? []))
    }
}
