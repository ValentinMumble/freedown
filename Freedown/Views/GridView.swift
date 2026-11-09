import SwiftUI

/// Items as square cards. Click selects one, Cmd-click adds or removes, Shift-click selects a range,
/// double-click opens the item in Photos, right-click shows what can be done to it, the arrow keys move.
struct GridView: View {
    let items: [Item]
    @Binding var selection: Set<String>
    let actions: Actions
    /// The last arrow key pressed in the window
    var arrow: Arrow?
    @Environment(Library.self) private var library
    @AppStorage(Settings.Key.thumbnailSize.rawValue) private var cardWidth = Self.defaultCardWidth
    @State private var anchor: Int?
    /// Cards per row, for the up and down arrows
    @State private var columns = 1
    /// The card a drag hovers over
    @State private var dropTarget: String?

    /// A right-click acts on the whole selection when the item is part of it, like in Finder
    private func targets(_ item: Item) -> [Item] {
        selection.contains(item.id) ? items.filter { selection.contains($0.id) } : [item]
    }

    /// Which video is a shrunk copy, which original has one and can go, which was tried and left as it
    /// was, and which edit only rotates
    private func mark(_ item: Item) -> String? {
        if library.marked.contains(item.id) { return "Marked" }
        if library.shrinkStatus.copies[item.id] != nil { return "Shrunk" }
        if library.shrinkStatus.shrunk.contains(item.id) { return "Copy saved" }
        if library.shrinkStatus.kept.contains(item.id) { return "Not shrunk" }
        if item.onlyRotated { return "Only rotated" }
        if item.hiddenMotion { return "Hidden motion" }
        return nil
    }

    var body: some View {
        if items.isEmpty {
            ContentUnavailableView("Nothing here", systemImage: "photo.on.rectangle", description: Text("No items match."))
        } else {
            let width = CGFloat(min(max(cardWidth, Self.cardWidths.lowerBound), Self.cardWidths.upperBound))
            let pixels = Self.pixels(for: width)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: width), spacing: Self.spacing)], spacing: Self.spacing) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            Card(item: item, selected: selection.contains(item.id), mark: mark(item), pixels: pixels)
                                .onTapGesture { click(index) }
                                // Drop photos on another one to give them its date and time, just after it
                                .draggable(item.id) { Thumbnail(asset: item.asset, pixels: 160).frame(width: 80, height: 80) }
                                .dropDestination(for: String.self) { ids, _ in
                                    drop(ids, on: item)
                                } isTargeted: { over in
                                    dropTarget = over ? item.id : (dropTarget == item.id ? nil : dropTarget)
                                }
                                // macOS keeps the cursor during a drag, so the card says where the drop goes:
                                // a bar on its right edge, where the photo lands, and the time it will take
                                .overlay(alignment: .trailing) {
                                    if dropTarget == item.id {
                                        ZStack(alignment: .topTrailing) {
                                            RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 2)
                                            Capsule().fill(Color.accentColor).frame(width: 5).padding(.vertical, 2).offset(x: 4)
                                            Label("After \(item.date.formatted(date: .omitted, time: .shortened))", systemImage: "arrow.turn.down.right")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 3)
                                                .background(Color.accentColor, in: Capsule())
                                                .padding(6)
                                        }
                                        .allowsHitTesting(false)
                                    }
                                }
                                .contextMenu { ItemMenu(items: targets(item), actions: actions) }
                        }
                    }
                    // Only read by the arrow keys, never fed back into the layout
                    .onGeometryChange(for: Int.self) { geometry in
                        max(1, Int((geometry.size.width + Self.spacing) / (width + Self.spacing)))
                    } action: { count in
                        columns = count
                    }
                    .padding(12)
                }
                .onChange(of: arrow) {
                    if let arrow { move(arrow.direction, proxy) }
                }
            }
        }
    }

    /// The smallest a card gets, in points: the toolbar's slider and View > Bigger or Smaller Thumbnails set it
    static let defaultCardWidth = 150.0
    static let cardWidths = 100.0...400.0
    nonisolated private static let spacing: CGFloat = 4

    /// What to ask Photos for: a card grows up to twice its smallest width to fill a row, on a 2x screen. In
    /// steps, so the slider does not ask again for every point.
    private static func pixels(for width: CGFloat) -> CGFloat {
        width <= 160 ? 320 : width <= 260 ? 640 : 960
    }

    /// Left and right go to the previous and next item, up and down a row, scrolling to keep it in view
    private func move(_ direction: Arrow.Direction, _ proxy: ScrollViewProxy) {
        let current =
            anchor.flatMap { items.indices.contains($0) && selection.contains(items[$0].id) ? $0 : nil }
            ?? items.firstIndex { selection.contains($0.id) }
        let step =
            switch direction {
            case .left: -1
            case .right: 1
            case .up: -columns
            case .down: columns
            }
        let next = current.map { min(max($0 + step, 0), items.count - 1) } ?? 0
        selection = [items[next].id]
        anchor = next
        proxy.scrollTo(items[next].id)
    }

    /// A dragged photo brings the rest of the selection when it is part of it, like in Finder
    private func drop(_ ids: [String], on target: Item) -> Bool {
        dropTarget = nil
        let dragged = Set(ids.contains { selection.contains($0) } ? Array(selection) + ids : ids)
        let moving = items.filter { dragged.contains($0.id) && $0.id != target.id }
        guard !moving.isEmpty else { return false }
        actions.placeAfter(moving, target)
        return true
    }

    /// A separate double-click gesture would hold every click until the double-click time ran out, and by then
    /// Shift or Cmd is often let go: so one gesture, reading the click itself
    private func click(_ index: Int) {
        let event = NSApp.currentEvent
        if (event?.clickCount ?? 1) >= 2 {
            actions.open(items[index])
            return
        }
        let modifiers = event?.modifierFlags ?? NSEvent.modifierFlags
        let id = items[index].id
        if modifiers.contains(.shift), let anchor, anchor < items.count {
            for item in items[min(anchor, index)...max(anchor, index)] { selection.insert(item.id) }
        } else if modifiers.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
        anchor = index
    }
}

/// An arrow key press, handed from the window's key handling to the grid. Each press is new, so pressing the
/// same arrow twice moves twice.
struct Arrow: Equatable {
    enum Direction {
        case left, right, up, down

        init?(_ key: NSEvent.SpecialKey?) {
            switch key {
            case .leftArrow?: self = .left
            case .rightArrow?: self = .right
            case .upArrow?: self = .up
            case .downArrow?: self = .down
            default: return nil
            }
        }
    }

    let direction: Direction
    let id = UUID()
}

struct Card: View {
    let item: Item
    let selected: Bool
    var mark: String?
    var pixels: CGFloat = 320

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { Thumbnail(asset: item.asset, pixels: pixels) }
            .overlay(alignment: .topLeading) {
                // Pills pad themselves: pull them closer together
                HStack(spacing: -6) {
                    if item.favorite { Pill(text: "♥") }
                    if let mark { Pill(text: mark) }
                }
            }
            .overlay(alignment: .topTrailing) { Pill(text: Format.bytes(item.size)) }
            .overlay(alignment: .bottom) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.filename).fontWeight(.semibold).lineLimit(1)
                        Text(Format.date(item.date))
                    }
                    Spacer(minLength: 4)
                    if item.kind == .video { Text(Format.duration(item.duration)) }
                }
                .font(.caption2)
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.top, 16)
                .padding(.bottom, 5)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 3)
                }
            }
            .opacity(selected ? 0.85 : 1)
            .contentShape(Rectangle())
    }
}

struct Pill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
            .padding(6)
    }
}
