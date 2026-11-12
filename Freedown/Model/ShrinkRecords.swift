import Foundation

enum ShrinkPreset: String, CaseIterable, Identifiable, Codable {
    case high, small

    var id: String { rawValue }

    // Measured on the library's videos: CRF 26 scores VMAF 95-96 on iPhone footage, CRF 28 scores 90-92
    var crf: Int { self == .high ? 26 : 28 }
    var defaultMinQuality: Double { self == .high ? 93 : 88 }

    /// The score a copy needs to be kept: the default, or what was last set in the Shrink window
    var minQuality: Double {
        get { UserDefaults.standard.object(forKey: Settings.minQualityKey(self)) as? Double ?? defaultMinQuality }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: Settings.minQualityKey(self)) }
    }

    /// The preset last started from the Shrink window, which opens on it next time
    static var last: ShrinkPreset {
        get {
            UserDefaults.standard.string(forKey: Settings.Key.shrinkPreset.rawValue).flatMap(ShrinkPreset.init(rawValue:))
                ?? .high
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Settings.Key.shrinkPreset.rawValue) }
    }

    var label: String { self == .high ? "High quality" : "Smaller files" }
    var detail: String { self == .high ? "CRF 26, hard to tell apart" : "CRF 28, slightly softer" }
}

/// What happened to one video. Saved, so the app remembers across launches which videos were shrunk.
struct ShrinkRecord: Codable, Identifiable {
    /// Local identifier of the original
    let original: String
    let name: String
    /// Local identifier of the copy in Photos, when one was kept
    let copy: String?
    /// Why the original was kept as it was
    let kept: String?
    let before: Int64
    let after: Int64
    let vmaf: Double?
    /// The score the copy needed, as set when it was made: missing from older records
    let minQuality: Double?
    /// No copy went into Photos, but one waits aside to be compared: missing from older records
    var keptAside: Bool? = nil
    let preset: ShrinkPreset
    let from: String
    let to: String
    let date: Date

    var id: String { original }

    /// "27 MB → 16 MB (−40%)"
    var sizes: String {
        "\(Format.bytes(before)) → \(Format.bytes(after)) (\(Self.change(before, after)))"
    }

    /// "+25%", "−40%", and "+<1%" rather than a misleading 0% when the copy is barely bigger or smaller
    static func change(_ before: Int64, _ after: Int64) -> String {
        let percent = (Double(after) / Double(max(before, 1)) - 1) * 100
        if abs(percent) < 1 { return percent > 0 ? "+<1%" : percent < 0 ? "−<1%" : "0%" }
        let rounded = Int(abs(percent).rounded())
        return percent > 0 ? "+\(rounded)%" : "−\(rounded)%"
    }

    /// "27 MB → 16 MB (−40%), quality 95.3"
    var summary: String {
        sizes + (vmaf.map { ", quality \($0)" } ?? "")
    }

    var requiredQuality: Double { minQuality ?? preset.defaultMinQuality }

    /// Refused for its quality score or its frame count, not its size, so the copy can be saved anyway (older
    /// records kept aside only copies refused for their score)
    var reviewable: Bool { copy == nil && (keptAside ?? (vmaf != nil)) }
}

/// The ids the sidebar and the skip rules need, taken from the saved records
struct ShrinkStatus {
    var shrunk: Set<String> = []
    /// Each copy's original
    var copies: [String: String] = [:]
    var kept: Set<String> = []

    init(records: [String: ShrinkRecord] = [:]) {
        for record in records.values {
            if let copy = record.copy {
                shrunk.insert(record.original)
                copies[copy] = record.original
            } else {
                kept.insert(record.original)
            }
        }
    }
}

enum ShrinkRecords {
    private static let file = Settings.supportFolder.appending(path: "shrink.json")

    static func load() -> [String: ShrinkRecord] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: ShrinkRecord].self, from: data)) ?? [:]
    }

    /// Where a copy refused for its quality waits until it is saved anyway or discarded: one folder per
    /// video, so the file keeps the video's name
    static func preview(original: String, name: String) -> URL {
        Settings.cacheFolder.appending(path: "Previews")
            .appending(path: original.replacingOccurrences(of: "/", with: "_"))
            .appending(path: (name as NSString).deletingPathExtension + ".mov")
    }

    static func preview(_ record: ShrinkRecord) -> URL? {
        let file = preview(original: record.original, name: record.name)
        return record.reviewable && FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    static func discardPreview(_ record: ShrinkRecord) {
        try? FileManager.default.removeItem(at: preview(original: record.original, name: record.name).deletingLastPathComponent())
    }

    static func save(_ records: [String: ShrinkRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(records).write(to: file)
    }
}
