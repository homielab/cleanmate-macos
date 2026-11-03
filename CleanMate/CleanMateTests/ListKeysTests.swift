import Foundation
import Testing
@testable import CleanMate

/// ⌘A / ⇧⌘A and the search field in the lists that gained them.
@MainActor
struct ListKeysTests {
    // MARK: Large Files

    /// ⌘A ticks like Select All: in Duplicates, every copy but the one to keep.
    @Test func largeFilesSelectAllKeepsOneCopyOfEachDuplicate() {
        let model = LargeFilesModel()
        let f = { (path: String, age: Double) in
            LargeFile(url: URL(fileURLWithPath: path), size: 100_000_000, lastUsed: .now, kind: .other, modified: .now.addingTimeInterval(-age))
        }
        let (old, new, single) = (f("/old", 9), f("/new", 1), f("/single", 1))
        model.files = [old, new, single]
        model.duplicateGroups = [[new.url, old.url]]
        model.phase = .results
        model.setCheckedByKey(true)
        #expect(model.checked == [old.url, new.url, single.url])
        model.setCheckedByKey(false)
        #expect(model.checked.isEmpty)
        model.duplicatesOnly = true
        model.setCheckedByKey(true)
        #expect(model.checked == [new.url])
    }

    // MARK: Similar Photos

    static func photo(_ path: String) -> SimilarPhotos.Photo {
        let url = URL(fileURLWithPath: path)
        return SimilarPhotos.Photo(url: url, size: 1_000, modified: .now, width: 10, height: 10, name: url.lastPathComponent,
                                   location: url.deletingLastPathComponent().path)
    }

    /// A search shows whole groups (the suggested photo stays in view); ⌘A and ⇧⌘A touch only those.
    @Test func similarPhotosSearchShowsWholeGroupsAndSelectAllKeepsTheSuggestedPhoto() {
        let model = SimilarPhotosModel()
        let beach = SimilarPhotos.Group(photos: [Self.photo("/p/beach-1.jpg"), Self.photo("/p/beach-2.jpg")])
        let cat = SimilarPhotos.Group(photos: [Self.photo("/q/cat-1.jpg"), Self.photo("/q/cat-2.jpg"), Self.photo("/q/cat-3.jpg")])
        model.groups = [beach, cat]
        model.search = "cat-3"
        #expect(model.shownGroups == [cat])
        model.checkAllButSuggested()
        #expect(model.checked == Set(cat.photos.dropFirst().map(\.url)))
        model.search = ""
        model.checked.insert(beach.photos[1].url)
        model.search = "/q"
        #expect(model.checkedPhotos.count == 2) // the hidden beach photo is not counted
        model.uncheckAll()
        #expect(model.checked == [beach.photos[1].url])
        model.search = "dog"
        #expect(model.shownGroups.isEmpty)
    }

    // MARK: Uninstaller

    @Test func uninstallerSelectAllTicksTheFilesAndTheApp() {
        let app = InstalledApp(url: URL(filePath: "/nonexistent/A.app"), name: "Aaaa", bundleID: "com.test.qqx.a", version: nil, lastUsed: nil)
        let model = UninstallerModel()
        model.apps = [app]
        model.selection = .app(app.url)
        let data = [URL(filePath: "/nonexistent/Library/Caches/a"), URL(filePath: "/nonexistent/Library/Logs/a")]
        model.entries = data.map { AppDataEntry(url: $0, size: 1) }
        model.setAllChecked(false)
        #expect(model.checked.isEmpty && !model.trashApp)
        model.setAllChecked(true)
        #expect(model.checked == Set(data) && model.trashApp)
        model.working = true // nothing changes while removing
        model.setAllChecked(false)
        #expect(model.checked == Set(data))
    }

    @Test func uninstallerSelectAllOnLeftoversTicksEveryRow() {
        let model = UninstallerModel()
        model.selection = .leftovers
        let leftover = URL(filePath: "/nonexistent/Library/Caches/gone")
        model.entries = [AppDataEntry(url: leftover, size: 1)]
        model.setAllChecked(true)
        #expect(model.checked == [leftover])
    }

    // MARK: Login Items

    @Test func loginItemsSearchMatchesLabelProgramOrApp() {
        let agent = LaunchAgent(url: URL(filePath: "/nonexistent/com.foo.updater.plist"), label: "com.foo.updater", scope: .user,
                                program: "/Applications/Foo Sync.app/Contents/MacOS/helper", programMissing: false,
                                owner: URL(filePath: "/Applications/Foo Sync.app"), state: .loaded)
        #expect(LaunchAgentsModel.matches(agent, ""))
        #expect(LaunchAgentsModel.matches(agent, "UPDATER"))
        #expect(LaunchAgentsModel.matches(agent, "helper"))
        #expect(LaunchAgentsModel.matches(agent, "foo sync"))
        #expect(!LaunchAgentsModel.matches(agent, "dropbox"))
    }

    // MARK: Maintenance

    @Test func maintenanceSearchFiltersTasksAndSnapshots() {
        let model = MaintenanceModel()
        #expect(model.tasks.contains(.quickLook) && model.showsSnapshots)
        model.search = "quick look"
        #expect(model.tasks == [.quickLook] && !model.showsSnapshots)
        model.search = "thumbnail" // in the description
        #expect(model.tasks == [.quickLook])
        model.search = "Time Machine"
        #expect(model.tasks.isEmpty && model.showsSnapshots)
        model.search = "zzz"
        #expect(model.tasks.isEmpty && !model.showsSnapshots)
        #expect(MaintenanceModel.matches(.fontCache, "Font"))
    }
}
