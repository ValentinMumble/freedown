/// Photos that look taken by mistake: in a pocket, of the floor, a black or blurred frame. Vision's
/// aesthetics score is very low, the photo is not a document or a receipt, and Vision sees nobody in it.
///
/// Measured on a 6,300-photo library: 16 photos scored below -0.6 with nobody in them, about half of them
/// plainly accidental. The other lowest scores were dark or blurred photos of friends, worth keeping, which is
/// why a photo with someone in it is never suggested. Darkness or blur alone did worse: they also catch the
/// moon, city lights at night and sunsets.
enum Accidental {
    static let defaultMaxScore: Float = -0.6
    /// Set in Settings: lower finds fewer
    static var maxScore: Float { Float(Settings.number(.accidentalScore, Double(defaultMaxScore))) }

    /// Low enough to ask Vision whether anyone is in it
    static func suspect(_ fingerprint: Similar.Fingerprint?, below maxScore: Float) -> Bool {
        guard let fingerprint, let score = fingerprint.score, fingerprint.utility == false else { return false }
        return score < maxScore
    }
}
