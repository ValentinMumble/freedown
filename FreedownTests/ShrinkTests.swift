import Foundation
import Testing

@testable import Freedown

struct ShrinkTests {
    private func record(copy: String? = nil, kept: String? = nil, vmaf: Double? = nil, aside: Bool? = nil) -> ShrinkRecord {
        ShrinkRecord(
            original: "original", name: "IMG_0001.MOV", copy: copy, kept: kept, before: 100, after: 60, vmaf: vmaf,
            minQuality: nil, keptAside: aside, preset: .high, from: "", to: "", date: .now)
    }

    @Test func sizesGiveTheChange() {
        #expect(record().sizes.hasSuffix("(−40%)"))
    }

    @Test func summaryAddsTheScore() {
        #expect(record(vmaf: 95.3).summary.hasSuffix(", quality 95.3"))
    }

    @Test func aSavedCopyIsNotReviewable() {
        #expect(!record(copy: "copy", vmaf: 95, aside: false).reviewable)
    }

    @Test func aCopyKeptAsideIsReviewable() {
        #expect(record(kept: "it has 3000 frames instead of 3020", aside: true).reviewable)
    }

    @Test func olderRecordsKeptAsideOnlyCopiesWithAScore() {
        #expect(record(kept: "the copy would look softer", vmaf: 85).reviewable)
        #expect(!record(kept: "the copy is 5% bigger").reviewable)
    }

    @Test func statusSplitsShrunkAndKept() {
        let records = [
            "first": ShrinkRecord(
                original: "first", name: "", copy: "first-copy", kept: nil, before: 100, after: 50, vmaf: 95,
                minQuality: nil, preset: .high, from: "", to: "", date: .now),
            "second": ShrinkRecord(
                original: "second", name: "", copy: nil, kept: "bigger", before: 100, after: 120, vmaf: nil,
                minQuality: nil, preset: .high, from: "", to: "", date: .now),
        ]
        let status = ShrinkStatus(records: records)
        #expect(status.shrunk == ["first"])
        #expect(status.copies == ["first-copy": "first"])
        #expect(status.kept == ["second"])
    }

    @Test func oneFrameShortIsAllowed() {
        #expect(Shrinker.framesMatch(3020, 3020))
        #expect(Shrinker.framesMatch(3019, 3020))
        #expect(!Shrinker.framesMatch(3000, 3020))
    }

    /// A copy barely bigger or smaller says so, rather than a misleading 0%
    @Test func describesTheSizeChange() {
        #expect(ShrinkRecord.change(100, 60) == "−40%")
        #expect(ShrinkRecord.change(72, 91) == "+26%")
        #expect(ShrinkRecord.change(810, 815) == "+<1%")
        #expect(ShrinkRecord.change(815, 810) == "−<1%")
        #expect(ShrinkRecord.change(100, 100) == "0%")
    }
}
