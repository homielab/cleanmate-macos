import AppKit
import SwiftUI
import Testing
@testable import CleanMate

/// The "Quit App" / "Open Settings…" links of a locked row must stay clickable: they used to sit inside the
/// label of the disabled Toggle, so they were disabled too. SwiftUI builds no accessibility tree for an offscreen
/// NSHostingView, so the check is visual: an enabled link is drawn in the accent color (blue), a disabled one in gray,
/// and nothing else in a collapsed row is blue.
@MainActor
struct SmartScanRowTests {
    /// Pixels of `row` where blue clearly dominates (the link text), rendered offscreen in light mode; re-rendered
    /// until there are more than `moreThan` (≥ 10 s), so a busy machine that draws late doesn't fail.
    func bluePixels(_ row: CleanerItemRow, moreThan: Int = -1) async throws -> Int {
        let size = CGSize(width: 600, height: 100)
        let host = NSHostingView(rootView: row.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        defer { window.close() }
        var count = 0, tries = 0
        repeat {
            tries += 1
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            count = 0
            for x in 0..<rep.pixelsWide {
                for y in 0..<rep.pixelsHigh {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if c.blueComponent - max(c.redComponent, c.greenComponent) > 0.3 { count += 1 }
                }
            }
        } while count <= moreThan && tries < 50
        return count
    }

    let scanned = ItemScan(entries: [ScanEntry(url: URL(fileURLWithPath: "/Users/Shared/x"), size: 10)])

    @Test func quitAppLinkIsEnabledWhileTheRowIsLocked() async throws {
        let item = CleanerItem(id: "x", title: "X", paths: [], runningAppBundleIDs: ["com.example.x"])
        let locked = CleanerItemRow(item: item, scan: scanned, isOn: .constant(false), isRunning: true, quit: {})
        let free = CleanerItemRow(item: item, scan: scanned, isOn: .constant(false), isRunning: false, quit: {})
        #expect(try await bluePixels(free) == 0) // the probe sees no blue without a link
        #expect(try await bluePixels(locked, moreThan: 20) > 20)
    }

    @Test func openSettingsLinkIsEnabledWithoutFullDiskAccess() async throws {
        let item = CleanerItem(id: "x", title: "X", paths: [])
        let row = CleanerItemRow(item: item, scan: ItemScan(permissionDenied: true), isOn: .constant(false), isRunning: false, quit: {})
        #expect(try await bluePixels(row, moreThan: 20) > 20)
    }
}

/// VoiceOver reads a Smart Scan row as one element: title, note, size.
struct SmartScanRowLabelTests {
    @Test func labelJoinsTitleNoteAndSize() {
        let item = CleanerItem(id: "x", title: "X", note: "Note", paths: [])
        let size = Int64(2_000_000).formatted(.fileSize)
        #expect(CleanerItemRow.accessibilityLabel(item: item, scan: ItemScan(entries: [ScanEntry(url: URL(fileURLWithPath: "/x"), size: 2_000_000)])) == "X, Note, \(size)")
        #expect(CleanerItemRow.accessibilityLabel(item: item, scan: nil) == "X, Note") // scanning: the spinner has its own label
    }

    @Test func labelCarriesUpperBoundAndUnmeasured() {
        let bound = CleanerItem(id: "x", title: "X", paths: [], sizeIsUpperBound: true)
        #expect(CleanerItemRow.accessibilityLabel(item: bound, scan: ItemScan()).hasPrefix("X, "))
        #expect(CleanerItemRow.sizeText(item: bound, scan: ItemScan()) == String(localized: "Up to \(Int64(0).formatted(.fileSize))"))
        #expect(CleanerItemRow.sizeText(item: CleanerItem(id: "y", title: "Y", paths: []), scan: ItemScan(unmeasured: true)) == String(localized: "Size unknown"))
    }

    /// Some entries left out: the size column and VoiceOver read "selected of total", not the whole item.
    @Test func partialSelectionShowsSelectedOfTotal() {
        let item = CleanerItem(id: "x", title: "X", paths: [], selectableEntries: true)
        let scan = ItemScan(entries: [ScanEntry(url: URL(fileURLWithPath: "/a"), size: 3_000_000),
                                      ScanEntry(url: URL(fileURLWithPath: "/b"), size: 2_000_000)])
        let en = Locale(identifier: "en")
        #expect(CleanerItemRow.sizeText(item: item, scan: scan, selectedSize: 2_000_000, locale: en) == "2 MB of 5 MB")
        #expect(CleanerItemRow.accessibilityLabel(item: item, scan: scan, selectedSize: 2_000_000, locale: en) == "X, 2 MB of 5 MB")
        #expect(CleanerItemRow.sizeText(item: item, scan: scan, locale: en) == "5 MB") // whole item
        #expect(CleanerItemRow.sizeText(item: item, scan: scan, selectedSize: 2_000_000, locale: Locale(identifier: "vi")) == "2 MB / 5 MB")
    }
}

/// VoiceOver labels of newer controls: Smart Scan rows, Activity kind icons, the duplicate copies column.
struct NewControlLabelTests {
    let en = Locale(identifier: "en"), vi = Locale(identifier: "vi")

    /// A Docker image row has no checkbox and no file: one element "name, size". Rows with a control keep theirs.
    @Test func dockerImageRowReadsNameAndSize() {
        let image = ScanEntry(url: URL(string: "docker-image:0")!, size: 2_000_000, title: "nginx:latest")
        #expect(CleanerItemRow.rowAccessibilityLabel(entry: image, selectable: false, locale: en) == "nginx:latest, 2 MB")
        #expect(CleanerItemRow.rowAccessibilityLabel(entry: image, selectable: true, locale: en) == nil)
        let file = ScanEntry(url: URL(fileURLWithPath: "/a/b.log"), size: 2_000_000)
        #expect(CleanerItemRow.rowAccessibilityLabel(entry: file, selectable: false, locale: en) == nil) // has Reveal in Finder
        #expect(CleanerItemRow.accessibilityLabel(entry: file, locale: en) == "b.log, 2 MB") // the entry checkbox
    }

    /// A labelled entry (DerivedData project, iPhone backup) reads "label, date, size", not its path.
    @Test func labelledEntryReadsLabelDateAndSize() {
        let date = Date(timeIntervalSince1970: 1_768_478_400) // 2026-01-15 12:00 UTC
        let url = URL(fileURLWithPath: "/Users/me/Library/Developer/Xcode/DerivedData/App-abcdefghijklmnop")
        let dated = ScanEntry(url: url, size: 2_000_000, title: "App · ~/Code/App.xcodeproj", date: date)
        let day = date.formatted(.dateTime.year().month().day().locale(en))
        #expect(CleanerItemRow.accessibilityLabel(entry: dated, locale: en) == "App · ~/Code/App.xcodeproj, \(day), 2 MB")
        let undated = ScanEntry(url: url, size: 2_000_000, title: "iOS 18.1 (22B83)")
        #expect(CleanerItemRow.accessibilityLabel(entry: undated, locale: en) == "iOS 18.1 (22B83), 2 MB")
        #expect(!CleanerItemRow.accessibilityLabel(entry: dated, locale: vi).contains("/Users"))
        #expect(CleanerItemRow.accessibilityLabel(entry: ScanEntry(url: url, size: 2_000_000), locale: en) == "App-abcdefghijklmnop, 2 MB")
    }

    /// The Activity log's Kind column is an icon only: its label is what VoiceOver reads, in EN and VI.
    @Test func activityKindIconHasLabel() {
        let deleted = ActivitySettings.kindLabel("deleted", locale: en)
        #expect(deleted.title == "Deleted" && deleted.systemImage == "xmark.circle")
        #expect(ActivitySettings.kindLabel("deleted", locale: vi).title == "Đã xoá")
        #expect(ActivitySettings.kindLabel("restored", locale: vi).title == "Đã khôi phục")
        #expect(ActivitySettings.kindLabel("trashed", locale: en).title == "Trashed")
        let other = ActivitySettings.kindLabel("other", locale: vi)
        #expect(other.title == "other" && other.systemImage == "questionmark")
    }

    /// The Copies column reads "N copies" / "N bản".
    @Test func copiesColumnReadsCount() {
        var text: LocalizedStringResource = "\(3) copies"
        text.locale = vi
        #expect(String(localized: text) == "3 bản")
    }
}
