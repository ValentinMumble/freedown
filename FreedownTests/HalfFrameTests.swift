import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Freedown

struct HalfFrameTests {
    /// A grey picture: noise around `level`, with a near-black strip over the given columns
    private func grey(width: Int, height: Int, level: Int, strip: Range<Int>? = nil) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<(width * height)).map { index in
            if let strip, strip.contains(index % width) { return UInt8.random(in: 2...10, using: &generator) }
            return UInt8(max(0, min(255, level + Int.random(in: -40...40, using: &generator))))
        }
    }

    @Test func findsTheStripBetweenTwoFrames() throws {
        let gap = try #require(HalfFrame.findGap(grey(width: 600, height: 400, level: 130, strip: 293..<307), width: 600, height: 400))
        #expect(abs(gap.lowerBound - 293.0 / 600) < 0.002)
        #expect(abs(gap.upperBound - 307.0 / 600) < 0.002)
    }

    @Test func aPhotoWithoutStripHasNone() {
        #expect(HalfFrame.findGap(grey(width: 600, height: 400, level: 130), width: 600, height: 400) == nil)
    }

    /// Dark all over, so its middle is no darker than its sides
    @Test func aNightShotIsNotTakenForAScan() {
        #expect(HalfFrame.findGap(grey(width: 600, height: 400, level: 18), width: 600, height: 400) == nil)
    }

    /// A dark pole near the edge is outside the middle, where the strip is looked for
    @Test func aDarkBarNearTheEdgeIsNotAStrip() {
        #expect(HalfFrame.findGap(grey(width: 600, height: 400, level: 130, strip: 40..<54), width: 600, height: 400) == nil)
    }

    @Test func turnsMapToOrientations() {
        #expect(HalfFrame.orientation(0) == 1)
        #expect(HalfFrame.orientation(1) == 6)
        #expect(HalfFrame.orientation(2) == 3)
        #expect(HalfFrame.orientation(3) == 8)
        #expect(HalfFrame.orientation(-1) == 8)
    }

    /// A scan of 900 × 600 cut around a strip at 440 to 460 gives a left half of 440 and a right one of 440,
    /// turned as asked, with the scan's date
    @Test func splitsAScanIntoTwoTurnedHalves() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "freedown-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let scan = folder.appending(path: "R1-00001-001A.jpeg")
        let image = TestImages.gradient(width: 900, height: 600)
        let destination = try #require(CGImageDestinationCreateWithURL(scan as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let exif = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:09:19 17:02:00"]]
        CGImageDestinationAddImage(destination, image, exif as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))

        let halves = try HalfFrame.split(scan, gap: (440.0 / 900)...(460.0 / 900), turns: [1, 0], to: folder)
        #expect(halves.map(\.lastPathComponent) == ["R1-00001-001A_a.heic", "R1-00001-001A_b.heic"])
        for (half, turn) in zip(halves, [6, 1]) {
            let source = try #require(CGImageSourceCreateWithURL(half as CFURL, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            #expect(properties[kCGImagePropertyPixelWidth] as? Int == 440)
            #expect(properties[kCGImagePropertyPixelHeight] as? Int == 600)
            #expect(properties[kCGImagePropertyOrientation] as? Int == turn)
            let date = (properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] as? String
            #expect(date == "2026:09:19 17:02:00")
        }
    }
}
