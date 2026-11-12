import SwiftUI

/// Disk space on this Mac that can go: a bar of what each group would free, then one line per thing, with what
/// cleaning it does, a bar of its size and one button. With `largeFiles`, the files in the home folder from the
/// size set in Settings instead, from the last search (kept across launches) or looked for when the page first
/// opens.
struct CleanupView: View {
    var largeFiles = false
    @Environment(Library.self) private var library
    @State private var confirming: CleanupItem?
    @State private var working: Set<String> = []
    @State private var results: [String: String] = [:]
    @State private var free = Self.freeSpace()
    @State private var highlighted: String?
    @AppStorage(Settings.Key.largeFileMegabytes.rawValue) private var largeFileMegabytes = Cleanup.defaultLargeFileMegabytes

    /// The smallest large file shown: a bigger size than the search's applies at once
    private var minimum: Int64 { Int64(max(1, largeFileMegabytes)) << 20 }

    private var items: [CleanupItem] {
        guard largeFiles else { return library.cleanupItems ?? [] }
        // A file just cleaned keeps its line, to say what happened
        return (library.largeFiles ?? []).filter { $0.size >= minimum || results[$0.id] != nil }
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 10) {
                if largeFiles {
                    largeFilesPage
                } else if library.cleanupItems != nil {
                    overview(proxy).padding(.horizontal, 16)
                    list
                } else {
                    ProgressView("Measuring the Trash, Docker, caches and apps…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task {
            if largeFiles {
                if library.largeFiles == nil && library.largeFilesProgress == nil { await library.findLargeFiles() }
            } else if library.cleanupItems == nil {
                await measure()
            }
        }
        .confirmationDialog(
            confirming.map(question) ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { item in
            Button(buttonTitle(item), role: .destructive) { clean(item) }
        } message: { item in
            Text(item.detail)
        }
    }

    // MARK: Overview

    /// What each group would free, side by side in one bar, with its legend
    private func overview(_ proxy: ScrollViewProxy) -> some View {
        let groups = CleanupItem.Group.allCases.compactMap { group -> (CleanupItem.Group, Int64)? in
            let total = items.filter { $0.group == group && $0.cleanable }.reduce(0) { $0 + $1.size }
            return total > 0 ? (group, total) : nil
        }
        let total = groups.reduce(0) { $0 + $1.1 }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Format.bytes(total)) can be freed").font(.title3.weight(.semibold))
                Text(free.map { "\(Format.bytes($0)) free now" } ?? "").foregroundStyle(.secondary)
                Spacer()
                Button("Measure Again", systemImage: "arrow.clockwise") { Task { await measure() } }
                    .disabled(!working.isEmpty)
            }
            GeometryReader { geometry in
                let gaps = CGFloat(max(0, groups.count - 1)) * 2
                HStack(spacing: 2) {
                    ForEach(groups, id: \.0) { group, size in
                        Rectangle()
                            .fill(group.color)
                            // The smallest groups stay visible as a sliver
                            .frame(width: max(2, (geometry.size.width - gaps) * CGFloat(size) / CGFloat(max(total, 1))))
                            .contentShape(Rectangle())
                            .help("\(group.title): \(Format.bytes(size)), \(Int((Double(size) / Double(max(total, 1)) * 100).rounded()))%")
                            .onTapGesture { show(group, proxy) }
                    }
                }
            }
            .frame(height: 16)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            // The legend, which also says each group's size
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(groups, id: \.0) { group, size in
                    Button {
                        show(group, proxy)
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(group.color).frame(width: 8, height: 8)
                            Text(group.title)
                            Text(Format.bytes(size)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                }
            }
        }
    }

    private func show(_ group: CleanupItem.Group, _ proxy: ScrollViewProxy) {
        guard let first = items.first(where: { $0.group == group }) else { return }
        withAnimation { proxy.scrollTo(first.id, anchor: .top) }
        highlighted = first.id
        Task {
            try? await Task.sleep(for: .seconds(2))
            if highlighted == first.id { highlighted = nil }
        }
    }

    // MARK: List

    private var list: some View {
        // Every row's bar shares one scale, so bars compare across groups
        let largest = max(items.map(\.size).max() ?? 1, 1)
        return List {
            if largeFiles {
                ForEach(items) { row($0, largest: largest) }
            } else {
                ForEach(CleanupItem.Group.allCases, id: \.self) { group in
                    let rows = items.filter { $0.group == group }
                    if !rows.isEmpty {
                        Section {
                            ForEach(rows) { row($0, largest: largest) }
                        } header: {
                            HStack(spacing: 6) {
                                Circle().fill(group.color).frame(width: 8, height: 8)
                                Text(group.title)
                                Spacer()
                                Text(Format.bytes(rows.filter(\.cleanable).reduce(0) { $0 + $1.size }))
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Large files

    @ViewBuilder
    private var largeFilesPage: some View {
        if library.largeFiles != nil {
            let files = items
            HStack(alignment: .firstTextBaseline) {
                Text("\(Format.count(files.count, "file")), \(Format.bytes(files.reduce(0) { $0 + $1.size }))").font(.title3.weight(.semibold))
                Text(free.map { "\(Format.bytes($0)) free now" } ?? "").foregroundStyle(.secondary)
                Spacer()
                if let seen = library.largeFilesProgress {
                    ProgressView().controlSize(.small)
                    Text("\(seen.formatted()) items looked at").foregroundStyle(.secondary).monospacedDigit()
                } else {
                    if let searched = library.largeFilesSearched {
                        Text("Looked \(searched.formatted(.relative(presentation: .named)))").foregroundStyle(.secondary)
                            .help("Files moved or deleted since are left out. A new file shows after Look Again.")
                    }
                    Button("Look Again", systemImage: "arrow.clockwise") {
                        results = [:]
                        Task { await library.findLargeFiles() }
                    }
                    .disabled(!working.isEmpty)
                }
            }
            .padding(.horizontal, 16)
            HStack(spacing: 4) {
                Text("From \(Format.bytes(minimum))")
                SettingsLink { Text("Change…") }.buttonStyle(.link)
                if let searched = library.largeFilesMinimum, minimum < searched, library.largeFilesProgress == nil {
                    Text("The last search looked from \(Format.bytes(searched)): Look Again to find the files in between.")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            if files.isEmpty {
                ContentUnavailableView(
                    "No large file", systemImage: "scalemass",
                    description: Text("Nothing of \(Format.bytes(minimum)) or more outside what Clean Up, iCloud Drive and Photos cover."))
            } else {
                list
            }
        } else {
            ProgressView {
                Text("Looking through your home folder… \((library.largeFilesProgress ?? 0).formatted()) items so far")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ item: CleanupItem, largest: Int64) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).fontWeight(.medium)
                Text(item.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                // Its size against the largest line; grey when it can't be cleaned from here
                GeometryReader { geometry in
                    Capsule()
                        .fill(item.cleanable ? item.group.color : Color.secondary.opacity(0.35))
                        .frame(width: max(2, geometry.size.width * CGFloat(item.size) / CGFloat(largest)))
                }
                .frame(height: 4)
                if let result = results[item.id] {
                    Text(result).font(.callout).foregroundStyle(result.hasPrefix("Freed") || result == "In the Trash" ? .green : .red)
                }
            }
            Spacer()
            Text(Format.bytes(item.size)).monospacedDigit()
            if let target = item.reveal {
                Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([target]) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
            }
            if working.contains(item.id) {
                ProgressView().controlSize(.small)
            } else if let app = item.quitFirst {
                Text("Quit \(app) first").font(.callout).foregroundStyle(.secondary)
            } else if case .none = item.action {
                EmptyView()
            } else {
                Button(buttonTitle(item)) { confirming = item }
                    .disabled(!item.cleanable)
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(highlighted == item.id ? Color.accentColor.opacity(0.12) : nil)
        .contextMenu {
            if item.appBundle != nil {
                Button("Always Keep This App") { library.keepApp(item) }
            }
            if item.group == .files, let target = item.reveal {
                Button("Always Skip This File") { library.skip(target.path) }
                Button("Always Skip Its Folder") { library.skip(target.deletingLastPathComponent().path) }
            }
        }
    }

    // MARK: Actions

    private func buttonTitle(_ item: CleanupItem) -> String {
        switch item.action {
        case .emptyTrash: "Empty Trash…"
        case .moveToTrash: "Move to Trash…"
        default: "Clean…"
        }
    }

    private func question(_ item: CleanupItem) -> String {
        switch item.action {
        case .emptyTrash: "Empty the Trash (\(Format.bytes(item.size)))? This can't be undone."
        case .moveToTrash: "Move \(item.name) (\(Format.bytes(item.size))) to the Trash?"
        default: "Clean \(item.name) (\(Format.bytes(item.size)))?"
        }
    }

    private func clean(_ item: CleanupItem) {
        working.insert(item.id)
        results[item.id] = nil
        Task {
            results[item.id] = await library.clean(item)
            working.remove(item.id)
            free = Self.freeSpace()
        }
    }

    private func measure() async {
        results = [:]
        await library.scanCleanup()
        free = Self.freeSpace()
    }

    /// Space no file holds, without what macOS could free on its own
    private static func freeSpace() -> Int64? {
        let values = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacity.map(Int64.init)
    }
}

extension CleanupItem.Group {
    /// One fixed color per group, in the palette's order
    var color: Color { Palette.color(CleanupItem.Group.allCases.firstIndex(of: self)!) }
}
