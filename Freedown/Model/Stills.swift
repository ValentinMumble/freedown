import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// JPEG photos saved again as HEIC, at quality 0.8 (0.9 saved only 6% on a sample, 0.7 scored lower for 9% more).
///
/// Whether a JPEG gains depends on how hard its camera already compressed it, in bits per pixel. Measured on
/// 1,526 of the library's JPEGs: under 1.5 bits per pixel, 55 of 801 passed the checks below and they saved 1 to
/// 5% of the band's size; from 1.5 to 4, about half passed, saving 20% of the band; from 4, 26 of 27 passed,
/// saving 55%. So only JPEGs from 1.5 bits per pixel are offered, which keeps 94% of the saving for half the work.
enum Stills {
    static let heicQuality = 0.8
    /// The score a HEIC needs to replace its JPEG, out of 100
    static let minScore = 97.0
    static let minBitsPerPixel = 1.5

    struct Conversion {
        let file: URL
        let score: Double
    }

    /// Why a JPEG stays a JPEG. Remembered, so the photo is not offered again.
    struct Refusal: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    static func bitsPerPixel(size: Int64, pixels: Int) -> Double {
        pixels > 0 ? Double(size) * 8 / Double(pixels) : 0
    }

    /// The share of a JPEG's size a conversion is expected to free, refusals included (see above)
    static func expectedSaving(bitsPerPixel: Double) -> Double {
        bitsPerPixel >= 4 ? 0.55 : bitsPerPixel >= minBitsPerPixel ? 0.2 : 0
    }

    /// Writes the photo as HEIC with its metadata (date, place, orientation), or says why it should stay a
    /// JPEG. A Google Motion Photo's video, appended after the picture, is not part of the image, so it is
    /// left behind.
    static func heic(from jpeg: URL, to heic: URL) throws -> Conversion {
        guard let source = CGImageSourceCreateWithURL(jpeg as CFURL, nil),
            let original = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw FFmpeg.Failure(message: "could not read the photo") }
        if hasGainMap(source) { throw Refusal(reason: "it has an HDR layer HEIC would drop") }
        guard let destination = CGImageDestinationCreateWithURL(heic as CFURL, UTType.heic.identifier as CFString, 1, nil)
        else { throw FFmpeg.Failure(message: "could not write HEIC") }
        CGImageDestinationAddImageFromSource(
            destination, source, 0, [kCGImageDestinationLossyCompressionQuality: heicQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination), let written = CGImageSourceCreateWithURL(heic as CFURL, nil),
            let converted = CGImageSourceCreateImageAtIndex(written, 0, nil)
        else { throw FFmpeg.Failure(message: "could not write HEIC") }
        let before = try fileSize(jpeg)
        let after = try fileSize(heic)
        if Double(after) > Double(before) * (1 - Shrinker.minSaving) {
            throw Refusal(reason: "HEIC saves only \(max(0, Int((1 - Double(after) / Double(before)) * 100)))%")
        }
        let quality = score(original, converted)
        if quality < minScore {
            throw Refusal(reason: "the HEIC would look different (score \(String(format: "%.1f", quality)), below \(Int(minScore)))")
        }
        return Conversion(file: heic, score: quality)
    }

    /// iPhones and Pixels add a layer for HDR screens that a plain HEIC would not keep
    static func hasGainMap(_ source: CGImageSource) -> Bool {
        CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
            || CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
    }

    /// How alike two pictures look, out of 100: structural similarity (SSIM) of their grey versions at 1024
    /// pixels, over 8x8 windows every 4 pixels. Identical pictures score 100.
    static func score(_ first: CGImage, _ second: CGImage) -> Double {
        let scale = min(1, 1024 / Double(max(first.width, first.height)))
        let width = max(8, Int(Double(first.width) * scale))
        let height = max(8, Int(Double(first.height) * scale))
        let one = grey(first, width, height)
        let two = grey(second, width, height)
        // The usual constants, for 8-bit values: (0.01 × 255)² and (0.03 × 255)²
        let stabilizer: Double = 6.5025
        let contrastStabilizer: Double = 58.5225
        var total = 0.0
        var windows = 0
        for top in stride(from: 0, through: height - 8, by: 4) {
            for left in stride(from: 0, through: width - 8, by: 4) {
                var sumOne = 0.0, sumTwo = 0.0, squaresOne = 0.0, squaresTwo = 0.0, products = 0.0
                for row in top..<top + 8 {
                    for column in left..<left + 8 {
                        let valueOne = Double(one[row * width + column])
                        let valueTwo = Double(two[row * width + column])
                        sumOne += valueOne
                        sumTwo += valueTwo
                        squaresOne += valueOne * valueOne
                        squaresTwo += valueTwo * valueTwo
                        products += valueOne * valueTwo
                    }
                }
                let meanOne = sumOne / 64
                let meanTwo = sumTwo / 64
                let varianceOne = squaresOne / 64 - meanOne * meanOne
                let varianceTwo = squaresTwo / 64 - meanTwo * meanTwo
                let covariance = products / 64 - meanOne * meanTwo
                total += ((2 * meanOne * meanTwo + stabilizer) * (2 * covariance + contrastStabilizer))
                    / ((meanOne * meanOne + meanTwo * meanTwo + stabilizer) * (varianceOne + varianceTwo + contrastStabilizer))
                windows += 1
            }
        }
        return windows == 0 ? 0 : total / Double(windows) * 100
    }

    static func grey(_ image: CGImage, _ width: Int, _ height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            context?.interpolationQuality = .high
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }

    private static func fileSize(_ file: URL) throws -> Int64 {
        (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
}
