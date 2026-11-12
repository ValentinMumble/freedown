import Foundation
import Testing

@testable import Freedown

struct AccidentalTests {
    @Test func onlyAVeryLowScoreThatIsNoDocumentIsSuspect() {
        #expect(Accidental.suspect(Similar.Fingerprint(hash: 1, score: -0.9, utility: false), below: Accidental.defaultMaxScore))
        #expect(!Accidental.suspect(Similar.Fingerprint(hash: 1, score: -0.5, utility: false), below: Accidental.defaultMaxScore))
        // A receipt or a whiteboard scores low on looks, but was taken on purpose
        #expect(!Accidental.suspect(Similar.Fingerprint(hash: 1, score: -0.9, utility: true), below: Accidental.defaultMaxScore))
        #expect(!Accidental.suspect(Similar.Fingerprint(hash: 1, score: -0.9, utility: nil), below: Accidental.defaultMaxScore))
        #expect(!Accidental.suspect(Similar.Fingerprint(hash: nil, score: nil, utility: nil), below: Accidental.defaultMaxScore))
        #expect(!Accidental.suspect(nil, below: Accidental.defaultMaxScore))
    }

    /// The cache written before the utility flag was kept still reads, with the flag unknown
    @Test func olderFingerprintsStillRead() throws {
        let json = Data(#"{"hash": 7493102443609208912, "score": 0.6}"#.utf8)
        let fingerprint = try JSONDecoder().decode(Similar.Fingerprint.self, from: json)
        #expect(fingerprint.hash == 7_493_102_443_609_208_912)
        #expect(fingerprint.utility == nil)
    }
}
