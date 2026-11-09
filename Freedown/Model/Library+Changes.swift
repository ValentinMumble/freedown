import os
import Photos

private let log = Logger(subsystem: "com.valentinmumble.freedown", category: "library")

/// Every change the app makes to the library: deletions, favorites, dates, and the items it replaces by a
/// lighter version.
extension Library {
    /// Deletes for real: macOS asks for confirmation, and the items go to Recently Deleted for 30 days.
    /// Whether they were deleted: macOS's confirmation can be refused
    @discardableResult
    func delete(_ targets: [Item]) async -> Bool {
        let assets = targets.map(\.asset) as NSArray
        guard await change({ PHAssetChangeRequest.deleteAssets(assets) }) else { return false }
        // A shrunk original frees only what its copy does not take back
        let shrunk = targets.filter { shrinkRecords[$0.id]?.copy != nil }
        let others = targets.filter { shrinkRecords[$0.id]?.copy == nil }
        addSaving(.shrunk, shrunk.count, shrunk.reduce(0) { $0 + max(0, $1.size - (shrinkRecords[$1.id]?.after ?? 0)) })
        addSaving(.deleted, others.count, others.reduce(0) { $0 + $1.size })
        return true
    }

    func setFavorite(_ targets: [Item], _ favorite: Bool) async {
        await change {
            for item in targets { PHAssetChangeRequest(for: item.asset).isFavorite = favorite }
        }
    }

    func setDates(_ changes: [(Item, Date)]) async {
        await change {
            for (item, date) in changes { PHAssetChangeRequest(for: item.asset).creationDate = date }
        }
    }

    /// Whether the change went through
    @discardableResult
    private func change(_ block: @escaping () -> Void) async -> Bool {
        do {
            try await PHPhotoLibrary.shared().performChanges(block)
        } catch let failure as NSError where failure.domain == PHPhotosErrorDomain
            && failure.code == PHPhotosError.userCancelled.rawValue
        {
            return false
        } catch {
            self.error = error.localizedDescription
            return false
        }
        await reload()
        return true
    }

    struct ReplaceOutcome {
        var replaced = 0
        var freed: Int64 = 0
        var failed: [String] = []
        /// New items that do not hold what they should, read back from Photos
        var warnings: [String] = []
        var cancelled = false
    }

    /// One confirmation per this many items: big enough to stay rare, small enough to keep each change light
    private static let replaceBatch = 200

    /// Replaces items by their current version alone (see Replacement). `progress` gets a message and how
    /// many items are done.
    func replace(_ targets: [Item], kind: Replacement, progress: @escaping (String, Int) -> Void) async -> ReplaceOutcome {
        var outcome = ReplaceOutcome()
        let folder = FileManager.default.temporaryDirectory.appending(path: "freedown-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var done = 0
        var refusals: [String: String] = [:]
        for start in stride(from: 0, to: targets.count, by: Self.replaceBatch) {
            var entries: [Replacer.Entry] = []
            for item in targets[start..<min(start + Self.replaceBatch, targets.count)] {
                progress("Getting the current version of each item from Photos…", done)
                do {
                    entries.append(try await Task.detached { try await kind.export(item, to: folder) }.value)
                } catch {
                    log.error("Could not export \(item.filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    outcome.failed.append("\(item.filename) (\(error.localizedDescription))")
                    if let refusal = error as? Stills.Refusal { refusals[item.id] = refusal.reason }
                }
                done += 1
            }
            guard !entries.isEmpty else { continue }
            progress("Waiting for you to confirm the deletion…", done)
            do {
                let created = try await Task.detached { [entries] in try await Replacer.replace(entries) }.value
                // What really changed, read back from Photos, not what was expected
                let check = await Task.detached { [entries] in Replacer.check(entries, created: created) }.value
                outcome.replaced += entries.count
                outcome.freed += check.freed
                outcome.warnings += check.warnings
                addSaving(kind.savingKind, entries.count, check.freed)
            } catch let failure as NSError where failure.domain == PHPhotosErrorDomain
                && failure.code == PHPhotosError.userCancelled.rawValue
            {
                outcome.cancelled = true
                break
            } catch {
                self.error = error.localizedDescription
                break
            }
            for entry in entries { try? FileManager.default.removeItem(at: entry.file.deletingLastPathComponent()) }
        }
        // Before the reload, so the refused photos leave the list with it, also after a refused batch
        rememberHEICRefusals(refusals)
        await reload()
        return outcome
    }

    struct SplitOutcome {
        var split = 0
        var failed: [String] = []
        var cancelled = false
    }

    /// Splits half-frame scans into their two photos (see HalfFrame), a batch per confirmation. `progress` gets a
    /// message and how many scans are done.
    func splitHalfFrames(_ scans: [HalfFrameScan], progress: @escaping (String, Int) -> Void) async -> SplitOutcome {
        var outcome = SplitOutcome()
        let folder = FileManager.default.temporaryDirectory.appending(path: "freedown-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var done = 0
        for start in stride(from: 0, to: scans.count, by: Self.replaceBatch) {
            var splits: [(scan: PHAsset, halves: [URL])] = []
            for scan in scans[start..<min(start + Self.replaceBatch, scans.count)] {
                progress("Cutting each scan in two…", done)
                do {
                    let halves = try await Task.detached {
                        let entry = try await Replacer.exportCurrent(scan.item, to: folder)
                        return try HalfFrame.split(entry.file, gap: scan.gap, turns: scan.turns, to: entry.file.deletingLastPathComponent())
                    }.value
                    splits.append((scan.item.asset, halves))
                } catch {
                    log.error("Could not split \(scan.item.filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    outcome.failed.append("\(scan.item.filename) (\(error.localizedDescription))")
                }
                done += 1
            }
            guard !splits.isEmpty else { continue }
            progress("Waiting for you to confirm…", done)
            do {
                try await Task.detached { [splits] in try await HalfFrame.replace(splits) }.value
                outcome.split += splits.count
            } catch let failure as NSError where failure.domain == PHPhotosErrorDomain
                && failure.code == PHPhotosError.userCancelled.rawValue
            {
                outcome.cancelled = true
                break
            } catch {
                self.error = error.localizedDescription
                break
            }
        }
        await reload()
        return outcome
    }
}
