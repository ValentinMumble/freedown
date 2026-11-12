import AppKit
import Observation
import os
import Photos

private let log = Logger(subsystem: "com.valentinmumble.freedown", category: "library")

/// The Photos library as the app shows it. Reading it is in LibraryScan, changing it in Library+Changes, and
/// what Vision and the picture hashes find in it in Analysis.
@MainActor
@Observable
final class Library {
    enum State: Equatable {
        case starting
        case denied
        case loading(done: Int, total: Int)
        case ready
    }

    struct Tally {
        var count = 0
        var size: Int64 = 0
        /// What replacing every item by its current version alone would free
        var saving: Int64 = 0
    }

    private(set) var state: State = .starting
    private(set) var items: [Item] = []
    private(set) var itemsById: [String: Item] = [:]
    private(set) var duplicateGroups: [ItemGroup] = []
    private(set) var tallies: [Destination: Tally] = [:]
    private(set) var storage: ICloudStorage?
    private(set) var recentlyDeleted: Result<RecentlyDeleted, RecentlyDeleted.Failure>?
    private(set) var shrinkRecords: [String: ShrinkRecord] = ShrinkRecords.load()
    private(set) var shrinkStatus = ShrinkStatus()
    /// Live Photos picked one by one for Remove Motion, kept across launches until it is done
    private(set) var marked: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: Settings.Key.markedForRemoveMotion.rawValue) ?? [])
    private(set) var savings: [Saving] = Savings.load()
    private(set) var storageReadings: [StorageReading] = StorageHistory.load()
    /// Photos a HEIC conversion refused, with why: they are not offered again
    private(set) var heicRefusals: [String: String] = Settings.read([String: String].self, from: heicRefusalsFile) ?? [:]
    private static let heicRefusalsFile = "heic-refused.json"
    let analysis = Analysis()
    /// The biggest files in iCloud Drive (see ICloudDrive): nil until read
    private(set) var driveFiles: [DriveFile]?
    var error: String?

    @ObservationIgnored private var resources = CachedResources.load()
    @ObservationIgnored private var observer: ChangeObserver?
    @ObservationIgnored private var pendingReload: Task<Void, Never>?

    /// What the destinations need besides the item itself
    var listContext: ListContext { ListContext(lifeless: analysis.lifeless ?? [], accidental: analysis.accidental ?? []) }

    func start() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            state = .denied
            return
        }
        // Changes made in Photos (or by this app) show up here a moment later
        observer = ChangeObserver { [weak self] in
            Task { @MainActor in self?.scheduleReload() }
        }
        await reload()
        await scanDrive()
    }

    func scheduleReload() {
        pendingReload?.cancel()
        pendingReload = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    func reload() async {
        let started = Date.now
        let cached = resources
        let refused = Set(heicRefusals.keys)
        let firstLoad = items.isEmpty
        let (loaded, nextResources, read) = await Task.detached(priority: .userInitiated) {
            LibraryScan.fetch(cached: cached, heicRefused: refused) { done, total in
                guard firstLoad else { return }
                Task { @MainActor in self.state = .loading(done: done, total: total) }
            }
        }.value
        // Written only when Photos was asked about something, or items went away
        if read > 0 || nextResources.count != resources.count {
            Task.detached(priority: .utility) { CachedResources.save(nextResources) }
        }
        resources = nextResources
        items = loaded
        itemsById = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        // A mark is done once its photo is gone or no longer live (its motion was removed)
        let stillMarked = marked.filter { itemsById[$0]?.live == true }
        if stillMarked != marked {
            marked = stillMarked
            saveMarks()
        }
        shrinkStatus = ShrinkStatus(records: shrinkRecords)
        tallies = LibraryScan.tallies(loaded, in: listContext)
        state = .ready
        duplicateGroups = await Task.detached { LibraryScan.duplicateGroups(loaded) }.value
        let total = loaded.reduce(0) { $0 + $1.size }
        log.notice(
            "Loaded \(loaded.count) items, \(Format.bytes(total)), \(self.duplicateGroups.count) duplicate groups, in \(Date.now.timeIntervalSince(started), format: .fixed(precision: 1))s"
        )
        await analysis.refresh(loaded)
        tallies = LibraryScan.tallies(loaded, in: listContext)
        await refreshStorage()
        log.notice(
            "iCloud: \(self.storage?.apps.count ?? 0) apps, plan \(self.storage?.total ?? 0), free \(self.storage?.free ?? 0)")
    }

    // MARK: Analyses

    func findSimilar() async {
        await analysis.findSimilar(items)
    }

    func findSubjects() async {
        await analysis.findSubjects(items)
        tallies = LibraryScan.tallies(items, in: listContext)
    }

    func findHalfFrames() async {
        await analysis.findHalfFrames(items)
    }

    func findAccidental() async {
        await analysis.findAccidental(items)
        tallies = LibraryScan.tallies(items, in: listContext)
    }

    // MARK: This Mac

    /// What can go to free disk space on this Mac (see Cleanup): nil until measured
    private(set) var cleanupItems: [CleanupItem]?
    /// Big files from the last search, the launch before included: nil until one ran
    private(set) var largeFiles: [CleanupItem]?
    /// When that search ran, and the smallest size it looked for
    private(set) var largeFilesSearched: Date?
    private(set) var largeFilesMinimum: Int64?
    /// How many items the large-file search looked at, while it runs
    private(set) var largeFilesProgress: Int?
    /// Apps Clean Up never offers, by bundle id
    private(set) var keptApps: [String] = Settings.list(.keptApps)
    /// Files and folders the large-file search leaves out
    private(set) var skippedPaths: [String] = Settings.list(.skippedPaths)

    init() {
        // The last search, without the files gone or skipped since: a stat per file, no folder is read again
        if let search = LargeFileSearch.load() {
            largeFiles = search.present.filter { !Cleanup.isInside($0.path, skippedPaths) }.map(Cleanup.item)
            largeFilesSearched = search.date
            largeFilesMinimum = search.minimum ?? 500 << 20
        }
    }

    func findLargeFiles() async {
        largeFilesProgress = 0
        let minimum = Cleanup.largeFileSize
        let skipped = skippedPaths
        let found = await Task.detached(priority: .utility) {
            Cleanup.largeFiles(minimum: minimum, skipped: skipped) { seen in Task { @MainActor in self.largeFilesProgress = seen } }
        }.value
        let search = LargeFileSearch(date: .now, minimum: minimum, files: found)
        largeFiles = found.map(Cleanup.item)
        largeFilesSearched = search.date
        largeFilesMinimum = minimum
        largeFilesProgress = nil
        Task.detached(priority: .utility) { search.save() }
    }

    func scanCleanup() async {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let photosTrash = (try? recentlyDeleted?.get())?.size
        let kept = Set(keptApps)
        let unusedDays = Cleanup.unusedDays
        cleanupItems = await Task.detached(priority: .userInitiated) {
            Cleanup.scan(running: running, photosTrash: photosTrash, kept: kept, unusedDays: unusedDays)
        }.value
    }

    /// Never offers the app again, and takes its line away now
    func keepApp(_ item: CleanupItem) {
        guard let bundle = item.appBundle, !keptApps.contains(bundle) else { return }
        keptApps.append(bundle)
        Settings.setList(keptApps, .keptApps)
        cleanupItems = cleanupItems?.filter { $0.id != item.id }
    }

    /// Offers the app again, if unused, once Clean Up has measured again
    func unkeepApp(_ bundle: String) {
        keptApps.removeAll { $0 == bundle }
        Settings.setList(keptApps, .keptApps)
        rework(.cleanup)
    }

    /// Leaves the file or folder out of later searches, and out of the list now
    func skip(_ path: String) {
        guard !skippedPaths.contains(path) else { return }
        skippedPaths.append(path)
        Settings.setList(skippedPaths, .skippedPaths)
        largeFiles = largeFiles?.filter { !Cleanup.isInside($0.reveal?.path ?? "", [path]) }
    }

    /// Looked at again from the next search on
    func unskip(_ path: String) {
        skippedPaths.removeAll { $0 == path }
        Settings.setList(skippedPaths, .skippedPaths)
    }

    /// What a change in Settings affects
    enum Rework { case cleanup, drive, analysis }
    @ObservationIgnored private var pendingRework: [Rework: Task<Void, Never>] = [:]

    /// Works out again what a change in Settings affects, a second after the last change: a stepper clicked
    /// five times runs it once
    func rework(_ part: Rework) {
        pendingRework[part]?.cancel()
        pendingRework[part] = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            switch part {
            case .cleanup: if cleanupItems != nil { await scanCleanup() }
            case .drive: if driveFiles != nil { await scanDrive() }
            case .analysis: await analysis.refresh(items)
            }
        }
    }

    /// Cleans one item, then measures it and the Trash again, which gets what goes to it. Returns what was
    /// freed, or why not.
    func clean(_ item: CleanupItem) async -> String {
        let trash = cleanupItems?.first { $0.group == .trash }
        let (problem, after, trashAfter) = await Task.detached(priority: .userInitiated) {
            let problem = Cleanup.clean(item)
            return (problem, Cleanup.measure(item), trash.map(Cleanup.measure))
        }.value
        let update = { (current: CleanupItem) -> CleanupItem in
            if current.id == item.id { return current.measured(after) }
            if current.id == trash?.id, let trashAfter { return current.measured(trashAfter) }
            return current
        }
        cleanupItems = cleanupItems?.map(update)
        largeFiles = largeFiles?.map(update)
        let freed = max(0, item.size - after)
        // Moving to the Trash frees nothing yet: it counts once the Trash is emptied
        if freed > 0 {
            switch item.action {
            case .emptyTrash: addSaving(.deletedOnMac, item.count, freed)
            case .emptyFolders, .command: addSaving(item.refills ? .clearedCaches : .deletedOnMac, item.count, freed)
            case .moveToTrash, .none: break
            }
        }
        if let problem { return freed > 0 ? "Freed \(Format.bytes(freed)), then: \(problem)" : problem }
        if case .moveToTrash = item.action { return "In the Trash" }
        return "Freed \(Format.bytes(freed))"
    }

    // MARK: iCloud Drive

    func scanDrive() async {
        let minimum = ICloudDrive.minimum
        driveFiles = await Task.detached(priority: .userInitiated) { ICloudDrive.scan(minimum: minimum) }.value
    }

    /// Moves files to the Trash and counts what left iCloud. Returns why some could not go.
    func trash(_ files: [DriveFile]) async -> [String] {
        let (trashed, failed) = await Task.detached { ICloudDrive.trash(files) }.value
        addSaving(.deletedFiles, trashed.count, trashed.reduce(0) { $0 + $1.size })
        await scanDrive()
        return failed
    }

    // MARK: Marks

    /// Marks the Live Photos among `targets` for Remove Motion, or unmarks them when they all are already
    func toggleMark(_ targets: [Item]) {
        let ids = targets.filter(\.live).map(\.id)
        guard !ids.isEmpty else { return }
        if ids.allSatisfy(marked.contains) { marked.subtract(ids) } else { marked.formUnion(ids) }
        saveMarks()
    }

    private func saveMarks() {
        UserDefaults.standard.set(Array(marked), forKey: Settings.Key.markedForRemoveMotion.rawValue)
    }

    /// Takes effect at the next reload
    func rememberHEICRefusals(_ refusals: [String: String]) {
        guard !refusals.isEmpty else { return }
        heicRefusals.merge(refusals) { _, new in new }
        Settings.write(heicRefusals, to: Self.heicRefusalsFile)
    }

    // MARK: Saved space

    func addSaving(_ kind: Saving.Kind, _ count: Int, _ bytes: Int64) {
        guard count > 0 else { return }
        savings.append(Saving(date: .now, kind: kind, count: count, bytes: bytes))
        Savings.save(savings)
    }

    /// Starts the saved-space totals again from zero
    func clearSavings() {
        savings = []
        Savings.save(savings)
    }

    /// iCloud storage changes outside the library too (a deleted backup), so it is read again on its own
    func refreshStorage() async {
        storage = await Task.detached { ICloudStorage.read() }.value
        if let free = storage?.free {
            let readings = StorageHistory.adding(free, to: storageReadings)
            if readings.count != storageReadings.count {
                storageReadings = readings
                StorageHistory.save(readings)
            }
        }
        // Read with it, so emptying Recently Deleted in Photos shows when coming back
        recentlyDeleted = await Task.detached { RecentlyDeleted.read() }.value
    }

    // MARK: Shrinking

    func saveShrinkRecord(_ record: ShrinkRecord) {
        shrinkRecords[record.original] = record
        ShrinkRecords.save(shrinkRecords)
        shrinkStatus = ShrinkStatus(records: shrinkRecords)
        tallies = LibraryScan.tallies(items, in: listContext)
    }

    /// Why a video cannot be shrunk, or nil
    func shrinkSkip(_ item: Item) -> String? {
        if item.kind != .video { return "not a video" }
        if item.slowMotion { return "slow motion: the copy would lose it" }
        if shrinkStatus.shrunk.contains(item.id) { return "already shrunk" }
        if shrinkStatus.copies[item.id] != nil { return "is a shrunk copy" }
        return nil
    }

    /// A video left to try: it can be shrunk, and no copy was made or refused before
    func shrinkUntried(_ item: Item) -> Bool {
        shrinkSkip(item) == nil && !shrinkStatus.kept.contains(item.id)
    }

    /// What shrinking did to a video, whether it is the original or the copy
    func shrinkRecord(_ item: Item) -> ShrinkRecord? {
        shrinkRecords[item.id] ?? shrinkStatus.copies[item.id].flatMap { shrinkRecords[$0] }
    }
}
