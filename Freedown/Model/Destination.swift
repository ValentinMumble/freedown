import Foundation

/// The entries of the sidebar: each one a view of the library with its own filter and explanation.
enum Destination: String, CaseIterable, Identifiable, Hashable {
    case cleanup, videos, photos, similar, accidental, live, lifeless, hiddenMotion, edited, rotated, jpeg, screenshots,
        shrinking, drive, halfFrame, favorites

    /// What the main area shows for a destination
    enum Page { case grid, groups, shrinking, files, cleanup, halfFrame }

    var id: String { rawValue }

    static let sections = ["This Mac", "Library", "Free up space", "Film", "Browse"]

    var section: String {
        switch self {
        case .videos, .photos: "Library"
        case .similar, .accidental, .live, .lifeless, .hiddenMotion, .edited, .rotated, .jpeg, .screenshots, .shrinking, .drive:
            "Free up space"
        case .cleanup: "This Mac"
        case .halfFrame: "Film"
        case .favorites: "Browse"
        }
    }

    /// Whether the view lists photos and videos, with their details panel and actions
    var showsItems: Bool { page == .grid || page == .groups || page == .shrinking }

    var page: Page {
        switch self {
        case .similar: .groups
        case .shrinking: .shrinking
        case .drive: .files
        case .cleanup: .cleanup
        case .halfFrame: .halfFrame
        default: .grid
        }
    }

    var label: String {
        switch self {
        case .videos: "Videos"
        case .photos: "Photos"
        case .similar: "Duplicates & Similar"
        case .accidental: "Probably Accidental"
        case .screenshots: "Screenshots"
        case .shrinking: "Shrinking"
        case .drive: "iCloud Drive"
        case .cleanup: "Clean Up"
        case .halfFrame: "Half-Frame Scans"
        case .favorites: "Favorites"
        case .edited: "Edited"
        case .rotated: "Only Rotated"
        case .live: "Live Photos"
        case .lifeless: "No People or Pets"
        case .hiddenMotion: "Hidden Motion"
        case .jpeg: "JPEG Photos"
        }
    }

    var symbol: String {
        switch self {
        case .videos: "video"
        case .photos: "photo"
        case .similar: "square.on.square"
        case .accidental: "questionmark.square.dashed"
        case .screenshots: "camera.viewfinder"
        case .shrinking: "gearshape.2"
        case .drive: "icloud"
        case .cleanup: "internaldrive"
        case .halfFrame: "rectangle.split.2x1"
        case .favorites: "heart"
        case .edited: "slider.horizontal.3"
        case .rotated: "rotate.right"
        case .live: "livephoto"
        case .lifeless: "mountain.2"
        case .hiddenMotion: "eye.slash"
        case .jpeg: "photo.badge.arrow.down"
        }
    }

    /// One line under the title, saying what the view is for
    var hint: String {
        switch self {
        case .videos:
            "Every video in the library. Videos take most of the space: the biggest come first. Select some, then Shrink to re-encode them to a smaller file with ffmpeg: a copy is kept only if it is at least 20% smaller and looks the same. An edited video (rotated, trimmed) is shrunk as it looks now. Slow-motion videos are left out: their copy would lose the slow motion."
        case .photos: "Every photo in the library."
        case .similar:
            "Exact copies first: one of each is kept (a favorite, then an edited one, then the one in more albums) and the rest can go in one click. Then photos taken less than a minute apart that look alike: check each group. Click a shot to see it on the right, click Keep or Delete under it to switch."
        case .accidental:
            "Photos that look taken by mistake: in a pocket, of the floor, a black or blurred frame. Vision, on this Mac, gave them a very low score and found nobody in them. Favorites and edited photos are left out. Some may still be worth keeping, so look before deleting."
        case .screenshots: "Screenshots are rarely worth keeping for long."
        case .shrinking:
            "Videos being shrunk, one at a time, and the results. Copies go into Photos with the same date, place, favorite and albums. Once you have checked a copy, delete the originals here: that is what frees the space. A copy refused for its quality waits here too: compare it with the original and save it anyway if it looks fine."
        case .favorites: "Favorite photos and videos."
        case .halfFrame:
            "Scans of half-frame film: the lab puts two shots side by side on one picture, with a dark strip between them. Check each cut, turn the halves you shot holding the camera sideways, then Split: each scan becomes two photos with its date, place, favorite and albums, and the scan goes to Recently Deleted."
        case .cleanup:
            "Disk space on this Mac: the Trash, Docker leftovers, caches that tools and apps fill again on their own, and apps not opened for a while. Each size is measured on the disk, and measured again after cleaning. Nothing here touches your photos or iCloud."
        case .drive:
            "Files in iCloud Drive and in apps' iCloud folders, from 1 MB, biggest first. Select some, then Move to Trash: they leave iCloud Drive on all your devices. When macOS keeps a file for the app that made it, Finder moves it instead, and macOS asks you once to allow that. Files an app keeps for itself, like WhatsApp's chat backup, are listed so you see what they take, but are deleted from that app. Double-click a file to open it."
        case .edited:
            "iCloud keeps both the original and the edited version of these. Select some, then Keep Edited Version: the edited version is saved as a new item with the same date, place, favorite and albums, and the original is deleted. A Live Photo stays a Live Photo, with its edited motion. The edit can no longer be undone."
        case .rotated:
            "Edits that only rotate an item, or change nothing at all: iCloud still keeps the original under them, a full extra copy. Select some, then Keep Edited Version: the rotated version is saved as a new item with the same date, place, favorite and albums, and the original is deleted. A Live Photo stays a Live Photo, with its rotated motion."
        case .jpeg:
            "JPEG photos that HEIC could make smaller. Only lightly compressed ones are listed (1.5 bits per pixel or more): most phone JPEGs are already about as small as HEIC would make them. Select some, then Convert to HEIC: each copy is checked against its JPEG before it takes its place, with the same date, place, favorite and albums. A photo with an HDR layer, or whose copy would look different or save under 20%, stays a JPEG and leaves this list. On this library about half of those listed passed. A Google Motion Photo loses its hidden video."
        case .hiddenMotion:
            "Stills that still store the motion clip of the Live Photo they came from, though Photos no longer plays it, so iCloud still counts it. Select them, then Remove Motion: each is saved again as a new file, and iCloud lets go of the clip."
        case .lifeless:
            "Live Photos where Vision, on this Mac, found no person, face, cat or dog: landscapes, food, things, where the motion rarely adds much. Select some, then Remove Motion: each becomes a still, with its edit, the same date, place, favorite and albums. It can miss someone small or turned away, so look before removing."
        case .live:
            "Live Photos carry a few seconds of video, often bigger than the photo itself. Select some, then Remove Motion: each becomes a still, with its edit, the same date, place, favorite and albums."
        }
    }

    /// What the toolbar's main button does here, and what the sidebar counts it would free
    var replacement: Replacement? {
        switch self {
        case .live, .lifeless, .hiddenMotion: .removeMotion
        case .jpeg: .convertToHEIC
        case .edited, .rotated: .keepEdit
        default: nil
        }
    }

    /// Whether the grid of this destination shows an item
    func includes(_ item: Item, in context: ListContext) -> Bool {
        switch self {
        case .videos: item.kind == .video
        case .photos: item.kind == .photo
        case .similar, .shrinking, .drive, .cleanup, .halfFrame: false
        case .screenshots: item.screenshot
        case .favorites: item.favorite
        case .edited: Replacement.keepEdit.applies(to: item)
        case .rotated: item.onlyRotated
        case .live: item.live
        case .lifeless: item.live && context.lifeless.contains(item.id)
        case .accidental: context.accidental.contains(item.id)
        case .hiddenMotion: item.hiddenMotion
        case .jpeg: Replacement.convertToHEIC.applies(to: item)
        }
    }
}

/// What some destinations need besides the item itself: what the analyses found
struct ListContext {
    /// Live Photos where Vision found nobody (see Subjects)
    var lifeless: Set<String> = []
    /// Photos that look taken by mistake (see Accidental)
    var accidental: Set<String> = []
}

enum Sort: String, CaseIterable, Identifiable {
    case biggest, newest, oldest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .biggest: "Biggest First"
        case .newest: "Newest First"
        case .oldest: "Oldest First"
        }
    }

    func ordered(_ first: Item, _ second: Item) -> Bool {
        switch self {
        case .biggest: first.size > second.size
        case .newest: first.date > second.date
        case .oldest: first.date < second.date
        }
    }
}
