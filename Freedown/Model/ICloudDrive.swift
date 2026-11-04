import Foundation

/// A file in iCloud Drive, or in an app's iCloud folder, as Finder would list it.
struct DriveFile: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }
    /// Where it is, as Finder names it: "iCloud Drive › Manuals", "Pages", "WhatsApp"
    let place: String
    /// What iCloud stores, whether or not this Mac holds a copy
    let size: Int64
    let modified: Date
    /// This Mac holds a copy, rather than only iCloud
    let downloaded: Bool
    /// The name of the app that keeps the file for itself (WhatsApp's chat backup, for one), or nil for a
    /// file in iCloud Drive. Such a file is deleted from its app, which would only write it again.
    let keptBy: String?
}

/// The files in `~/Library/Mobile Documents`, which iCloud keeps in step: iCloud Drive itself
/// (`com~apple~CloudDocs`) and one folder per app. An app's own files under `Documents` show in Finder as that
/// app's folder in iCloud Drive; the rest is data the app keeps for itself.
enum ICloudDrive {
    static let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Mobile Documents")
    /// Smaller files are not worth sorting out one by one
    static let minSize: Int64 = 1 << 20

    private static let keys: [URLResourceKey] = [
        .isRegularFileKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey,
    ]

    /// Every file of at least `minSize`, biggest first. A package (a Keynote file, say) counts as one file.
    nonisolated static func scan(_ folder: URL = root) -> [DriveFile] {
        let containers =
            (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var files: [DriveFile] = []
        for container in containers {
            let drive = container.lastPathComponent == "com~apple~CloudDocs"
            let app = displayName(container)
            guard
                let enumerator = FileManager.default.enumerator(
                    at: container, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                let size: Int64
                if values.isPackage == true {
                    size = packageSize(url)
                } else if values.isRegularFile == true {
                    size = Int64(values.fileSize ?? 0)
                } else {
                    continue
                }
                guard size >= minSize else { continue }
                let folders = Array(url.deletingLastPathComponent().pathComponents.dropFirst(container.pathComponents.count))
                // Outside an app's Documents folder, the file is the app's own business
                let documents = drive || folders.first == "Documents"
                let shown = drive ? folders : Array(folders.dropFirst())
                files.append(
                    DriveFile(
                        url: url,
                        place: documents ? ([drive ? "iCloud Drive" : app] + shown).joined(separator: " › ") : app,
                        size: size,
                        modified: values.contentModificationDate ?? .distantPast,
                        downloaded: values.ubiquitousItemDownloadingStatus.map { $0 != .notDownloaded } ?? false,
                        keptBy: documents ? nil : app))
            }
        }
        return files.sorted { $0.size > $1.size }
    }

    /// Moves the files to this Mac's Trash, which takes them out of iCloud Drive on every device. Returns those
    /// moved, and why the others were not.
    nonisolated static func trash(_ files: [DriveFile]) -> (trashed: [DriveFile], failed: [String]) {
        var trashed: [DriveFile] = []
        var failed: [String] = []
        for file in files where file.keptBy == nil {
            do {
                try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
                trashed.append(file)
            } catch let refusal as CocoaError where refusal.code == .fileWriteNoPermission {
                // macOS keeps some files for the apps that made or opened them (the com.apple.macl mark, common on
                // files that came from elsewhere): Finder may still move them, as dragging them to the Trash would
                if let problem = Finder.trash(file.url) {
                    failed.append("\(file.name) (\(problem))")
                } else {
                    trashed.append(file)
                }
            } catch {
                failed.append("\(file.name) (\(error.localizedDescription))")
            }
        }
        return (trashed, failed)
    }

    /// The folder's name as Finder shows it ("WhatsApp" for `57T9237FN3~net~whatsapp~WhatsApp`), without the
    /// direction marks Finder adds
    private static func displayName(_ folder: URL) -> String {
        FileManager.default.displayName(atPath: folder.path).filter { !["\u{200E}", "\u{200F}"].contains($0) }
    }

    private static func packageSize(_ package: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: package, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}
