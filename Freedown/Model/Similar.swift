import AppKit
import Photos
import Vision

/// Items that are copies or near copies of each other (similar shots, duplicates), with the one to keep.
struct ItemGroup: Identifiable {
    let id: String
    let itemIds: [String]
    let pick: String
    /// Vision's aesthetics score, -1 to 1 (similar shots only)
    var scores: [String: Float] = [:]
}

enum Similar {
    struct Fingerprint: Codable {
        let hash: UInt64?
        /// Vision's aesthetics score, -1 to 1
        let score: Float?
        /// Vision's guess that the photo keeps information rather than a moment: a receipt, a document, a
        /// whiteboard. nil in fingerprints taken before it was kept.
        var utility: Bool?
    }

    static let defaultGap: TimeInterval = 60
    /// How far apart two shots of one moment can be: set in Settings, a minute at first
    static var gap: TimeInterval { Settings.number(.similarSeconds, defaultGap) }
    /// "less than a minute", for the texts
    static var gapText: String {
        let seconds = Int(gap)
        if seconds == 60 { return "less than a minute" }
        return seconds % 60 == 0 ? "less than \(seconds / 60) minutes" : "less than \(seconds) seconds"
    }
    /// Looking alike is a 64-bit difference hash of a small render: one bit per pixel of a 9x8 grey thumbnail,
    /// set when it is brighter than its right neighbour. On the web version's library, shots of the same
    /// moment differ by up to about 16 bits, different scenes by 20 to 40 (32 is chance). Vision's feature
    /// print was tried too: it calls two framings of the same view "very close", which are both worth keeping.
    static let defaultMaxDistance = 16
    /// Set in Settings: lower is stricter
    static var maxDistance: Int { Int(Settings.number(.similarBits, Double(defaultMaxDistance))) }

    /// Groups the photos (any order). `known` holds fingerprints computed before, by analysis key; the result
    /// returns them all.
    nonisolated static func groups(
        _ photos: [Item], known: [String: Fingerprint], gap: TimeInterval, maxDistance: Int, progress: @escaping (Double) -> Void
    ) -> ([ItemGroup], [String: Fingerprint]) {
        let shots = photos.sorted { $0.date < $1.date }
        // Only photos with a neighbour taken close enough need a fingerprint
        var candidates = Set<String>()
        for (first, second) in zip(shots, shots.dropFirst()) where second.date.timeIntervalSince(first.date) <= gap {
            candidates.insert(first.id)
            candidates.insert(second.id)
        }
        var fingerprints = known
        for (index, item) in shots.enumerated() where candidates.contains(item.id) && fingerprints[item.analysisKey] == nil {
            fingerprints[item.analysisKey] = fingerprint(item.asset)
            if index % 20 == 0 { progress(Double(index) / Double(shots.count)) }
        }

        var groups: [ItemGroup] = []
        var current: [Item] = []
        func close() {
            if current.count > 1 { groups.append(group(current, fingerprints)) }
            current = []
        }
        for item in shots {
            if let previous = current.last, !alike(previous, item, fingerprints, gap: gap, maxDistance: maxDistance) { close() }
            current.append(item)
        }
        close()
        return (groups, fingerprints)
    }

    private static func alike(
        _ first: Item, _ second: Item, _ fingerprints: [String: Fingerprint], gap: TimeInterval, maxDistance: Int
    ) -> Bool {
        guard second.date.timeIntervalSince(first.date) <= gap,
            let firstHash = fingerprints[first.analysisKey]?.hash, let secondHash = fingerprints[second.analysisKey]?.hash
        else { return false }
        return distance(firstHash, secondHash) <= maxDistance
    }

    /// The shot to keep: a favorite or an edited one first (someone cared about it), then the best score.
    private static func group(_ items: [Item], _ fingerprints: [String: Fingerprint]) -> ItemGroup {
        let scores = items.reduce(into: [String: Float]()) { scores, item in
            if let score = fingerprints[item.analysisKey]?.score { scores[item.id] = score }
        }
        let best = items.max { first, second in
            (first.favorite ? 1 : 0, first.edited ? 1 : 0, scores[first.id] ?? -2)
                < (second.favorite ? 1 : 0, second.edited ? 1 : 0, scores[second.id] ?? -2)
        }!
        return ItemGroup(id: items[0].id, itemIds: items.map(\.id), pick: best.id, scores: scores)
    }

    static func fingerprint(_ asset: PHAsset) -> Fingerprint {
        guard let image = smallImage(asset) else { return Fingerprint(hash: nil, score: nil) }
        let request = VNCalculateImageAestheticsScoresRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let result = request.results?.first
        return Fingerprint(hash: differenceHash(image), score: result?.overallScore, utility: result?.isUtility)
    }

    /// The photo as it looks now, at most `pixels` on its longer side, waited for: only called off the main thread
    static func smallImage(_ asset: PHAsset, pixels: CGFloat = 360) -> CGImage? {
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        var result: CGImage?
        PHImageManager.default().requestImage(
            for: asset, targetSize: CGSize(width: pixels, height: pixels), contentMode: .aspectFit, options: options
        ) { image, _ in
            result = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        return result
    }

    /// How many of the 64 bits differ: 0 for the same picture
    static func distance(_ first: UInt64, _ second: UInt64) -> Int {
        (first ^ second).nonzeroBitCount
    }

    static func differenceHash(_ image: CGImage) -> UInt64? {
        let width = 9
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var bits: UInt64 = 0
        for row in 0..<height {
            for column in 0..<(width - 1) {
                bits = bits << 1 | (pixels[row * width + column] > pixels[row * width + column + 1] ? 1 : 0)
            }
        }
        return bits
    }
}
