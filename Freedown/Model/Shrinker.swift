import Foundation
import Observation
import os
import Photos

private let log = Logger(subsystem: "com.valentinmumble.freedown", category: "shrink")

/// Shrinks videos one at a time. Nothing is deleted here: the copies go into Photos next to the originals,
/// and the Shrinking view deletes the originals when asked. The steps of one shrink are in ShrinkPipeline.
@MainActor
@Observable
final class Shrinker {
    enum Phase: String {
        case queued, downloading, encoding, checking, importing, done, kept, failed, cancelled

        var active: Bool { [.queued, .downloading, .encoding, .checking, .importing].contains(self) }

        var label: String {
            switch self {
            case .queued: "Waiting"
            case .downloading: "Getting the original from Photos"
            case .encoding: "Encoding"
            case .checking: "Checking quality"
            case .importing: "Saving the copy to Photos"
            case .done: "Copy saved to Photos"
            case .kept: "Not shrunk"
            case .failed: "Failed"
            case .cancelled: "Cancelled"
            }
        }
    }

    struct Job: Identifiable {
        let id = UUID()
        let item: Item
        let preset: ShrinkPreset
        /// Read when the job is queued, so changing the setting later leaves it alone
        let minQuality: Double
        var phase = Phase.queued
        var progress = 0.0
        /// How much of the video has come from Photos: it can start before the job's turn, and is 1 once done
        var downloaded: Double?
        var record: ShrinkRecord?
        var error: String?
    }

    /// A job's video being fetched from Photos into a folder of its own, possibly ahead of its turn
    private struct Download {
        let jobId: UUID
        let folder: URL
        let file: Task<URL, Error>

        func discard() {
            file.cancel()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Keep a copy only when it is at least this much smaller
    nonisolated static let defaultMinSavingPercent = 20
    /// The smallest saving that keeps a shrunk video or a HEIC copy: set in Settings, 20% at first
    nonisolated static var minSaving: Double { Settings.number(.minSavingPercent, Double(defaultMinSavingPercent)) / 100 }
    nonisolated static var minSavingText: String { "\(Int((minSaving * 100).rounded()))%" }

    private(set) var jobs: [Job] = [] {
        didSet { saveQueue() }
    }
    /// Videos deleted while they were being shrunk: their entry goes once the job stops
    @ObservationIgnored private var forgotten: Set<String> = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    /// The videos last written to the queue file, so it is written only when the queue changes
    @ObservationIgnored private var savedQueue: [String] = []
    private let library: Library

    init(library: Library) {
        self.library = library
    }

    var running: Int { jobs.filter(\.phase.active).count }

    func enqueue(_ items: [Item], preset: ShrinkPreset) {
        let busy = Set(jobs.filter(\.phase.active).map(\.item.id))
        jobs += items.filter { !busy.contains($0.id) && library.shrinkSkip($0) == nil }.map { Job(item: $0, preset: preset, minQuality: preset.minQuality) }
        Notifier.ask()
        if worker == nil { worker = Task { await work() } }
    }

    func cancelWaiting() {
        for index in jobs.indices where jobs[index].phase == .queued { jobs[index].phase = .cancelled }
    }

    /// Deleted videos leave the list: waiting or finished ones at once, the one being shrunk when it stops
    func forget(_ items: [Item]) {
        let ids = Set(items.map(\.id))
        forgotten.formUnion(ids)
        jobs.removeAll { ids.contains($0.item.id) && ($0.phase == .queued || !$0.phase.active) }
    }

    func clearFinished() {
        jobs.removeAll { !$0.phase.active }
    }

    /// Videos downloaded ahead of their turn
    private static let downloadsAhead = 2

    private func work() async {
        var ahead: [Download] = []
        var finished: [UUID] = []
        while let job = jobs.first(where: { $0.phase == .queued }) {
            // Deleted while it waited, in Photos for one: nothing left to shrink
            guard library.itemsById[job.item.id] != nil else {
                jobs.removeAll { $0.id == job.id }
                continue
            }
            let download: Download
            if let index = ahead.firstIndex(where: { $0.jobId == job.id }) {
                download = ahead.remove(at: index)
            } else {
                download = startDownload(job)
            }
            // The next videos download while this one is shrunk, so each is ready when its turn comes
            let upcoming = Set(jobs.filter { $0.phase == .queued && $0.id != job.id }.prefix(Self.downloadsAhead).map(\.id))
            for stale in ahead where !upcoming.contains(stale.jobId) { stale.discard() }
            ahead.removeAll { !upcoming.contains($0.jobId) }
            for next in jobs where upcoming.contains(next.id) && !ahead.contains(where: { $0.jobId == next.id }) {
                ahead.append(startDownload(next))
            }
            await run(job, download)
            finished.append(job.id)
        }
        for download in ahead { download.discard() }
        worker = nil
        notifyDone(finished)
    }

    private func notifyDone(_ finished: [UUID]) {
        let ids = Set(finished)
        let ended = jobs.filter { ids.contains($0.id) }
        guard !ended.isEmpty else { return }
        let saved = ended.filter { $0.phase == .done }
        let freed = saved.reduce(Int64(0)) { $0 + max(0, ($1.record?.before ?? 0) - ($1.record?.after ?? 0)) }
        var parts = ["\(Format.count(saved.count, "video")) shrunk, \(Format.bytes(freed)) to free once the originals are deleted."]
        let review = ended.filter { $0.record?.reviewable == true }.count
        if review > 0 { parts.append("\(review) refused, to review in Shrinking.") }
        let failed = ended.filter { $0.phase == .failed }.count
        if failed > 0 { parts.append("\(failed) failed.") }
        Notifier.post("Shrinking done", parts.joined(separator: " "))
    }

    private func startDownload(_ job: Job) -> Download {
        let id = job.id
        let item = job.item
        let folder = FileManager.default.temporaryDirectory.appending(path: "freedown-\(UUID().uuidString)")
        let file = Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // The video as Photos shows it, so an edited one (rotated, trimmed) keeps its edit in the copy
            let source = try await Replacer.exportCurrent(item, to: folder) { fraction in
                // Reports can arrive out of order: never step back
                Task { @MainActor in self.update(id) { $0.downloaded = max($0.downloaded ?? 0, fraction) } }
            }.file
            await MainActor.run { self.update(id) { $0.downloaded = 1 } }
            return source
        }
        return Download(jobId: id, folder: folder, file: file)
    }

    private func run(_ job: Job, _ download: Download) async {
        let id = job.id
        let folder = download.folder
        defer { try? FileManager.default.removeItem(at: folder) }
        update(id) { $0.phase = .downloading }
        do {
            let source = try await download.file.value
            let record = try await Task.detached(priority: .utility) {
                try await Shrinker.shrink(
                    job.item, source: source, preset: job.preset, minQuality: job.minQuality, in: folder
                ) { phase, progress in
                    Task { @MainActor in
                        // A late progress report must not undo the final state
                        self.update(id) { job in
                            guard job.phase.active else { return }
                            job.phase = phase
                            job.progress = progress
                        }
                    }
                }
            }.value
            library.saveShrinkRecord(record)
            log.notice("Shrunk \(record.name, privacy: .public): \(record.summary, privacy: .public), \(record.kept ?? "copy saved", privacy: .public)")
            update(id) { job in
                job.record = record
                job.phase = record.copy == nil ? .kept : .done
                job.progress = 1
            }
        } catch {
            log.error("Shrink failed for \(job.item.filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
            // Deleted from here while it was being shrunk: the entry goes with it
            if forgotten.contains(job.item.id) {
                jobs.removeAll { $0.id == id }
                return
            }
            update(id) { job in
                job.phase = .failed
                job.error = error.localizedDescription
            }
        }
    }

    /// Saves a copy refused for its quality score after all, from the file kept aside for comparing
    func saveAnyway(_ record: ShrinkRecord) async throws {
        guard let file = ShrinkRecords.preview(record), let original = library.itemsById[record.original] else {
            throw FFmpeg.Failure(message: "the copy or the original is no longer there")
        }
        let copyId = try await Shrinker.importCopy(file, like: original.asset)
        library.saveShrinkRecord(
            ShrinkRecord(
                original: record.original, name: record.name, copy: copyId, kept: nil, before: record.before,
                after: record.after, vmaf: record.vmaf, minQuality: record.minQuality, preset: record.preset, from: record.from, to: record.to,
                date: .now))
        ShrinkRecords.discardPreview(record)
        log.notice("Saved \(record.name, privacy: .public) anyway: \(record.summary, privacy: .public)")
    }

    // MARK: Queue across launches

    private struct SavedJob: Codable {
        let item: String
        let preset: ShrinkPreset
        let minQuality: Double
    }

    private static let queueFile = Settings.supportFolder.appending(path: "queue.json")

    /// The waiting and running jobs, written whenever that list changes, so quitting the app keeps the queue
    private func saveQueue() {
        let active = jobs.filter(\.phase.active)
        let ids = active.map(\.item.id)
        guard ids != savedQueue else { return }
        savedQueue = ids
        let saved = active.map { SavedJob(item: $0.item.id, preset: $0.preset, minQuality: $0.minQuality) }
        try? FileManager.default.createDirectory(at: Settings.supportFolder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(saved).write(to: Self.queueFile)
    }

    /// Puts back what a quit left in the queue, once the library has loaded. A video being shrunk then starts over.
    func restoreQueue() {
        guard let data = try? Data(contentsOf: Self.queueFile),
            let saved = try? JSONDecoder().decode([SavedJob].self, from: data)
        else { return }
        let busy = Set(jobs.map(\.item.id))
        jobs += saved.compactMap { job in
            guard let item = library.itemsById[job.item], !busy.contains(item.id), library.shrinkSkip(item) == nil else { return nil }
            return Job(item: item, preset: job.preset, minQuality: job.minQuality)
        }
        if worker == nil, jobs.contains(where: { $0.phase == .queued }) { worker = Task { await work() } }
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        if let index = jobs.firstIndex(where: { $0.id == id }) { change(&jobs[index]) }
    }
}
