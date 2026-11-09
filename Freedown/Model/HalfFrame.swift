import CoreGraphics
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

/// A lab scan of half-frame film: two shots side by side on one landscape picture, with a dark strip of unexposed
/// film between them. It splits into two photos, each turned as it was shot.
struct HalfFrameScan: Identifiable, Sendable {
    let item: Item
    var id: String { item.id }
    /// Where the strip between the frames starts and ends, as shares of the scan's width
    var gap: ClosedRange<Double>
    /// Quarter turns clockwise for the left and the right half
    var turns = [0, 0]
    /// Whether the strip was found, rather than placed in the middle by hand
    var found = true
}

enum HalfFrame {
    /// Two frames of 17 × 24 mm and the strip between them make a scan about 3:2 wide
    static let aspect = 1.35...1.6
    /// The strip is looked for around the middle only: a dark subject elsewhere can't pass for it
    static let window = 0.38...0.62

    /// A strip in the middle as wide as the lab's usual one, for a scan where none was found
    static let defaultGap = 0.494...0.506

    static func isCandidate(_ item: Item) -> Bool {
        guard item.kind == .photo, !item.screenshot, !item.live, item.height > 0 else { return false }
        return aspect.contains(Double(item.width) / Double(item.height))
    }

    /// The strip on a small render of the photo as Photos shows it, or nil when there is none
    nonisolated static func gap(_ asset: PHAsset) -> ClosedRange<Double>? {
        guard let image = Similar.smallImage(asset, pixels: 600) else { return nil }
        let width = image.width
        let height = image.height
        return findGap(Stills.grey(image, width, height), width: width, height: height)
    }

    /// The dark strip between two frames: columns near the middle much darker than the picture on both sides of
    /// them, a few percent of the width at most. A night shot is dark all over, so its middle is not darker
    /// than its sides and is not taken for a strip.
    static func findGap(_ grey: [UInt8], width: Int, height: Int) -> ClosedRange<Double>? {
        guard width >= 50, height >= 20, grey.count == width * height else { return nil }
        // Each column's brightness over the middle rows, away from the scan's own edges
        let top = height / 10
        let bottom = height - height / 10
        let columns = (0..<width).map { column -> Double in
            var sum = 0
            for row in top..<bottom { sum += Int(grey[row * width + column]) }
            return Double(sum) / Double(bottom - top)
        }
        let first = Int(window.lowerBound * Double(width))
        let last = Int(window.upperBound * Double(width))
        // The strip is near black, whatever the shots around it
        let dark = columns[first...last].enumerated().filter { $0.element < 40 }.map { first + $0.offset }
        guard !dark.isEmpty else { return nil }
        // Runs of dark columns next to each other; the strip is the run nearest the middle
        var runs: [ClosedRange<Int>] = []
        for column in dark {
            if let run = runs.last, run.upperBound == column - 1 {
                runs[runs.count - 1] = run.lowerBound...column
            } else {
                runs.append(column...column)
            }
        }
        let widest = Double(width) * 0.08
        let middle = Double(width) / 2
        let candidates = runs.filter { Double($0.count) <= widest }
            .sorted { abs(Double($0.lowerBound + $0.upperBound) / 2 - middle) < abs(Double($1.lowerBound + $1.upperBound) / 2 - middle) }
        let band = max(2, width / 40)
        for run in candidates {
            let inside = run.map { columns[$0] }.reduce(0, +) / Double(run.count)
            let left = columns[max(0, run.lowerBound - band)..<run.lowerBound]
            let right = columns[(run.upperBound + 1)..<min(width, run.upperBound + 1 + band)]
            guard !left.isEmpty, !right.isEmpty else { continue }
            let sides = min(left.reduce(0, +) / Double(left.count), right.reduce(0, +) / Double(right.count))
            // Both shots beside it are clearly brighter than the strip
            if sides > inside * 2 + 12 {
                return Double(run.lowerBound) / Double(width)...Double(run.upperBound + 1) / Double(width)
            }
        }
        return nil
    }

    /// Writes the two halves into `folder`, cut on either side of the strip, each turned and carrying the scan's
    /// date, place and camera details. Returns the left half's file, then the right one's.
    nonisolated static func split(_ scan: URL, gap: ClosedRange<Double>, turns: [Int], to folder: URL) throws -> [URL] {
        guard let source = CGImageSourceCreateWithURL(scan as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
            let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int,
            // The scan as it is shown, its own orientation applied, at full size
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(pixelWidth, pixelHeight),
                ] as CFDictionary)
        else { throw FFmpeg.Failure(message: "could not read the scan") }
        let width = image.width
        let leftEnd = Int((gap.lowerBound * Double(width)).rounded())
        let rightStart = Int((gap.upperBound * Double(width)).rounded())
        let halves = [
            CGRect(x: 0, y: 0, width: leftEnd, height: image.height),
            CGRect(x: rightStart, y: 0, width: width - rightStart, height: image.height),
        ]
        let stem = scan.deletingPathExtension().lastPathComponent
        return try zip(halves, ["a", "b"]).enumerated().map { index, pair in
            let (rect, letter) = pair
            guard rect.width > 0, let half = image.cropping(to: rect) else { throw FFmpeg.Failure(message: "the cut leaves an empty half") }
            let file = folder.appending(path: "\(stem)_\(letter).heic")
            guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.heic.identifier as CFString, 1, nil)
            else { throw FFmpeg.Failure(message: "could not write HEIC") }
            // The scan's metadata, its size and turn replaced: the turn is written as an orientation, so the
            // pixels are not encoded twice
            var metadata = properties
            for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyOrientation] { metadata[key] = nil }
            metadata[kCGImagePropertyOrientation] = orientation(turns[index])
            metadata[kCGImageDestinationLossyCompressionQuality] = 0.9
            for key in [kCGImagePropertyTIFFDictionary] {
                if var tiff = metadata[key] as? [CFString: Any] {
                    tiff[kCGImagePropertyTIFFOrientation] = nil
                    metadata[key] = tiff
                }
            }
            CGImageDestinationAddImage(destination, half, metadata as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw FFmpeg.Failure(message: "could not write HEIC") }
            return file
        }
    }

    /// The EXIF orientation that shows the pixels turned clockwise this many quarter turns
    static func orientation(_ turns: Int) -> UInt32 {
        switch ((turns % 4) + 4) % 4 {
        case 1: 6
        case 2: 3
        case 3: 8
        default: 1
        }
    }

    /// Adds the halves of each scan to Photos and deletes the scan, in one change macOS asks to confirm. Each half
    /// gets the scan's date (the right one a second later, so they stay in order), place, favorite and albums.
    nonisolated static func replace(_ splits: [(scan: PHAsset, halves: [URL])]) async throws {
        let albums = splits.map { PHAssetCollection.fetchAssetCollectionsContaining($0.scan, with: .album, options: nil) }
        try await PHPhotoLibrary.shared().performChanges {
            for ((scan, halves), scanAlbums) in zip(splits, albums) {
                for (index, half) in halves.enumerated() {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = half.lastPathComponent
                    request.addResource(with: .photo, fileURL: half, options: options)
                    request.creationDate = scan.creationDate?.addingTimeInterval(Double(index))
                    request.location = scan.location
                    request.isFavorite = scan.isFavorite
                    guard let placeholder = request.placeholderForCreatedAsset else { continue }
                    scanAlbums.enumerateObjects { album, _, _ in
                        if album.canPerform(.addContent) {
                            PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                        }
                    }
                }
            }
            PHAssetChangeRequest.deleteAssets(splits.map(\.scan) as NSArray)
        }
    }
}
