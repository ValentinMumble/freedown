import SwiftUI

/// Duplicates & Similar: exact copies, which can all go in one click, then similar shots to review.
struct GroupsView: View {
    @Environment(Library.self) private var library
    @Binding var selection: Set<String>
    let actions: Actions
    /// Items the user chose to keep, per group; the suggested pick until they change it
    @State private var keeps: [String: Set<String>] = [:]

    private struct Row: Identifiable {
        let group: ItemGroup
        let items: [Item]
        let keep: Set<String>
        var id: String { group.id }
        var toDelete: [Item] { items.filter { !keep.contains($0.id) } }
    }

    private func rows(_ groups: [ItemGroup]) -> [Row] {
        groups.compactMap { group in
            // Items deleted since the groups were made drop out
            let items = group.itemIds.compactMap { library.itemsById[$0] }
            guard items.count > 1 else { return nil }
            return Row(group: group, items: items, keep: keeps[group.id] ?? [group.pick])
        }
    }

    var body: some View {
        let copies = rows(library.duplicateGroups)
        let copied = Set(copies.flatMap { $0.items.map(\.id) })
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                section("Exact copies", rows: copies, deleteAll: true)
                if let similar = library.analysis.similarGroups {
                    // A group made only of exact copies is already listed above
                    let rows = rows(similar).filter { !Set($0.items.map(\.id)).isSubset(of: copied) }.reversed()
                    section("Similar shots", rows: Array(rows), deleteAll: false)
                } else {
                    Text("Similar shots").font(.title3.weight(.semibold)).padding(.top, 8)
                    ProgressView(value: library.analysis.similarProgress) {
                        Text("Comparing photos taken \(Similar.gapText) apart…")
                    }
                    .task { await library.findSimilar() }
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func section(_ title: String, rows: [Row], deleteAll: Bool) -> some View {
        let all = rows.flatMap(\.toDelete)
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.semibold))
            Text(rows.isEmpty ? "none" : "\(Format.count(rows.count, "group")), \(Format.count(all.count, "item")) could go (\(Format.bytes(all.reduce(0) { $0 + $1.size })))")
                .foregroundStyle(.secondary)
            Spacer()
            if deleteAll {
                // Exact copies are safe to remove together; similar shots deserve a look each
                Button("Delete All \(all.count) Extra Copies…", role: .destructive) { actions.delete(all) }
                    .disabled(all.isEmpty)
            }
        }
        .padding(.top, 8)
        ForEach(rows) { row in groupView(row) }
    }

    private func groupView(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(Format.date(row.items[0].date)).font(.headline)
                Text("\(row.items.count) items, \(Format.bytes(row.items.reduce(0) { $0 + $1.size }))")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Delete \(row.toDelete.count) (\(Format.bytes(row.toDelete.reduce(0) { $0 + $1.size })))…", role: .destructive) {
                    actions.delete(row.toDelete)
                }
                .disabled(row.toDelete.isEmpty)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(row.items) { item in shot(item, row) }
                }
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func shot(_ item: Item, _ row: Row) -> some View {
        let kept = row.keep.contains(item.id)
        let selected = selection.contains(item.id)
        return VStack(alignment: .leading, spacing: 4) {
            Thumbnail(asset: item.asset, pixels: 400)
                .frame(width: 200, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .opacity(kept ? 1 : 0.45)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(selected ? Color.accentColor : kept ? .green : .clear, lineWidth: 3)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { actions.open(item) }
                .onTapGesture { selection = [item.id] }
                .help("Click to see it on the right, double-click to open in Photos")
            HStack {
                Button(kept ? "Keep" : "Delete", systemImage: kept ? "checkmark.circle.fill" : "trash.circle") {
                    toggle(item, row)
                }
                .buttonStyle(.borderless)
                .fontWeight(.semibold)
                .foregroundStyle(kept ? .green : .red)
                .help("Switch between keep and delete")
                Spacer()
                if item.id == row.group.pick { Text("best") }
                if item.favorite { Text("♥") }
                if let score = row.group.scores[item.id] { Text(String(format: "score %.2f", score)) }
            }
            .font(.caption)
            Text("\(item.filename) · \(Format.bytes(item.size))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 200)
        .contextMenu { ItemMenu(items: [item], actions: actions) }
    }

    private func toggle(_ item: Item, _ row: Row) {
        var keep = row.keep
        if keep.contains(item.id) {
            // Always keep at least one of a group
            guard keep.count > 1 else { return }
            keep.remove(item.id)
        } else {
            keep.insert(item.id)
        }
        keeps[row.group.id] = keep
    }
}
