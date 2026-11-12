import Foundation
import Testing

@testable import Freedown

struct CleanupTests {
    /// Docker writes sizes in powers of 1000, with the share after them
    @Test func readsDockerSizes() {
        #expect(Cleanup.dockerBytes("187.9MB (2%)") == 187_900_000)
        #expect(Cleanup.dockerBytes("233.5kB (0%)") == 233_500)
        #expect(Cleanup.dockerBytes("21GB") == 21_000_000_000)
        #expect(Cleanup.dockerBytes("0B") == 0)
        #expect(Cleanup.dockerBytes("nothing") == 0)
    }

    @Test func namesUpdateFolders() {
        #expect(Cleanup.updaterName("notion-updater") == "notion")
        #expect(Cleanup.updaterName("com.example.no-such-app.ShipIt") == "com.example.no-such-app")
    }

    @Test func anAppIsUnusedAfterSixtyDaysOrWhenNeverOpened() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(Cleanup.isUnused(nil, days: 60, now: now))
        #expect(Cleanup.isUnused(now.addingTimeInterval(-61 * 86_400), days: 60, now: now))
        #expect(!Cleanup.isUnused(now.addingTimeInterval(-59 * 86_400), days: 60, now: now))
        #expect(Cleanup.isUnused(now.addingTimeInterval(-31 * 86_400), days: 30, now: now))
    }

    /// A skipped folder covers what it holds, not a neighbour whose name starts the same
    @Test func skipsWhatIsInsideASkippedFolder() {
        let skipped = ["/Users/me/VMs", "/Users/me/Downloads/keep.dmg"]
        #expect(Cleanup.isInside("/Users/me/VMs", skipped))
        #expect(Cleanup.isInside("/Users/me/VMs/linux.qcow2", skipped))
        #expect(!Cleanup.isInside("/Users/me/VMs-old/linux.qcow2", skipped))
        #expect(Cleanup.isInside("/Users/me/Downloads/keep.dmg", skipped))
        #expect(!Cleanup.isInside("/Users/me/Downloads/other.dmg", skipped))
    }

    @Test func readsTheBundleOfAnAppLine() {
        let app = CleanupItem(id: "app-com.example.app", group: .apps, name: "Example", detail: "", size: 1, action: .none)
        let cache = CleanupItem(id: "dev-npm", group: .developer, name: "npm", detail: "", size: 1, action: .none)
        #expect(app.appBundle == "com.example.app")
        #expect(cache.appBundle == nil)
    }

    /// A program from inside the app, or from its maker's folder, means the app works in the background
    @Test func seesAppsWorkingInTheBackground() {
        let karabiner = URL(filePath: "/Applications/Karabiner-Elements.app")
        let daemon = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_console_user_server"
        #expect(Cleanup.inBackground(karabiner, bundle: "org.pqrs.Karabiner-Elements.Settings", processes: [daemon]))
        let helper = "/Applications/Example.app/Contents/Library/LoginItems/Helper.app/Contents/MacOS/Helper"
        #expect(Cleanup.inBackground(URL(filePath: "/Applications/Example.app"), bundle: "com.example.app", processes: [helper]))
        // Apple's apps share com.apple with every macOS program, so only their own path counts
        let garageBand = URL(filePath: "/Applications/GarageBand.app")
        #expect(!Cleanup.inBackground(garageBand, bundle: "com.apple.garageband10", processes: ["/System/Library/CoreServices/com.apple.thing"]))
    }

    /// What fills again counts as caches; deleted data and emptied Trash count as files
    @Test func knowsWhatFillsAgain() {
        func item(_ id: String, _ group: CleanupItem.Group) -> CleanupItem {
            CleanupItem(id: id, group: group, name: id, detail: "", size: 1, action: .none)
        }
        #expect(item("docker-build", .docker).refills)
        #expect(item("docker-images", .docker).refills)
        #expect(!item("docker-volumes", .docker).refills)
        #expect(item("dev-npm", .developer).refills)
        #expect(item("browser-com.google.Chrome", .browsers).refills)
        #expect(!item("trash", .trash).refills)
    }

    /// A launch keeps only the files of the last search still where they were
    @Test func aSavedSearchLeavesOutFilesGoneSince() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "freedown-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let kept = folder.appending(path: "kept.dmg")
        try Data([1]).write(to: kept)
        let gone = folder.appending(path: "gone.dmg")
        let search = LargeFileSearch(
            date: .now, minimum: 500 << 20,
            files: [LargeFile(path: kept.path, size: 600 << 20, modified: nil), LargeFile(path: gone.path, size: 700 << 20, modified: nil)])
        #expect(search.present.map(\.path) == [kept.path])
    }

    /// A search saved before the size could be set still loads, with no size of its own
    @Test func readsASearchSavedWithoutItsSize() throws {
        let json = #"{"date":"2026-11-12T10:00:00Z","files":[{"path":"/tmp/a.dmg","size":600}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let search = try decoder.decode(LargeFileSearch.self, from: Data(json.utf8))
        #expect(search.minimum == nil)
        #expect(search.files == [LargeFile(path: "/tmp/a.dmg", size: 600, modified: nil)])
    }

    /// A file inside an app's data is only shown: that app removes it
    @Test func filesInAppDataAreOnlyShown() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let inApp = Cleanup.item(LargeFile(path: home.appending(path: "Library/Application Support/Game/data.pak").path, size: 1, modified: nil))
        let download = Cleanup.item(LargeFile(path: home.appending(path: "Downloads/movie.mkv").path, size: 1, modified: nil))
        #expect(!inApp.cleanable)
        if case .moveToTrash = download.action {} else { Issue.record("a download should go to the Trash") }
    }
}
