import Photos

/// Reading the library: every item with its files, the exact copies, and the counts the sidebar shows.
enum LibraryScan {
    /// `heicRefused`: the photos a HEIC conversion refused before. Also returns how many items Photos was asked
    /// about, those not cached or changed since.
    nonisolated static func fetch(
        cached: [String: CachedResources], heicRefused: Set<String>, progress: @escaping (Int, Int) -> Void
    ) -> ([Item], [String: CachedResources], read: Int) {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: options)
        var items: [Item] = []
        var nextResources: [String: CachedResources] = [:]
        var read = 0
        items.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, index, _ in
            let id = asset.localIdentifier
            let modified = asset.modificationDate?.timeIntervalSinceReferenceDate
            let resources: Resources
            if let entry = cached[id], entry.modified == modified {
                resources = entry.resources
            } else {
                resources = Resources(asset: asset)
                read += 1
            }
            nextResources[id] = CachedResources(modified: modified, resources: resources)
            items.append(Item(asset: asset, resources: resources, heicRefused: heicRefused.contains(id)))
            if index % 250 == 0 { progress(index, assets.count) }
        }
        return (items, nextResources, read)
    }

    /// Copies of the same item, newest first. The copy to keep is a favorite, then an edited one, then the one
    /// in more albums (the one someone organised), then the biggest.
    nonisolated static func duplicateGroups(_ items: [Item]) -> [ItemGroup] {
        let sets = Dictionary(grouping: items.filter { $0.duplicateKey != nil }, by: { $0.duplicateKey! })
            .values.filter { $0.count > 1 }
            .sorted { $0[0].date > $1[0].date }
        return sets.map { copies in
            let albums = Dictionary(
                uniqueKeysWithValues: copies.map {
                    ($0.id, PHAssetCollection.fetchAssetCollectionsContaining($0.asset, with: .album, options: nil).count)
                })
            let keep = copies.max { first, second in
                (first.favorite ? 1 : 0, first.edited ? 1 : 0, albums[first.id] ?? 0, first.size)
                    < (second.favorite ? 1 : 0, second.edited ? 1 : 0, albums[second.id] ?? 0, second.size)
            }!
            return ItemGroup(id: copies[0].id, itemIds: copies.map(\.id), pick: keep.id)
        }
    }

    static func tallies(_ items: [Item], in context: ListContext) -> [Destination: Library.Tally] {
        var tallies: [Destination: Library.Tally] = [:]
        for item in items {
            for destination in Destination.allCases where destination.includes(item, in: context) {
                tallies[destination, default: Library.Tally()].count += 1
                tallies[destination, default: Library.Tally()].size += item.size
                tallies[destination, default: Library.Tally()].saving += destination.replacement?.saving(item) ?? 0
            }
        }
        return tallies
    }
}

/// An asset's files as of its last change, kept on disk so a launch only asks Photos about what changed
struct CachedResources: Codable {
    /// Seconds since 2001, kept as a number: a date written as text loses the fraction and would never match again
    let modified: Double?
    let resources: Resources

    private static let file = "resources.json"

    static func load() -> [String: CachedResources] {
        Settings.read([String: CachedResources].self, from: file) ?? [:]
    }

    static func save(_ resources: [String: CachedResources]) {
        Settings.write(resources, to: file, compact: true)
    }
}

/// Tells the library when Photos changes, whoever made the change.
final class ChangeObserver: NSObject, PHPhotoLibraryChangeObserver {
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange()
    }
}
