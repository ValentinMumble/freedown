import SwiftUI

struct ContentView: View {
    @Environment(Library.self) private var library
    @Environment(Shrinker.self) private var shrinker
    // For screenshots: open --args -StartDestination similar -SelectFirst YES
    @State private var destination: Destination? =
        Destination(rawValue: UserDefaults.standard.string(forKey: Settings.Key.startDestination.rawValue) ?? "") ?? .videos
    @State private var selection: Set<String> = []
    @State private var sort: Sort = .biggest
    @State private var year = 0
    @State private var search = ""
    @State private var showInspector = true
    @State private var dateRequest: DateRequest?
    @State private var shrinkRequest: ShrinkRequest?
    @State private var replaceRequest: ReplaceRequest?
    @State private var keyMonitor: Any?
    @State private var arrow: Arrow?
    @AppStorage(Settings.Key.videosNotShrunkOnly.rawValue) private var notShrunkOnly = false
    @AppStorage(Settings.Key.thumbnailSize.rawValue) private var thumbnailSize = GridView.defaultCardWidth

    private var current: Destination { destination ?? .videos }

    /// The destination's items, before the year and search filters
    private func listed(_ item: Item, _ context: ListContext) -> Bool {
        current.includes(item, in: context)
            && (current != .videos || !notShrunkOnly || library.shrinkUntried(item))
    }

    private var shown: [Item] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let context = library.listContext
        return library.items
            .filter { item in
                listed(item, context)
                    && (year == 0 || Calendar.current.component(.year, from: item.date) == year)
                    && (query.isEmpty || item.filename.lowercased().contains(query))
            }
            .sorted(by: sort.ordered)
    }

    private var selected: [Item] {
        library.items.filter { selection.contains($0.id) }
    }

    private var years: [Int] {
        let context = library.listContext
        let years = library.items.filter { listed($0, context) }
            .map { Calendar.current.component(.year, from: $0.date) }
        return Array(Set(years)).sorted(by: >)
    }

    private var actions: Actions {
        Actions(
            open: { item in
                // AppleScript's spotlight command crashes Photos on macOS 27; this link does not
                NSWorkspace.shared.open(URL(string: "photos-navigation://asset?uuid=\(item.uuid)")!)
            },
            changeDate: { items in dateRequest = DateRequest(items: items) },
            setFavorite: { items, favorite in Task { await library.setFavorite(items, favorite) } },
            delete: { items in
                Task {
                    // A deleted video leaves the shrink list too
                    if await library.delete(items) { shrinker.forget(items) }
                }
            },
            shrink: { items in shrinkRequest = ShrinkRequest(items: items) },
            replace: { items, kind in replaceRequest = ReplaceRequest(items: items, kind: kind) }
        )
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(destination: $destination)
                .navigationSplitViewColumnWidth(min: 240, ideal: 270)
        } detail: {
            detail
                .navigationTitle(current.label)
                .navigationSubtitle(subtitle)
                // Small minimums: when the columns' minimums add up to more than the window, resizing a column
                // makes the split view and the grid fight over the width, and the layout never settles
                .navigationSplitViewColumnWidth(min: 300, ideal: 800)
        }
        // Files have no details panel: the table shows all there is
        .inspector(isPresented: Binding(get: { showInspector && current.showsItems }, set: { showInspector = $0 })) {
            Inspector(items: selected, actions: actions)
                .inspectorColumnWidth(min: 260, ideal: 420, max: 600)
        }
        .toolbar { toolbar }
        .searchable(text: $search, placement: .toolbar, prompt: "File name")
        .sheet(item: $dateRequest) { request in DateSheet(items: request.items) }
        .sheet(item: $replaceRequest) { request in ReplaceSheet(request: request) }
        .sheet(item: $shrinkRequest) { request in
            ShrinkSheet(items: request.items) { items, preset in
                shrinker.enqueue(items, preset: preset)
                destination = .shrinking
            }
        }
        .onChange(of: library.state) {
            if library.state == .ready, selection.isEmpty, UserDefaults.standard.bool(forKey: Settings.Key.selectFirst.rawValue),
                let first = shown.first
            {
                selection = [first.id]
            }
        }
        .onChange(of: destination) {
            selection = []
            year = 0
        }
        .alert("Photos refused the change", isPresented: errorShown) {
            Button("OK") { library.error = nil }
        } message: {
            Text(library.error ?? "")
        }
        .task {
            guard !FreedownApp.isTesting else { return }
            await library.start()
            shrinker.restoreQueue()
        }
        // Cmd-A selects every item shown. The Edit menu's Select All only reaches text fields, so the key is
        // caught before it, except while typing in a field or with a sheet open.
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard let window = NSApp.keyWindow, window.sheetParent == nil, !(window.firstResponder is NSText)
                else { return event }
                let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
                let key = event.charactersIgnoringModifiers
                if modifiers == .command, key == "a", current.page == .grid {
                    selection = Set(shown.map(\.id))
                    return nil
                }
                // The arrow keys move through the grid wherever the focus is: after dragging a divider, or
                // with the video player in the panel (which steps frames with them), the grid would miss them
                if modifiers.isEmpty, current.page == .grid, let direction = Arrow.Direction(event.specialKey) {
                    arrow = Arrow(direction: direction)
                    return nil
                }
                // M marks the selected Live Photos for Remove Motion, or unmarks them
                if modifiers.isEmpty, key == "m", selected.contains(where: \.live) {
                    library.toggleMark(selected)
                    return nil
                }
                // Space plays or pauses the video or Live Photo in the panel, Return opens the item in Photos
                if modifiers.isEmpty, key == " ", selection.count == 1 {
                    NotificationCenter.default.post(name: .togglePlayback, object: nil)
                    return nil
                }
                if modifiers.isEmpty, [.carriageReturn, .enter].contains(event.specialKey), let item = selected.first, selection.count == 1 {
                    actions.open(item)
                    return nil
                }
                return event
            }
        }
        .onDisappear { keyMonitor.map(NSEvent.removeMonitor) }
        // Free space changes with anything stored in iCloud: read it again every minute and on coming back
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await library.refreshStorage()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await library.refreshStorage() }
        }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })
    }

    private var subtitle: String {
        guard library.state == .ready, current.page == .grid else { return "" }
        let items = shown
        return "\(Format.count(items.count, "item")), \(Format.bytes(items.reduce(0) { $0 + $1.size }))"
    }

    @ViewBuilder private var detail: some View {
        switch library.state {
        case .starting:
            ProgressView()
        case .denied:
            ContentUnavailableView(
                "No access to Photos", systemImage: "lock",
                description: Text("Allow Freedown in System Settings › Privacy & Security › Photos, then open it again."))
        case .loading(let done, let total):
            ProgressView(value: Double(done), total: Double(max(total, 1))) {
                Text("Reading \(total.formatted()) items from Photos…")
            }
            .padding(40)
        case .ready:
            VStack(alignment: .leading, spacing: 0) {
                Text(current.hint)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                switch current.page {
                case .groups: GroupsView(selection: $selection, actions: actions)
                case .shrinking: ShrinkView(selection: $selection, actions: actions)
                case .files: FilesView()
                case .cleanup: CleanupView()
                case .grid where current == .lifeless && library.analysis.lifeless == nil:
                    ProgressView(value: library.analysis.subjectsProgress) {
                        Text("Looking for people and pets in each Live Photo…")
                    }
                    .padding(40)
                    .task { await library.findSubjects() }
                case .grid where current == .accidental && library.analysis.accidental == nil:
                    ProgressView(value: library.analysis.accidentalProgress) {
                        Text("Scoring each photo, the first time only…")
                    }
                    .padding(40)
                    .task { await library.findAccidental() }
                case .grid: GridView(items: shown, selection: $selection, actions: actions, arrow: arrow)
                }
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        let videos = selected.filter { $0.kind == .video }.count
        let shrinkable = selected.filter { library.shrinkSkip($0) == nil }.count
        let live = selected.filter(Replacement.removeMotion.applies).count
        let edited = selected.filter(Replacement.keepEdit.applies).count
        let jpegs = selected.filter(Replacement.convertToHEIC.applies).count
        let markedItems = library.items.filter { library.marked.contains($0.id) }
        if current == .live || current == .lifeless || current == .hiddenMotion || (live > 0 && current != .edited && current != .rotated) {
            ToolbarItem {
                Button {
                    actions.replace(selected, .removeMotion)
                } label: {
                    Label(live == 0 ? "Remove Motion" : "Remove Motion from \(live)", systemImage: "livephoto.slash")
                        .labelStyle(.titleAndIcon)
                }
                .prominent(when: live > 0)
                .help(live == 0 ? "Select Live Photos" : "Replace the selected Live Photos by their stills")
            }
        }
        if (current == .live || current == .lifeless) && !markedItems.isEmpty {
            ToolbarItem {
                Button {
                    replaceRequest = ReplaceRequest(items: markedItems, kind: .removeMotion, handPicked: true)
                } label: {
                    Label("Remove Motion from \(markedItems.count) Marked", systemImage: "checklist")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .help("Replace the Live Photos you marked (M) by their stills")
            }
        }
        if current == .edited || current == .rotated {
            ToolbarItem {
                Button {
                    actions.replace(selected, .keepEdit)
                } label: {
                    Label(edited == 0 ? "Keep Edited Version" : "Keep Edited Version of \(edited)", systemImage: "wand.and.stars")
                        .labelStyle(.titleAndIcon)
                }
                .prominent(when: edited > 0)
                .help(edited == 0 ? "Select edited items" : "Replace the selected items by their edited version alone")
            }
        }
        if current == .jpeg {
            ToolbarItem {
                Button {
                    actions.replace(selected, .convertToHEIC)
                } label: {
                    Label(jpegs == 0 ? "Convert to HEIC" : "Convert \(jpegs) to HEIC", systemImage: "photo.badge.arrow.down")
                        .labelStyle(.titleAndIcon)
                }
                .prominent(when: jpegs > 0)
                .help(jpegs == 0 ? "Select JPEG photos" : "Save the selected photos as HEIC, checked against their JPEG")
            }
        }
        if current == .videos || (videos > 0 && current != .live && current != .edited && current != .rotated) {
            ToolbarItem {
                Button {
                    actions.shrink(selected)
                } label: {
                    Label(shrinkable == 0 ? "Shrink" : "Shrink \(Format.count(shrinkable, "Video"))", systemImage: "arrow.down.right.and.arrow.up.left")
                        .labelStyle(.titleAndIcon)
                }
                .prominent(when: shrinkable > 0)
                .help(
                    shrinkable > 0
                        ? "Shrink the selected videos"
                        : selected.compactMap { library.shrinkSkip($0) }.first.map { "Cannot shrink: \($0)" } ?? "Select videos to shrink")
            }
        }
        ToolbarItemGroup {
            if current.page == .grid {
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.label).tag($0) }
                }
                Picker("Year", selection: $year) {
                    Text("All Years").tag(0)
                    ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                }
                Slider(value: $thumbnailSize, in: GridView.cardWidths) {
                    Text("Thumbnail Size")
                } minimumValueLabel: {
                    Image(systemName: "photo").imageScale(.small)
                } maximumValueLabel: {
                    Image(systemName: "photo").imageScale(.large)
                }
                .frame(width: 140)
                .help("Thumbnail size (Cmd-+ and Cmd-−)")
                if current == .videos {
                    Picker("Show", selection: $notShrunkOnly) {
                        Text("All Videos").tag(false)
                        Text("Not Shrunk Yet").tag(true)
                    }
                    .help("Not Shrunk Yet hides shrunk copies, originals that have one, videos tried before and slow-motion videos")
                }
                Button("Select All", systemImage: "checkmark.circle") { selection = Set(shown.map(\.id)) }
                    .help("Select every item shown (Cmd-A)")
            }
        }
        if current.showsItems {
            itemActions
        }
    }

    /// What can be done to the selected photos and videos
    @ToolbarContentBuilder private var itemActions: some ToolbarContent {
        ToolbarItemGroup {
            let favorite = !selected.isEmpty && selected.allSatisfy(\.favorite)
            Button("Favorite", systemImage: favorite ? "heart.fill" : "heart") {
                actions.setFavorite(selected, !favorite)
            }
            .disabled(selected.isEmpty)
            Button("Change Date", systemImage: "calendar") { actions.changeDate(selected) }
                .disabled(selected.isEmpty)
            Button("Open in Photos", systemImage: "arrow.up.forward.app") { selected.first.map(actions.open) }
                .disabled(selected.count != 1)
            Button("Delete", systemImage: "trash") { actions.delete(selected) }
                .disabled(selected.isEmpty)
                .keyboardShortcut(.delete, modifiers: .command)
            Button("Details", systemImage: "info.circle") { showInspector.toggle() }
        }
    }
}

extension View {
    /// The blue button only while it can be pressed: a disabled one drew its blue label on its blue fill
    @ViewBuilder
    func prominent(when enabled: Bool) -> some View {
        if enabled {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered).disabled(true)
        }
    }
}
