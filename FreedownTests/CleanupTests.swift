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
        #expect(Cleanup.isUnused(nil, now: now))
        #expect(Cleanup.isUnused(now.addingTimeInterval(-61 * 86_400), now: now))
        #expect(!Cleanup.isUnused(now.addingTimeInterval(-59 * 86_400), now: now))
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
}
