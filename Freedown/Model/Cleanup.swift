import CoreServices
import Foundation

/// Something on this Mac that can go to free disk space: the Trash, Docker leftovers, caches that tools and apps
/// fill again on their own, apps not opened for months. Sizes are what the disk really holds (allocated blocks,
/// or what Docker says it can reclaim), read when the list is made and again after cleaning.
struct CleanupItem: Identifiable, Sendable {
    enum Group: String, CaseIterable, Sendable {
        case trash, docker, developer, updates, browsers, apps, other, files

        var title: String {
            switch self {
            case .trash: "Trash"
            case .docker: "Docker"
            case .developer: "Developer caches"
            case .updates: "App update downloads"
            case .browsers: "Browser caches"
            case .apps: "Apps not opened for \(Cleanup.unusedDays) days"
            case .other: "Other"
            case .files: "Large files"
            }
        }
    }

    enum Action: Sendable {
        /// Deletes what the folders hold and keeps the folders: the tool or app fills them again when it needs to
        case emptyFolders([URL])
        /// Runs the tool's own cleanup, from its full path
        case command(String, [String])
        case emptyTrash
        /// An app or a file, through Finder when macOS refuses
        case moveToTrash(URL)
        /// Only shown: its own app cleans it
        case none
    }

    let id: String
    let group: Group
    let name: String
    /// What cleaning does, and what comes back
    let detail: String
    var size: Int64
    let action: Action
    /// The app to quit first, deleting a running app's cache can upset it
    var quitFirst: String?
    var reveal: URL?
    /// How many things cleaning it deletes, for the saved-space history
    var count = 1

    /// The app's bundle id, on a line of an unused app
    var appBundle: String? { group == .apps && id.hasPrefix("app-") ? String(id.dropFirst("app-".count)) : nil }

    /// Comes back on its own as tools and apps work: caches, update downloads, Docker images
    var refills: Bool {
        switch group {
        case .developer, .updates, .browsers, .other: true
        case .docker: id == "docker-build" || id == "docker-images"
        case .trash, .apps, .files: false
        }
    }

    /// The same item, measured again
    func measured(_ size: Int64) -> CleanupItem {
        var item = self
        item.size = size
        return item
    }

    var cleanable: Bool {
        switch action {
        case .none: false
        // The Trash may be unreadable without Full Disk Access, and Finder can still empty it
        case .emptyTrash: true
        default: size > 0 && quitFirst == nil
        }
    }
}

/// This Mac's startup disk: its size and the space no file holds
struct MacDisk: Equatable, Sendable {
    let total: Int64
    let free: Int64
    var used: Int64 { total - free }

    /// Free space without what macOS could free on its own (purgeable space), so a clean shows at once
    static func read() -> MacDisk? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityKey, .volumeTotalCapacityKey]
        guard let values = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: keys),
            let free = values.volumeAvailableCapacity, let total = values.volumeTotalCapacity
        else { return nil }
        return MacDisk(total: Int64(total), free: Int64(free))
    }
}

/// A big file or app, as the large-file search found it
struct LargeFile: Codable, Sendable, Equatable {
    let path: String
    let size: Int64
    let modified: Date?
}

/// The last large-file search, kept on disk so the page opens with it: a launch only checks that each file is still
/// where it was, rather than reading every folder again
struct LargeFileSearch: Codable, Sendable {
    let date: Date
    /// The smallest size it looked for; nil in a search saved before the size could be changed, which was 500 MB
    let minimum: Int64?
    let files: [LargeFile]

    /// The files still there: those moved to the Trash or deleted since are left out
    var present: [LargeFile] { files.filter { FileManager.default.fileExists(atPath: $0.path) } }

    private static let file = "large-files.json"
    static func load() -> LargeFileSearch? { Settings.read(LargeFileSearch.self, from: file) }
    func save() { Settings.write(self, to: Self.file, compact: true) }
}

enum Cleanup {
    static let defaultUnusedDays = 60
    /// Days without opening before an app is listed: set in Settings, 60 at first
    static var unusedDays: Int { Int(Settings.number(.unusedAppDays, Double(defaultUnusedDays))) }
    /// Smaller items are not worth a line
    static let minSize: Int64 = 1 << 20

    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let caches = home.appending(path: "Library/Caches")

    /// Everything worth listing, biggest first in each group. `running` holds the bundle ids of open apps, `kept`
    /// those of apps never to offer.
    nonisolated static func scan(running: Set<String>, photosTrash: Int64?, kept: Set<String>, unusedDays: Int) -> [CleanupItem] {
        var items: [CleanupItem] = []
        items += trash()
        items += docker()
        items += developer()
        items += updates()
        items += browsers(running: running)
        items += apps(running: running, kept: kept, unusedDays: unusedDays)
        items += other(running: running, photosTrash: photosTrash, listed: items)
        return items.filter { $0.size >= minSize || $0.group == .trash }
    }

    /// The item as it is now, to see what cleaning freed
    nonisolated static func measure(_ item: CleanupItem) -> Int64 {
        switch item.action {
        case .emptyFolders(let folders): folders.reduce(0) { $0 + allocated($1) }
        case .emptyTrash: allocated(home.appending(path: ".Trash"))
        case .moveToTrash(let target): FileManager.default.fileExists(atPath: target.path) ? allocated(target) : 0
        case .command:
            if item.group == .docker { dockerReclaimable()[item.id] ?? 0 } else { item.reveal.map(allocated) ?? 0 }
        case .none: item.size
        }
    }

    /// Cleans the item. Returns why it did not, or nil.
    nonisolated static func clean(_ item: CleanupItem) -> String? {
        switch item.action {
        case .emptyFolders(let folders):
            var refused = 0
            for folder in folders {
                let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                for child in children where (try? FileManager.default.removeItem(at: child)) == nil { refused += 1 }
            }
            return refused == 0 ? nil : "\(Format.count(refused, "item")) could not be deleted"
        case .command(let tool, let arguments):
            return run(tool, arguments).problem
        case .emptyTrash:
            return Finder.emptyTrash()
        case .moveToTrash(let target):
            do {
                try FileManager.default.trashItem(at: target, resultingItemURL: nil)
                return nil
            } catch {
                // Apps installed by an administrator or the App Store: Finder asks for the password
                return Finder.trash(target)
            }
        case .none:
            return nil
        }
    }

    // MARK: Groups

    private static func trash() -> [CleanupItem] {
        let folder = home.appending(path: ".Trash")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            return [
                CleanupItem(
                    id: "trash", group: .trash, name: "Trash",
                    detail: "Freedown can't measure it without Full Disk Access. Emptying it deletes what it holds for good.", size: 0,
                    action: .emptyTrash, reveal: folder)
            ]
        }
        let count = names.filter { $0 != ".DS_Store" }.count
        return [
            CleanupItem(
                id: "trash", group: .trash, name: "Trash (\(Format.count(count, "item")))",
                detail: "Emptying it deletes these items for good. Apps moved to the Trash from here wait in it too.",
                size: allocated(folder), action: .emptyTrash, reveal: folder, count: count)
        ]
    }

    private static func docker() -> [CleanupItem] {
        guard let docker = tool("docker", in: ["/usr/local/bin", "/opt/homebrew/bin", home.appending(path: ".orbstack/bin").path]) else { return [] }
        let reclaimable = dockerReclaimable(docker)
        guard !reclaimable.isEmpty else { return [] }
        let volumes = run(docker, ["volume", "ls", "--filter", "dangling=true", "--format", "{{.Name}}"]).output
            .split(separator: "\n").map(String.init)
        let rows: [(String, String, String, [String])] = [
            ("docker-build", "Build cache", "Layers kept to speed up the next builds. They come back as you build images.", ["builder", "prune", "--all", "--force"]),
            ("docker-images", "Images no container uses", "Public images download again when needed. Images you built yourself need building again.", ["image", "prune", "--all", "--force"]),
            ("docker-containers", "Stopped containers", "Containers that are not running, with what they wrote inside them.", ["container", "prune", "--force"]),
            ("docker-volumes", "Volumes no container uses",
             "Deleted for good, with their data (databases, uploads): \(volumes.isEmpty ? "none" : volumes.joined(separator: ", ")).",
             ["volume", "prune", "--all", "--force"]),
        ]
        return rows.map { id, name, detail, arguments in
            CleanupItem(id: id, group: .docker, name: name, detail: detail, size: reclaimable[id] ?? 0, action: .command(docker, arguments))
        }
    }

    /// Caches that package managers and Xcode fill again on their own
    private static func developer() -> [CleanupItem] {
        let library = home.appending(path: "Library")
        let folders: [(String, String, [URL])] = [
            ("npm", "npm downloads packages again when it needs them.", [home.appending(path: ".npm/_cacache"), home.appending(path: ".npm/_npx")]),
            ("Yarn", "Yarn downloads packages again when it needs them.", [caches.appending(path: "Yarn")]),
            ("pip", "pip downloads packages again when it needs them.", [caches.appending(path: "pip")]),
            ("uv", "uv downloads packages again when it needs them.", [home.appending(path: ".cache/uv")]),
            ("Poetry", "Poetry's download cache. Project environments are kept.", [caches.appending(path: "pypoetry/cache"), caches.appending(path: "pypoetry/artifacts")]),
            ("Playwright browsers", "Downloaded again by `playwright install`.", [caches.appending(path: "ms-playwright")]),
            ("node-gyp", "Node headers, downloaded again when a native module builds.", [caches.appending(path: "node-gyp")]),
            ("TypeScript", "Type definitions for editors, fetched again when needed.", [caches.appending(path: "typescript")]),
            ("Go build cache", "Go rebuilds it as you compile.", [caches.appending(path: "go-build")]),
            ("CocoaPods", "CocoaPods downloads pods again when it needs them.", [caches.appending(path: "CocoaPods")]),
            ("Gradle", "Gradle downloads dependencies again when it needs them.", [home.appending(path: ".gradle/caches")]),
            ("Cargo", "Cargo downloads crates again when it needs them.", [home.appending(path: ".cargo/registry/cache")]),
            ("Composer", "Composer downloads packages again when it needs them.", [home.appending(path: ".composer/cache"), caches.appending(path: "composer")]),
            ("Xcode build files", "Xcode builds again what it needs (DerivedData).", [library.appending(path: "Developer/Xcode/DerivedData")]),
            ("Xcode device support", "Copied again from a device the next time it is connected.",
             [library.appending(path: "Developer/Xcode/iOS DeviceSupport"), library.appending(path: "Developer/Xcode/watchOS DeviceSupport")]),
            ("SwiftUI previews", "Xcode makes them again when you open a preview.", [library.appending(path: "Developer/Xcode/UserData/Previews")]),
            ("Simulator caches", "Simulators fill it again when they run.", [library.appending(path: "Developer/CoreSimulator/Caches")]),
        ]
        var items = folders.map { name, detail, paths in
            CleanupItem(
                id: "dev-\(name)", group: .developer, name: name, detail: detail, size: paths.reduce(0) { $0 + allocated($1) },
                action: .emptyFolders(paths), reveal: paths.first)
        }
        if let brew = tool("brew", in: ["/opt/homebrew/bin", "/usr/local/bin"]) {
            let folder = caches.appending(path: "Homebrew")
            items.append(
                CleanupItem(
                    id: "dev-brew", group: .developer, name: "Homebrew",
                    detail: "Downloads and old versions of what Homebrew installed (brew cleanup). Only the downloads are counted here.",
                    size: allocated(folder), action: .command(brew, ["cleanup", "--prune=all", "-s"]), reveal: folder))
        }
        return items.sorted { $0.size > $1.size }
    }

    /// Updates an app downloaded and already installed: Electron apps (ShipIt) and others keep the last one
    private static func updates() -> [CleanupItem] {
        let folders = ((try? FileManager.default.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".ShipIt") || $0.lastPathComponent.hasSuffix("-updater") }
        return folders.map { folder in
            CleanupItem(
                id: "update-\(folder.lastPathComponent)", group: .updates, name: updaterName(folder.lastPathComponent),
                detail: "Update files the app already installed.", size: allocated(folder), action: .emptyFolders([folder]), reveal: folder)
        }
        .sorted { $0.size > $1.size }
    }

    private static func browsers(running: Set<String>) -> [CleanupItem] {
        let browsers: [(String, String, String)] = [
            ("Chrome", "com.google.Chrome", "Google/Chrome"), ("Firefox", "org.mozilla.firefox", "Firefox"),
            ("Brave", "com.brave.Browser", "BraveSoftware"), ("Edge", "com.microsoft.edgemac", "Microsoft Edge"),
            ("Arc", "company.thebrowser.Browser", "Arc"),
        ]
        return browsers.compactMap { name, bundle, path in
            let folder = caches.appending(path: path)
            guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
            return CleanupItem(
                id: "browser-\(bundle)", group: .browsers, name: name,
                detail: "Pages and images kept to load sites faster. Sites load a little slower once. Logins and history stay.",
                size: allocated(folder), action: .emptyFolders([folder]), quitFirst: running.contains(bundle) ? name : nil, reveal: folder)
        }
    }

    private static func apps(running: Set<String>, kept: Set<String>, unusedDays: Int) -> [CleanupItem] {
        let folders = [URL(filePath: "/Applications"), home.appending(path: "Applications")]
        let apps = folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "app" }
        }
        // Programs running now, apps included: an app can work without being opened, through a background helper
        let processes = run("/bin/ps", ["-axo", "comm="]).output.split(separator: "\n").map(String.init)
        return apps.compactMap { app in
            // An uninstaller is how its app's background parts go: it stays until they are gone
            guard let bundle = Bundle(url: app)?.bundleIdentifier, !running.contains(bundle), !protectedApps.contains(bundle), !kept.contains(bundle),
                !app.lastPathComponent.localizedCaseInsensitiveContains("uninstall"), !inBackground(app, bundle: bundle, processes: processes)
            else { return nil }
            let opened = lastOpened(app, bundle: bundle)
            guard isUnused(opened, days: unusedDays) else { return nil }
            let extensions = (try? FileManager.default.contentsOfDirectory(atPath: app.appending(path: "Contents/PlugIns").path))?
                .contains { $0.hasSuffix(".appex") } ?? false
            return CleanupItem(
                id: "app-\(bundle)", group: .apps, name: FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""),
                detail: "\(opened.map { "Last opened \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Never opened")."
                    + (extensions ? " It brings extensions (for Safari, Finder or others) that may work without opening it." : "")
                    + " Moved to the Trash; its settings in your Library stay.",
                size: allocated(app), action: .moveToTrash(app), reveal: app)
        }
        .sorted { $0.size > $1.size }
    }

    /// A program of the app runs now: from inside it, or from its maker's folder (Karabiner runs from
    /// /Library/Application Support/org.pqrs)
    static func inBackground(_ app: URL, bundle: String, processes: [String]) -> Bool {
        // Every macOS program sits under com.apple folders, so Apple's own apps are matched by their path only
        let maker = bundle.split(separator: ".").prefix(2).joined(separator: ".")
        let byMaker = maker.contains(".") && maker != "com.apple"
        return processes.contains { $0.hasPrefix(app.path + "/") || (byMaker && $0.contains("/\(maker)")) }
    }

    /// Big caches not listed above, and space only their own app can free
    private static func other(running: Set<String>, photosTrash: Int64?, listed: [CleanupItem]) -> [CleanupItem] {
        var items: [CleanupItem] = []
        let spotify = caches.appending(path: "com.spotify.client")
        if FileManager.default.fileExists(atPath: spotify.path) {
            items.append(
                CleanupItem(
                    id: "other-spotify", group: .other, name: "Spotify cache",
                    detail: "Clear it in Spotify › Settings › Storage, which keeps your downloaded songs.", size: allocated(spotify),
                    action: .none, reveal: spotify))
        }
        if let photosTrash, photosTrash > 0 {
            items.append(
                CleanupItem(
                    id: "other-photos", group: .other, name: "Photos' Recently Deleted",
                    detail: "About this much stays on this Mac until each item is 30 days old. Delete All in that album frees it now, for good. It no longer counts in iCloud.",
                    size: photosTrash, action: .none))
        }
        // Other apps' caches of 200 MB or more, except macOS's own
        let known = Set(listed.compactMap(\.reveal?.standardizedFileURL.path))
        let folders = (try? FileManager.default.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            let name = folder.lastPathComponent
            guard !name.hasPrefix("com.apple."), !known.contains(folder.standardizedFileURL.path), name != "com.spotify.client",
                !["Google", "Firefox", "BraveSoftware", "Microsoft Edge", "Arc", "Yarn", "pip", "pypoetry", "ms-playwright", "node-gyp",
                  "typescript", "go-build", "CocoaPods", "composer", "Homebrew"].contains(name)
            else { continue }
            let size = allocated(folder)
            guard size >= 200 << 20 else { continue }
            items.append(
                CleanupItem(
                    id: "other-\(name)", group: .other, name: appName(bundle: name) ?? name,
                    detail: "A cache its app fills again as it needs it.", size: size, action: .emptyFolders([folder]),
                    quitFirst: running.contains(name) ? (appName(bundle: name) ?? name) : nil, reveal: folder))
        }
        return items.sorted { $0.size > $1.size }
    }

    // MARK: Large files

    static let defaultLargeFileMegabytes = 500
    /// What the large-file search looks for: the size set in Settings, 500 MB at first
    static var largeFileSize: Int64 {
        let megabytes = UserDefaults.standard.integer(forKey: Settings.Key.largeFileMegabytes.rawValue)
        return Int64(megabytes > 0 ? megabytes : defaultLargeFileMegabytes) << 20
    }

    /// Files and packages (an app, a game) of `minimum` or more in the home folder, biggest first. It reads every
    /// folder, so it takes minutes: what other lines cover is skipped (the Trash, caches, iCloud Drive, the Photos
    /// library), so are folders that only make copies (node_modules, git data, OrbStack's view of its machine)
    /// and other apps' private containers, which macOS would ask about one by one, and the files and folders set to
    /// be skipped. `progress` hears how many items were looked at.
    nonisolated static func largeFiles(minimum: Int64, skipped: [String], progress: @escaping @Sendable (Int) -> Void) -> [LargeFile] {
        let skippedPaths = Set(
            [".Trash", "OrbStack", "Library/Caches", "Library/Containers", "Library/Group Containers", "Library/Mobile Documents",
             "Pictures/Photos Library.photoslibrary"].map { home.appending(path: $0).path }
        ).union(skipped)
        let skippedNames: Set<String> = ["node_modules", ".git"]
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isRegularFileKey, .totalFileAllocatedSizeKey, .contentModificationDateKey, .volumeIdentifierKey]
        let homeVolume = (try? home.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        guard let enumerator = FileManager.default.enumerator(
            at: home, includingPropertiesForKeys: Array(keys), options: [.skipsPackageDescendants], errorHandler: { _, _ in true })
        else { return [] }
        var found: [(URL, Int64, Date?)] = []
        var seen = 0
        for case let url as URL in enumerator {
            seen += 1
            if seen % 5_000 == 0 { progress(seen) }
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if values.isDirectory == true {
                // Another disk mounted inside the home folder holds nothing of this one
                let otherVolume = homeVolume.map { !$0.isEqual(values.volumeIdentifier) } ?? false
                if skippedNames.contains(url.lastPathComponent) || skippedPaths.contains(url.path) || otherVolume {
                    enumerator.skipDescendants()
                } else if values.isPackage == true {
                    let size = allocated(url)
                    if size >= minimum { found.append((url, size, values.contentModificationDate)) }
                }
                continue
            }
            // What the disk holds, not the length a file claims: disk images are mostly empty space
            guard values.isRegularFile == true, !skippedPaths.contains(url.path), let size = values.totalFileAllocatedSize.map(Int64.init),
                size >= minimum
            else { continue }
            found.append((url, size, values.contentModificationDate))
        }
        return found.sorted { $0.1 > $1.1 }.prefix(100).map { LargeFile(path: $0.0.path, size: $0.1, modified: $0.2) }
    }

    /// A line for a file the search found
    nonisolated static func item(_ file: LargeFile) -> CleanupItem {
        let url = URL(filePath: file.path)
        let folder = url.deletingLastPathComponent().path.replacingOccurrences(of: home.path, with: "~")
        let changed = file.modified.map { " · changed \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
        // Inside an app's data, the app keeps track of its files: delete them from it
        if file.path.hasPrefix(home.appending(path: "Library").path + "/") {
            return CleanupItem(
                id: "file-\(file.path)", group: .files, name: url.lastPathComponent,
                detail: "In \(folder)\(changed). Part of an app's data: remove it from that app.", size: file.size, action: .none,
                reveal: url)
        }
        return CleanupItem(
            id: "file-\(file.path)", group: .files, name: url.lastPathComponent, detail: "In \(folder)\(changed).", size: file.size,
            action: .moveToTrash(url), reveal: url)
    }

    // MARK: Helpers

    /// Apps macOS needs or protects
    private static let protectedApps: Set<String> = ["com.apple.Safari", "com.apple.dt.Xcode"]

    static func isUnused(_ opened: Date?, days: Int, now: Date = .now) -> Bool {
        guard let opened else { return true }
        return now.timeIntervalSince(opened) > Double(days) * 86_400
    }

    /// Whether the path is one of `paths` or inside one of them
    static func isInside(_ path: String, _ paths: [String]) -> Bool {
        paths.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    /// Spotlight's record of the last launch, or the newest write to the app's own data (settings, saved
    /// windows, its folders and what they hold), whichever is newer: Spotlight misses some launches. Caches are
    /// left out, macOS touches them all now and then.
    private static func lastOpened(_ app: URL, bundle: String) -> Date? {
        let spotlight = MDItemCreateWithURL(nil, app as CFURL).flatMap { MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date }
        let name = app.deletingPathExtension().lastPathComponent
        let library = home.appending(path: "Library")
        let places = [
            "Preferences/\(bundle).plist", "Saved Application State/\(bundle).savedState", "Containers/\(bundle)",
            "Application Support/\(bundle)", "Application Support/\(name)", "HTTPStorages/\(bundle)",
        ].map { library.appending(path: $0) }
        let written = places.compactMap(modified).max()
        return [spotlight, written].compactMap { $0 }.max()
    }

    /// When a file, a folder or anything right inside the folder last changed
    private static func modified(_ url: URL) -> Date? {
        guard let own = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
        let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return ([own] + children.compactMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }).max()
    }

    /// "com.microsoft.VSCode.ShipIt" → "Visual Studio Code", "notion-updater" → "notion"
    static func updaterName(_ folder: String) -> String {
        if folder.hasSuffix(".ShipIt") {
            let bundle = String(folder.dropLast(".ShipIt".count))
            return appName(bundle: bundle) ?? bundle
        }
        return String(folder.dropLast("-updater".count))
    }

    private static func appName(bundle: String) -> String? {
        guard let path = LaunchServices.path(bundle) else { return nil }
        return FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
    }

    /// Docker's reclaimable bytes by row id, empty when Docker is not running
    private static func dockerReclaimable(_ docker: String? = nil) -> [String: Int64] {
        guard let docker = docker ?? tool("docker", in: ["/usr/local/bin", "/opt/homebrew/bin", home.appending(path: ".orbstack/bin").path])
        else { return [:] }
        let result = run(docker, ["system", "df", "--format", "{{json .}}"])
        guard result.problem == nil else { return [:] }
        let ids = ["Build Cache": "docker-build", "Images": "docker-images", "Containers": "docker-containers", "Local Volumes": "docker-volumes"]
        var sizes: [String: Int64] = [:]
        for line in result.output.split(separator: "\n") {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String], let type = row["Type"],
                let id = ids[type], let reclaimable = row["Reclaimable"]
            else { continue }
            sizes[id] = dockerBytes(reclaimable)
        }
        return sizes
    }

    /// Docker's sizes, in powers of 1000: "187.9MB (2%)" → 187,900,000
    static func dockerBytes(_ text: String) -> Int64 {
        let value = text.split(separator: " ").first.map(String.init) ?? text
        let units: [(String, Double)] = [("kB", 1e3), ("KB", 1e3), ("MB", 1e6), ("GB", 1e9), ("TB", 1e12), ("B", 1)]
        for (unit, factor) in units where value.hasSuffix(unit) {
            return Int64((Double(value.dropLast(unit.count)) ?? 0) * factor)
        }
        return 0
    }

    private static func tool(_ name: String, in folders: [String]) -> String? {
        folders.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func run(_ tool: String, _ arguments: [String]) -> (output: String, problem: String?) {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        // Tools look for their helpers on the PATH, which an app launched from Finder barely has
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(home.path)/.orbstack/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return ("", error.localizedDescription)
        }
        // Read both pipes while it runs, so neither fills up and stalls the tool
        let errorText = Locked(Data())
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global().async {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            errorText.update { $0 = data }
            reading.leave()
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        reading.wait()
        let problem = String(decoding: errorText.value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, process.terminationStatus == 0 ? nil : (problem.isEmpty ? "\(URL(filePath: tool).lastPathComponent) failed" : problem))
    }

    /// What the disk holds for a file or folder and everything inside it
    static func allocated(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isDirectory != true { return Int64(values.totalFileAllocatedSize ?? 0) }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        else { return 0 }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            total += Int64((try? child.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

/// Where an app with a bundle id is installed, without touching AppKit off the main thread
enum LaunchServices {
    static func path(_ bundle: String) -> String? {
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(bundle as CFString, nil)?.takeRetainedValue() as? [URL] else { return nil }
        return urls.first?.path
    }
}
