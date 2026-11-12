import SwiftUI

struct Sidebar: View {
    @Environment(Library.self) private var library
    @Environment(Shrinker.self) private var shrinker
    @Binding var destination: Destination?
    @AppStorage(Settings.Key.largeFileMegabytes.rawValue) private var largeFileMegabytes = Cleanup.defaultLargeFileMegabytes

    var body: some View {
        List(selection: $destination) {
            if let storage = library.storage {
                Section("iCloud") { StorageView(storage: storage, library: library) }
            }
            ForEach(Destination.sections, id: \.self) { section in
                Section(section) {
                    ForEach(Destination.allCases.filter { $0.section == section }) { entry in
                        // A badge keeps the row's width fixed while the counts change
                        Label(entry.label, systemImage: entry.symbol)
                            .badge(Text(tally(entry)))
                            .tag(entry)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func tally(_ entry: Destination) -> String {
        if entry == .similar {
            let copies = library.duplicateGroups.reduce(0) { $0 + $1.itemIds.count - 1 }
            let similar = library.analysis.similarGroups.map { ", \(Format.count($0.count, "group"))" } ?? ""
            return "\(copies == 1 ? "1 copy" : "\(copies.formatted()) copies")\(similar)"
        }
        if entry == .shrinking {
            if shrinker.running > 0 { return "\(shrinker.running) running" }
            let originals = library.shrinkRecords.values.filter { $0.copy != nil && library.itemsById[$0.original] != nil }
            return originals.isEmpty ? "" : "\(originals.count) to delete"
        }
        // Not worked out until the view is first opened
        if entry == .lifeless && library.analysis.lifeless == nil { return "" }
        if entry == .accidental && library.analysis.accidental == nil { return "" }
        if entry == .halfFrame {
            return library.analysis.halfFrames.map { $0.count.formatted() } ?? ""
        }
        if entry == .cleanup {
            guard let items = library.cleanupItems else { return "" }
            return Format.bytes(items.filter(\.cleanable).reduce(0) { $0 + $1.size })
        }
        if entry == .largeFiles {
            guard library.largeFilesProgress == nil, let all = library.largeFiles else { return "" }
            let files = all.filter { $0.size >= Int64(largeFileMegabytes) << 20 }
            return "\(files.count.formatted()) · \(Format.bytes(files.reduce(0) { $0 + $1.size }))"
        }
        if entry == .drive {
            guard let files = library.driveFiles else { return "" }
            return "\(files.count.formatted()) · \(Format.bytes(files.reduce(0) { $0 + $1.size }))"
        }
        guard let tally = library.tallies[entry], tally.count > 0 else { return "0" }
        // Where a replacement applies, what it would free matters more than the size
        if entry == .live || entry == .lifeless || entry == .hiddenMotion || entry == .edited || entry == .rotated {
            return "\(tally.count.formatted()) · −\(Format.bytes(tally.saving))"
        }
        return "\(tally.count.formatted()) · \(Format.bytes(tally.size))"
    }
}

/// iCloud storage by app, like System Settings shows it, plus the library's own size.
struct StorageView: View {
    let storage: ICloudStorage
    let library: Library
    @State private var showSavings = false

    private static let colors: [Color] = [.blue, .orange, .cyan, .green]

    private struct Part: Identifiable {
        let label: String
        let size: Int64
        let color: Color
        var id: String { label }
    }

    private var parts: [Part] {
        let named = storage.apps.prefix(Self.colors.count)
        let others = storage.apps.dropFirst(Self.colors.count).reduce(0) { $0 + $1.size }
        var parts = named.enumerated().map { index, app in Part(label: app.label, size: app.size, color: Self.colors[index]) }
        if others > 0 {
            parts.append(Part(label: "\(storage.apps.count - named.count) other apps", size: others, color: .purple))
        }
        return parts
    }

    /// Space used now. The split by app is macOS's last copy and can lag; the free space is live.
    private var used: Int64 {
        guard let total = storage.total, let free = storage.free else { return storage.used }
        return total - free
    }

    private func trashDetail(_ trash: RecentlyDeleted) -> String {
        var text = "Photos removes deleted items for good 30 days after they were deleted"
        if let purge = trash.firstPurge {
            text += purge < .now ? ", and the oldest are due now" : ", the first on \(purge.formatted(date: .abbreviated, time: .omitted))"
        }
        return text + ". They no longer count toward your iCloud storage (Apple says so), so emptying it frees no iCloud space: it only removes them for good."
    }

    /// Photos, files and caches, in that order
    private var savedTotals: [(Saving.Kind.Category, Int64)] {
        let totals = Savings.totals(library.savings)
        return Saving.Kind.Category.allCases.map { ($0, totals[$0] ?? 0) }
    }

    private func savedRow(_ category: Saving.Kind.Category, _ total: Int64) -> some View {
        // Caches come back, so they are not shown as won
        let caches = category == .caches
        return HStack {
            Text(caches ? "Caches, they fill again" : category.label)
            Spacer()
            Text(Format.bytes(total)).foregroundStyle(caches ? Color.secondary : Color.green)
        }
        .padding(.leading, 14)
    }

    /// The saved total by kind of change, since the first one
    private var savedDetail: String {
        let byKind = Dictionary(grouping: library.savings, by: \.kind)
        let lines = Saving.Kind.allCases.compactMap { kind -> String? in
            guard let entries = byKind[kind] else { return nil }
            let count = entries.reduce(0) { $0 + $1.count }
            return "\(kind.label): \(Format.count(count, kind.noun)), \(Format.bytes(entries.reduce(0) { $0 + $1.bytes }))"
        }
        let since = library.savings.first.map { "Since \($0.date.formatted(date: .abbreviated, time: .omitted))\n" } ?? ""
        return since + lines.joined(separator: "\n")
            + "\nPhotos and iCloud Drive files free iCloud space, counted when the change is made: Apple says items in Recently Deleted don't count toward your iCloud storage. Files deleted from this Mac and caches free its disk. Caches are counted apart, since apps fill them again as they work."
    }

    var body: some View {
        // What changed since macOS last fetched the split by app: positive when space was freed
        let freedSince = storage.used - used
        // Shrink the parts to what is used now, so the bar matches the live free space
        let scale = storage.used > 0 ? min(1, Double(used) / Double(storage.used)) : 1
        VStack(alignment: .leading, spacing: 6) {
            if let total = storage.total {
                HStack {
                    Text("\(Format.bytes(used)) of \(Format.bytes(total)) used")
                    Spacer()
                }
                .font(.callout)
                // Drawn rather than laid out: measuring inside a sidebar row can loop the window's layout
                Canvas { context, size in
                    var x = 0.0
                    for part in parts {
                        let width = size.width * Double(part.size) * scale / Double(total)
                        context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)), with: .color(part.color))
                        x += width
                    }
                }
                .frame(height: 8)
                .background(.quaternary)
                .clipShape(Capsule())
            }
            ForEach(parts) { part in
                HStack(spacing: 6) {
                    Circle().fill(part.color).frame(width: 8, height: 8)
                    Text(part.label)
                    Spacer()
                    Text(Format.bytes(part.size)).foregroundStyle(.secondary)
                }
            }
            if let free = storage.free {
                HStack(spacing: 6) {
                    Circle().strokeBorder(.secondary).frame(width: 8, height: 8)
                    Text("Free")
                    Spacer()
                    Text(Format.bytes(free)).fontWeight(.semibold)
                }
            }
            if !library.savings.isEmpty {
                Button {
                    showSavings = true
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle").frame(width: 8)
                            Text("Saved with Freedown")
                            Spacer()
                        }
                        ForEach(savedTotals.filter { $0.1 != 0 }, id: \.0) { category, total in
                            savedRow(category, total)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(savedDetail + "\nClick for the history.")
                .sheet(isPresented: $showSavings) { SavingsSheet(library: library) }
            }
            switch library.recentlyDeleted {
            case .success(let trash) where trash.count > 0:
                HStack(spacing: 6) {
                    Image(systemName: "trash").frame(width: 8)
                    Text("Recently Deleted")
                    Spacer()
                    Text("\(trash.count.formatted()) · \(Format.bytes(trash.size))").foregroundStyle(.secondary)
                }
                .help(trashDetail(trash))
            case .failure(.noAccess):
                Button {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash").frame(width: 8)
                        Text("Recently Deleted: allow Full Disk Access")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(
                    "Photos hides deleted items from other apps, so Freedown reads Photos' own database for this. Click to open System Settings, then turn on Freedown under Full Disk Access."
                )
            default:
                EmptyView()
            }
            if let fetchedAt = storage.fetchedAt {
                // Ignore small drifts: photos keep syncing
                let change =
                    abs(freedSince) <= 100 << 20 ? ""
                    : freedSince > 0 ? ", \(Format.bytes(freedSince)) freed since" : ", \(Format.bytes(-freedSince)) added since"
                Text("By app as of \(Format.time(fetchedAt))\(change)")
                    .foregroundStyle(.tertiary)
                    .help(
                        "macOS fetches the split by app from Apple now and then. The free space is read every minute, so what changed since covers everything in iCloud, not only Freedown."
                    )
            }
        }
        .font(.caption)
        .padding(.vertical, 4)
    }
}
