import Foundation
import Photos

/// The steps of one shrink, off the main thread: encode, check, keep the copy aside or save it to Photos.
extension Shrinker {
    nonisolated static func shrink(
        _ item: Item, source: URL, preset: ShrinkPreset, minQuality: Double, in folder: URL,
        report: @escaping (Phase, Double) -> Void
    ) async throws -> ShrinkRecord {
        let original = try FFmpeg.probe(source)

        report(.encoding, 0)
        let outputFolder = folder.appending(path: "out")
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        let output = outputFolder.appending(path: source.deletingPathExtension().lastPathComponent + ".mov")
        try FFmpeg.encode(source, to: output, crf: preset.crf, duration: original.duration) { report(.encoding, $0) }
        let copy = try FFmpeg.probe(output)

        let before = try fileSize(source)
        let after = try fileSize(output)
        func record(copy copyId: String? = nil, kept: String? = nil, vmaf: Double? = nil, aside: Bool = false) -> ShrinkRecord {
            ShrinkRecord(
                original: item.id, name: item.filename, copy: copyId, kept: kept, before: before, after: after,
                vmaf: vmaf, minQuality: minQuality, keptAside: aside, preset: preset, from: original.summary,
                to: copy.summary, date: .now)
        }
        // Refused, but worth a look: the copy waits until it is saved anyway or discarded
        func keepAside() throws {
            let preview = ShrinkRecords.preview(original: item.id, name: item.filename)
            try? FileManager.default.removeItem(at: preview.deletingLastPathComponent())
            try FileManager.default.createDirectory(at: preview.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: output, to: preview)
        }
        let saving = 1 - Double(after) / Double(before)
        if after >= before {
            let bigger = (Double(after) / Double(before) - 1) * 100
            return record(kept: bigger < 1 ? "the copy is no smaller" : "the copy is \(Int(bigger.rounded()))% bigger")
        }
        // Beyond the frame rule the quality check cannot pair the frames, so the copy waits for a look instead
        if !framesMatch(copy.frames, original.frames) {
            try keepAside()
            return record(
                kept: "it has \(copy.frames) frames instead of \(original.frames), so its quality could not be measured", aside: true)
        }

        report(.checking, 1)
        let score = try FFmpeg.vmaf(output, against: source)
        // Too small a saving to be worth a copy on its own, but still smaller: the copy waits for a look
        if saving < minSaving {
            try keepAside()
            return record(kept: "the copy saves only \(Int(saving * 100))%", vmaf: score, aside: true)
        }
        if score < minQuality {
            try keepAside()
            return record(kept: "the copy would look softer (quality \(score), below \(Int(minQuality)))", vmaf: score, aside: true)
        }

        report(.importing, 1)
        // Deleted while it was being shrunk: a copy would be an orphan
        guard PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil).count > 0 else {
            throw FFmpeg.Failure(message: "the original was deleted meanwhile, so no copy was saved")
        }
        let copyId = try await importCopy(output, like: item.asset)
        return record(copy: copyId, vmaf: score)
    }

    /// One frame short is allowed: x265 sometimes drops the last one
    nonisolated static func framesMatch(_ copy: Int, _ original: Int) -> Bool {
        abs(copy - original) <= 1
    }

    /// Saves the copy with the original's date, place and favorite, in the same albums
    nonisolated static func importCopy(_ file: URL, like original: PHAsset) async throws -> String {
        let placeholder = Locked<String?>(nil)
        let albums = PHAssetCollection.fetchAssetCollectionsContaining(original, with: .album, options: nil)
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = file.lastPathComponent
            request.addResource(with: .video, fileURL: file, options: options)
            request.creationDate = original.creationDate
            request.location = original.location
            request.isFavorite = original.isFavorite
            guard let created = request.placeholderForCreatedAsset else { return }
            placeholder.update { $0 = created.localIdentifier }
            albums.enumerateObjects { album, _, _ in
                if album.canPerform(.addContent) {
                    PHAssetCollectionChangeRequest(for: album)?.addAssets([created] as NSArray)
                }
            }
        }
        guard let id = placeholder.value else { throw FFmpeg.Failure(message: "Photos did not save the copy") }
        return id
    }

    nonisolated static func fileSize(_ file: URL) throws -> Int64 {
        (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
}
