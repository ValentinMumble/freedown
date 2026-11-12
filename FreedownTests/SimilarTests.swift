import Testing

@testable import Freedown

struct SimilarTests {
    @Test func thePictureMatchesItself() throws {
        let hash = try #require(Similar.differenceHash(TestImages.gradient()))
        #expect(Similar.distance(hash, hash) == 0)
    }

    @Test func aBrighterCopyStaysClose() throws {
        let original = try #require(Similar.differenceHash(TestImages.gradient()))
        let brighter = try #require(Similar.differenceHash(TestImages.gradient(brighter: 20)))
        #expect(Similar.distance(original, brighter) <= Similar.defaultMaxDistance)
    }

    @Test func aMirroredPictureIsFar() throws {
        let original = try #require(Similar.differenceHash(TestImages.gradient()))
        let mirrored = try #require(Similar.differenceHash(TestImages.gradient(reversed: true)))
        #expect(Similar.distance(original, mirrored) > Similar.defaultMaxDistance)
    }
}
