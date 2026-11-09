import AVKit
import Photos
import PhotosUI
import SwiftUI

/// The right-hand panel: details of the selected item, or a summary of the selection.
struct Inspector: View {
    let items: [Item]
    let actions: Actions

    var body: some View {
        if let item = items.first, items.count == 1 {
            // A new item starts on its edited version
            ItemDetail(item: item, actions: actions).id(item.id)
        } else if items.isEmpty {
            ContentUnavailableView(
                "Nothing selected", systemImage: "photo",
                description: Text("Click an item to see it here. Cmd-click or Shift-click to select several."))
        } else {
            VStack(spacing: 12) {
                Text(Format.count(items.count, "item")).font(.title2.weight(.semibold))
                Text(Format.bytes(items.reduce(0) { $0 + $1.size })).foregroundStyle(.secondary)
                ActionButtons(items: items, actions: actions)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// What the toolbar, the inspector and the similar shots can do to items
struct Actions {
    let open: (Item) -> Void
    let changeDate: ([Item]) -> Void
    let setFavorite: ([Item], Bool) -> Void
    let delete: ([Item]) -> Void
    let shrink: ([Item]) -> Void
    let replace: ([Item], Replacement) -> Void
    /// Dropped onto another photo: they take its moment, just after it
    let placeAfter: ([Item], Item) -> Void
}

/// The right-click menu of an item, acting on `items` (the selection when the item is part of it)
struct ItemMenu: View {
    let items: [Item]
    let actions: Actions
    @Environment(Library.self) private var library

    var body: some View {
        let favorite = items.allSatisfy(\.favorite)
        if let item = items.first, items.count == 1 {
            Button("Open in Photos") { actions.open(item) }
        }
        Button("Change Date…") { actions.changeDate(items) }
        Button(favorite ? "Remove from Favorites" : "Add to Favorites") { actions.setFavorite(items, !favorite) }
        if items.contains(where: { $0.kind == .video }) {
            Button("Shrink…") { actions.shrink(items) }
        }
        if items.contains(where: Replacement.removeMotion.applies) {
            Button("Remove Motion…") { actions.replace(items, .removeMotion) }
            Button(items.filter(\.live).allSatisfy { library.marked.contains($0.id) } ? "Unmark (M)" : "Mark for Remove Motion (M)") {
                library.toggleMark(items)
            }
        }
        if items.contains(where: Replacement.keepEdit.applies) {
            Button("Keep Edited Version Only…") { actions.replace(items, .keepEdit) }
        }
        if items.contains(where: Replacement.convertToHEIC.applies) {
            Button("Convert to HEIC…") { actions.replace(items, .convertToHEIC) }
        }
        Divider()
        Button(items.count == 1 ? "Delete…" : "Delete \(items.count) Items…", role: .destructive) {
            actions.delete(items)
        }
    }
}

struct ActionButtons: View {
    let items: [Item]
    let actions: Actions
    @Environment(Library.self) private var library

    var body: some View {
        let favorite = items.allSatisfy(\.favorite)
        VStack(alignment: .leading, spacing: 8) {
            if let item = items.first, items.count == 1 {
                Button("Open in Photos", systemImage: "arrow.up.forward.app") { actions.open(item) }
            }
            Button("Change Date…", systemImage: "calendar") { actions.changeDate(items) }
            Button(favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: favorite ? "heart.slash" : "heart") {
                actions.setFavorite(items, !favorite)
            }
            if items.contains(where: { $0.kind == .video }) {
                Button("Shrink…", systemImage: "arrow.down.right.and.arrow.up.left") { actions.shrink(items) }
            }
            if items.contains(where: Replacement.removeMotion.applies) {
                Button("Remove Motion (−\(Format.bytes(Replacement.removeMotion.saving(of: items))))…", systemImage: "livephoto.slash") {
                    actions.replace(items, .removeMotion)
                }
                let marked = items.filter(\.live).allSatisfy { library.marked.contains($0.id) }
                Button(marked ? "Unmark (M)" : "Mark for Remove Motion (M)", systemImage: marked ? "xmark.circle" : "checklist") {
                    library.toggleMark(items)
                }
                .help("Mark it, check the next one, then remove the motion of all marked ones at once from Live Photos")
            }
            if items.contains(where: Replacement.keepEdit.applies) {
                Button("Keep Edited Version Only (−\(Format.bytes(Replacement.keepEdit.saving(of: items))))…", systemImage: "wand.and.stars") {
                    actions.replace(items, .keepEdit)
                }
            }
            if items.contains(where: Replacement.convertToHEIC.applies) {
                Button("Convert to HEIC (about −\(Format.bytes(Replacement.convertToHEIC.saving(of: items))))…", systemImage: "photo.badge.arrow.down") {
                    actions.replace(items, .convertToHEIC)
                }
            }
            Button("Delete…", systemImage: "trash", role: .destructive) { actions.delete(items) }
        }
        .buttonStyle(.borderless)
    }
}

struct ItemDetail: View {
    let item: Item
    let actions: Actions
    @Environment(Library.self) private var library
    @AppStorage(Settings.Key.blurPhotos.rawValue) private var blurPhotos = false
    @State private var showOriginal = false

    /// The shrink result, seen from this video: the original or its copy
    private func shrinkFact(_ record: ShrinkRecord) -> String {
        if record.copy == item.id { return "copy of \(record.name), \(record.summary)" }
        if record.copy != nil {
            return "a copy is saved, \(record.summary). Delete this original from Shrinking to free the space"
        }
        return "no, \(record.kept ?? "no copy saved")"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Group {
                    if item.kind == .video {
                        VideoPreview(asset: item.asset, original: showOriginal)
                    } else if item.live {
                        LivePhotoPreview(asset: item.asset, original: showOriginal)
                    } else {
                        Thumbnail(asset: item.asset, pixels: 1200, fit: true, original: showOriginal)
                    }
                }
                // The item's own shape at the panel's width, so a portrait video is not a strip in a wide box; the
                // height follows the width and never the other way, so resizing the panel settles
                .aspectRatio(item.height > 0 ? CGFloat(item.width) / CGFloat(item.height) : 1, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 560)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Photos keeps two versions of an edited item: the original and the latest edit
                if item.edited {
                    Picker("Version", selection: $showOriginal) {
                        Text("Edited" + (item.editedSize > 0 ? " · \(Format.bytes(item.editedSize))" : "")).tag(false)
                        Text("Original · \(Format.bytes(item.originalSize))").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Text(item.filename).font(.headline).textSelection(.enabled)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    Fact("Date", Format.date(item.date))
                    Fact("Size", Format.bytes(item.size) + (item.size != item.originalSize ? " (original \(Format.bytes(item.originalSize)))" : ""))
                    Fact("Dimensions", "\(item.width) × \(item.height)")
                    if item.kind == .video {
                        Fact("Length", Format.duration(item.duration))
                        if item.duration > 0 {
                            Fact("Bitrate", String(format: "%.1f Mbps", Double(item.originalSize) * 8 / 1e6 / item.duration))
                        }
                    }
                    if item.edited {
                        Fact("Edited", item.onlyRotated
                                ? "only rotated, or not changed at all: the original is a full extra copy"
                                : item.editedSize > 0 ? "yes, iCloud keeps both versions" : "yes, as a setting Photos applies when showing it, with no second file")
                    }
                    if item.hiddenMotion {
                        Fact("Motion", "a \(Format.bytes(item.motionSize)) clip Photos no longer plays, still counted by iCloud")
                    }
                    if item.live { Fact("Live Photo", "yes, \(Format.bytes(item.motionSize)) of motion. Point at the photo to play it") }
                    // An edited Live Photo can do both: Remove Motion frees more, Keep Edited Version keeps it live
                    let choices = [Replacement.removeMotion, .keepEdit, .convertToHEIC].filter { $0.applies(to: item) && $0.saving(item) > 0 }
                    if !choices.isEmpty {
                        // A HEIC's size is only an estimate until converted
                        Fact("Could free", choices.map { "\($0 == .convertToHEIC ? "about " : "")\(Format.bytes($0.saving(item))) with \($0.title)" }.joined(separator: ", or "))
                    }
                    if let record = library.shrinkRecord(item) { Fact("Shrunk", shrinkFact(record)) }
                    if let location = item.location, !blurPhotos {
                        GridRow {
                            Text("Place").foregroundStyle(.secondary)
                            Link(
                                String(format: "%.4f, %.4f", location.coordinate.latitude, location.coordinate.longitude),
                                destination: URL(string: "https://maps.apple.com/?ll=\(location.coordinate.latitude),\(location.coordinate.longitude)")!)
                        }
                    }
                }
                .font(.callout)

                Divider()
                ActionButtons(items: [item], actions: actions)
            }
            .padding()
        }
    }
}

private struct Fact: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

extension Notification.Name {
    /// Space pressed: the video or Live Photo in the panel plays or pauses
    static let togglePlayback = Notification.Name("togglePlayback")
}

/// Plays a video, streaming it from iCloud when it is not on this Mac.
struct VideoPreview: View {
    let asset: PHAsset
    /// The video as filmed, before any edit
    var original = false
    @State private var player: AVPlayer?
    @AppStorage(Settings.Key.blurPhotos.rawValue) private var blurPhotos = false

    var body: some View {
        Group {
            if let player, !blurPhotos {
                PlayerView(player: player)
            } else {
                Thumbnail(asset: asset, pixels: 1200, fit: true)
            }
        }
        .task(id: "\(asset.localIdentifier)-\(original)") {
            player = nil
            player = await Self.player(for: asset, original: original)
        }
        .onReceive(NotificationCenter.default.publisher(for: .togglePlayback)) { _ in
            guard let player else { return }
            if player.rate == 0 { player.play() } else { player.pause() }
        }
    }

    /// `.automatic` may stream a lighter version; `.highQualityFormat` waits for the full one. Photos answers
    /// on a queue of its own, so this must not run on the main actor: Swift 6 stops the app when a main actor
    /// closure runs elsewhere.
    nonisolated static func player(
        for asset: PHAsset, deliveryMode: PHVideoRequestOptionsDeliveryMode = .automatic, original: Bool = false
    ) async -> AVPlayer? {
        await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = deliveryMode
            options.version = original ? .original : .current
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                continuation.resume(returning: item.map(AVPlayer.init(playerItem:)))
            }
        }
    }
}

/// A Live Photo that plays its motion, with sound, while the pointer is over it, like in Photos.
struct LivePhotoPreview: View {
    let asset: PHAsset
    /// The Live Photo as taken, before any edit
    var original = false
    @State private var livePhoto: PHLivePhoto?
    @State private var playing = false
    @AppStorage(Settings.Key.blurPhotos.rawValue) private var blurPhotos = false

    var body: some View {
        Group {
            if let livePhoto, !blurPhotos {
                LivePhotoView(livePhoto: livePhoto, playing: playing)
                    .overlay(alignment: .topLeading) { Pill(text: playing ? "LIVE ▶︎" : "LIVE") }
                    .onHover { playing = $0 }
            } else {
                Thumbnail(asset: asset, pixels: 1200, fit: true)
            }
        }
        .task(id: "\(asset.localIdentifier)-\(original)") {
            livePhoto = nil
            livePhoto = await Self.load(asset, original: original)
        }
        .onReceive(NotificationCenter.default.publisher(for: .togglePlayback)) { _ in playing.toggle() }
    }

    /// Off the main actor, like VideoPreview.player
    nonisolated private static func load(_ asset: PHAsset, original: Bool) async -> PHLivePhoto? {
        await withCheckedContinuation { continuation in
            let options = PHLivePhotoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.version = original ? .original : .current
            // Called once, with the full version only
            options.deliveryMode = .highQualityFormat
            PHImageManager.default().requestLivePhoto(
                for: asset, targetSize: CGSize(width: 1200, height: 1200), contentMode: .aspectFit, options: options
            ) { livePhoto, _ in
                continuation.resume(returning: livePhoto)
            }
        }
    }

    private struct LivePhotoView: NSViewRepresentable {
        let livePhoto: PHLivePhoto
        let playing: Bool

        final class Coordinator {
            var playing = false
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> PHLivePhotoView {
            let view = PHLivePhotoView()
            view.contentMode = .aspectFit
            view.livePhoto = livePhoto
            return view
        }

        func updateNSView(_ view: PHLivePhotoView, context: Context) {
            if view.livePhoto !== livePhoto { view.livePhoto = livePhoto }
            // Only on a change: starting again on every update would restart the motion
            guard context.coordinator.playing != playing else { return }
            context.coordinator.playing = playing
            if playing { view.startPlayback(with: .full) } else { view.stopPlayback() }
        }
    }
}

/// AVKit's own player view. SwiftUI's VideoPlayer crashes on macOS 27: nothing else references AVKit,
/// so the framework is never loaded and its player class cannot be found at runtime.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
    }
}
