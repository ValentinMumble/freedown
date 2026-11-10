import CoreLocation
import Photos

/// A photo or video of the library, with what PhotoKit only tells through its resources.
struct Item: Identifiable, Hashable {
    enum Kind { case photo, video }

    let id: String
    let asset: PHAsset
    let kind: Kind
    let date: Date
    let filename: String
    /// Bytes iCloud stores for it: the original, the motion of a Live Photo, saved edits
    let size: Int64
    let originalSize: Int64
    let editedSize: Int64
    let motionSize: Int64
    /// A Live Photo's motion as Photos plays it: the edited clip, or the original one
    let currentMotionSize: Int64
    let width: Int
    let height: Int
    let duration: TimeInterval
    let favorite: Bool
    let edited: Bool
    let onlyRotated: Bool
    let screenshot: Bool
    let live: Bool
    let slowMotion: Bool
    let location: CLLocation?
    /// Photos' last change to it: a new date means a new picture to analyse
    let modified: Date?
    /// Converted to HEIC once and refused: it stays a JPEG
    let heicRefused: Bool

    init(asset: PHAsset, resources: Resources, heicRefused: Bool = false) {
        id = asset.localIdentifier
        self.asset = asset
        kind = asset.mediaType == .video ? .video : .photo
        date = asset.creationDate ?? .distantPast
        filename = resources.filename
        size = resources.size
        originalSize = resources.originalSize
        editedSize = resources.editedSize
        motionSize = resources.motionSize
        currentMotionSize = resources.editedMotionSize > 0 ? resources.editedMotionSize : resources.originalMotionSize
        width = asset.pixelWidth
        height = asset.pixelHeight
        duration = asset.duration
        favorite = asset.isFavorite
        edited = resources.edited
        // Without a rendered version there is no extra copy to free
        onlyRotated = resources.onlyRotated && resources.editedSize > 0
        screenshot = asset.mediaSubtypes.contains(.photoScreenshot)
        live = asset.mediaSubtypes.contains(.photoLive)
        slowMotion = asset.mediaSubtypes.contains(.videoHighFrameRate)
        location = asset.location
        modified = asset.modificationDate
        self.heicRefused = heicRefused
    }

    /// A still that keeps a motion clip Photos no longer plays: what Remove Motion left behind before it saved
    /// stills as new files
    var hiddenMotion: Bool { kind == .photo && !live && motionSize > 0 }

    /// Where the analyses keep their answers: the item as it is now, so an edit asks again
    var analysisKey: String { "\(id)|\(modified?.timeIntervalSinceReferenceDate ?? 0)" }

    /// Saved as JPEG, Google Motion Photos (.MP.jpg) included
    var isJPEG: Bool { ["jpg", "jpeg"].contains((filename as NSString).pathExtension.lowercased()) }

    /// The uuid Photos uses in links: the local identifier without its "/L0/001" suffix
    var uuid: String { String(id.prefix { $0 != "/" }) }

    /// Items imported twice share this: same moment, dimensions and original size. Without a known size,
    /// burst shots of the same second would match, so those items never count as duplicates.
    var duplicateKey: String? {
        originalSize > 0 ? "\(Int(date.timeIntervalSince1970))-\(width)x\(height)-\(originalSize)" : nil
    }

    static func == (first: Item, second: Item) -> Bool {
        first.id == second.id && first.date == second.date && first.favorite == second.favorite
            && first.size == second.size
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// The files behind an asset. Reading them costs a database query per asset, so the library keeps them, across
/// launches too.
struct Resources: Codable {
    let filename: String
    let size: Int64
    let originalSize: Int64
    /// The edited photo or video Photos rendered, 0 when not edited
    let editedSize: Int64
    /// A Live Photo's motion clips: the original and, after an edit, the re-rendered one
    let motionSize: Int64
    let originalMotionSize: Int64
    let editedMotionSize: Int64
    let edited: Bool
    /// The edit only rotates the item, or changes nothing: the edited version holds everything, and the
    /// original under it is a full extra copy
    let onlyRotated: Bool

    init(asset: PHAsset) {
        let resources = PHAssetResource.assetResources(for: asset)
        var filename = ""
        var size: Int64 = 0
        var originalSize: Int64 = 0
        var editedSize: Int64 = 0
        var motionSize: Int64 = 0
        var originalMotionSize: Int64 = 0
        var editedMotionSize: Int64 = 0
        var edited = false
        var onlyRotated = false
        for resource in resources {
            // Not public API, but the only way to know a resource's size without downloading it
            let bytes = (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
            size += bytes
            switch resource.type {
            case .photo, .video:
                if filename.isEmpty {
                    filename = resource.originalFilename
                    originalSize = bytes
                }
            case .fullSizePhoto, .fullSizeVideo:
                edited = true
                editedSize += bytes
            case .adjustmentData:
                edited = true
                onlyRotated = Self.onlyRotates(resource)
            case .pairedVideo:
                motionSize += bytes
                originalMotionSize += bytes
            case .fullSizePairedVideo:
                motionSize += bytes
                editedMotionSize += bytes
            case .adjustmentBasePairedVideo:
                motionSize += bytes
            default:
                break
            }
        }
        self.filename = filename.isEmpty ? (resources.first?.originalFilename ?? "") : filename
        self.size = size
        self.originalSize = originalSize
        self.editedSize = editedSize
        self.motionSize = motionSize
        self.originalMotionSize = originalMotionSize
        self.editedMotionSize = editedMotionSize
        self.edited = edited
        self.onlyRotated = onlyRotated
    }

    /// Photos saves an edit as a property list around compressed JSON, whose adjustments (crop, light,
    /// filters…) can each be switched off. A rotation is kept apart from them, so an edit with every
    /// adjustment off only rotates, or changes nothing.
    private static func onlyRotates(_ resource: PHAssetResource) -> Bool {
        guard let data = read(resource),
            let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
            plist["adjustmentFormatIdentifier"] as? String == "com.apple.photo",
            let packed = plist["adjustmentData"] as? Data,
            let unpacked = try? (packed as NSData).decompressed(using: .zlib) as Data,
            let edit = (try? JSONSerialization.jsonObject(with: unpacked)) as? [String: Any]
        else { return false }
        let adjustments = edit["adjustments"] as? [[String: Any]] ?? []
        return adjustments.allSatisfy { ($0["enabled"] as? Bool) == false }
    }

    /// Waits for a small resource's bytes. Only called while the library loads, off the main thread.
    private static func read(_ resource: PHAssetResource) -> Data? {
        let buffer = Locked(Data())
        let done = DispatchSemaphore(value: 0)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        PHAssetResourceManager.default().requestData(for: resource, options: options) { chunk in
            buffer.update { $0.append(chunk) }
        } completionHandler: { _ in
            done.signal()
        }
        return done.wait(timeout: .now() + 10) == .success ? buffer.value : nil
    }
}
