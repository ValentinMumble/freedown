import Foundation

/// What the app keeps between launches: its settings in UserDefaults, and the folders of its files.
enum Settings {
    /// The keys' text is stored on disk, so it never changes
    enum Key: String {
        case blurPhotos = "BlurPhotos"
        case markedForRemoveMotion = "MarkedForRemoveMotion"
        case shrinkPreset = "ShrinkPreset"
        case videosNotShrunkOnly = "VideosNotShrunkOnly"
        case startDestination = "StartDestination"
        case selectFirst = "SelectFirst"
        case thumbnailSize = "ThumbnailSize"
    }

    /// The quality bar of a shrink preset
    static func minQualityKey(_ preset: ShrinkPreset) -> String { "MinQuality.\(preset.rawValue)" }

    /// The saved-space history, the shrink records and the analyses
    static let supportFolder = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Freedown")
    /// Files the app can do without, like refused shrink copies waiting to be compared
    static let cacheFolder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/Freedown")

    /// One of the app's JSON files in the support folder, nil when missing or unreadable
    static func read<Value: Decodable>(_ type: Value.Type, from name: String) -> Value? {
        guard let data = try? Data(contentsOf: supportFolder.appending(path: name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    /// `compact` for big files nobody reads by hand
    static func write(_ value: some Encodable, to name: String, compact: Bool = false) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = compact ? [] : [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: supportFolder, withIntermediateDirectories: true)
        try? encoder.encode(value).write(to: supportFolder.appending(path: name))
    }
}
