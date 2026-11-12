import SwiftUI

/// The biggest files in iCloud Drive and in apps' iCloud folders, to delete or show in Finder.
struct FilesView: View {
    @Environment(Library.self) private var library
    @State private var selection: Set<DriveFile.ID> = []
    @State private var sortOrder = [KeyPathComparator(\DriveFile.size, order: .reverse)]
    @State private var confirming: [DriveFile]?
    @State private var failed: [String] = []

    var body: some View {
        let files = (library.driveFiles ?? []).sorted(using: sortOrder)
        let chosen = files.filter { selection.contains($0.id) }
        let deletable = chosen.filter { $0.keptBy == nil }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(
                    "\(Format.count(files.count, "file")) of \(Format.bytes(ICloudDrive.minimum)) or more, \(Format.bytes(files.reduce(0) { $0 + $1.size })) in all"
                )
                .foregroundStyle(.secondary)
                Spacer()
                Button("Show in Finder", systemImage: "folder") { reveal(chosen) }
                    .disabled(chosen.isEmpty)
                Button("Move \(deletable.isEmpty ? "" : "\(deletable.count) ")to Trash…", systemImage: "trash") { confirming = deletable }
                    .prominent(when: !deletable.isEmpty)
                    .help(
                        chosen.contains { $0.keptBy != nil }
                            ? "Files an app keeps for itself are deleted from that app" : "Move the selected files to the Trash")
            }
            .padding(.horizontal, 16)
            if !failed.isEmpty {
                Text("Not moved: \(failed.prefix(5).joined(separator: ", "))\(failed.count > 5 ? "…" : "")")
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
            }
            if library.driveFiles == nil {
                ProgressView("Reading iCloud Drive…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(files, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.name) { file in
                        Label(file.name, systemImage: file.downloaded ? "doc" : "icloud")
                            .help(file.downloaded ? "On this Mac and in iCloud" : "Only in iCloud")
                            .foregroundStyle(file.keptBy == nil ? .primary : .secondary)
                    }
                    TableColumn("Where", value: \.place) { file in
                        Text(file.keptBy.map { "\($0) (kept by the app)" } ?? file.place)
                            .foregroundStyle(.secondary)
                            .help(file.keptBy.map { "\($0) keeps this file for itself: delete it from \($0)" } ?? file.place)
                    }
                    TableColumn("Size", value: \.size) { file in Text(Format.bytes(file.size)).monospacedDigit() }
                        .width(min: 70, ideal: 80, max: 100)
                    TableColumn("Modified", value: \.modified) { file in Text(Format.date(file.modified)).foregroundStyle(.secondary) }
                        .width(min: 120, ideal: 150)
                }
                .contextMenu(forSelectionType: DriveFile.ID.self) { ids in
                    let targets = files.filter { ids.contains($0.id) }
                    Button("Show in Finder") { reveal(targets) }
                    Button("Move to Trash…") { confirming = targets.filter { $0.keptBy == nil } }
                        .disabled(!targets.contains { $0.keptBy == nil })
                } primaryAction: { ids in
                    // Double-click opens it, downloading it first when only iCloud has it
                    for file in files where ids.contains(file.id) { NSWorkspace.shared.open(file.url) }
                }
            }
        }
        .task { await library.scanDrive() }
        .confirmationDialog(
            "Move \(Format.count(confirming?.count ?? 0, "file")) (\(Format.bytes(confirming?.reduce(0) { $0 + $1.size } ?? 0))) to the Trash?",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
        ) {
            Button("Move to Trash", role: .destructive) {
                guard let targets = confirming else { return }
                Task {
                    failed = await library.trash(targets)
                    selection.subtract(targets.map(\.id))
                }
            }
        } message: {
            Text(
                "They leave iCloud Drive on all your devices and go to this Mac's Trash. iCloud.com keeps them in Recently Deleted for 30 days, where you can get them back, and Apple says they no longer count toward your iCloud storage."
            )
        }
    }

    private func reveal(_ files: [DriveFile]) {
        NSWorkspace.shared.activateFileViewerSelecting(files.map(\.url))
    }
}
