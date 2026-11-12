import SwiftUI

/// The shrink jobs of this session, every result so far, and the originals that can now go.
struct ShrinkView: View {
    @Environment(Library.self) private var library
    @Environment(Shrinker.self) private var shrinker
    @Binding var selection: Set<String>
    let actions: Actions
    @State private var comparing: ShrinkRecord?
    /// Refused copies ticked to be saved anyway, by original
    @State private var accepted: Set<String> = []
    @State private var saving: String?
    @State private var saveFailures: [String] = []

    var body: some View {
        let records = library.shrinkRecords.values.sorted { $0.date > $1.date }
        let shrunk = records.filter { $0.copy != nil }
        // Originals whose copy is in Photos and which are still there
        let originals = shrunk.compactMap { library.itemsById[$0.original] }
        let saved = shrunk.reduce(0) { $0 + $1.before - $1.after }
        // Refused copies kept aside, best score first: the ones most likely to be fine
        let waiting = records.filter { ShrinkRecords.preview($0) != nil && library.itemsById[$0.original] != nil }
            .sorted { ($0.vmaf ?? 0) > ($1.vmaf ?? 0) }
        let waitingIds = Set(waiting.map(\.id))
        let rest = records.filter { !waitingIds.contains($0.id) }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(headline(shrunk: shrunk.count, saved: saved, notShrunk: records.count - shrunk.count))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !originals.isEmpty {
                        Button("Delete \(Format.count(originals.count, "Original")) (\(Format.bytes(originals.reduce(0) { $0 + $1.size })))…", role: .destructive) {
                            actions.delete(originals)
                        }
                    }
                }

                if !shrinker.jobs.isEmpty {
                    HStack {
                        Text("This session").font(.title3.weight(.semibold))
                        Spacer()
                        Button("Cancel Waiting") { shrinker.cancelWaiting() }
                            .disabled(!shrinker.jobs.contains { $0.phase == .queued })
                        Button("Clear Finished") { shrinker.clearFinished() }
                    }
                    ForEach(shrinker.jobs) { job in jobRow(job) }
                }

                if !waiting.isEmpty { refusedSection(waiting) }

                if !rest.isEmpty {
                    Text("Results").font(.title3.weight(.semibold)).padding(.top, 6)
                    ForEach(rest) { record in recordRow(record) }
                }
            }
            .padding(16)
        }
        .sheet(item: $comparing) { record in
            if let original = library.itemsById[record.original], let file = ShrinkRecords.preview(record) {
                CompareSheet(record: record, original: original, file: file)
            }
        }
    }

    private func refusedSection(_ waiting: [ShrinkRecord]) -> some View {
        let chosen = waiting.filter { accepted.contains($0.original) }
        let allChosen = chosen.count == waiting.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Refused copies").font(.title3.weight(.semibold))
                Spacer()
                Button(allChosen ? "Select None" : "Select All") {
                    accepted = allChosen ? [] : Set(waiting.map(\.original))
                }
                .disabled(saving != nil)
                Button(saving ?? "Save \(copies(chosen.count)) to Photos") { save(chosen) }
                    .prominent(when: !chosen.isEmpty && saving == nil)
            }
            .padding(.top, 6)
            Text(
                "These copies were refused, for a score below the quality bar, a saving under \(Shrinker.minSavingText) or a different number of frames, and wait here instead of going into Photos. Tick the ones you accept, or compare one first, then save them: each goes into Photos like any other copy, and its original can then be deleted above."
            )
            .foregroundStyle(.secondary)
            if !saveFailures.isEmpty {
                Text("Not saved: \(saveFailures.joined(separator: ", ")).").foregroundStyle(.red)
            }
            ForEach(waiting) { record in recordRow(record) }
        }
    }

    /// "1 Copy", "12 Copies", for a button title
    private func copies(_ count: Int) -> String {
        count == 1 ? "1 Copy" : "\(count.formatted()) Copies"
    }

    /// One at a time: each import is its own change in Photos, and a failure leaves the others saved
    private func save(_ chosen: [ShrinkRecord]) {
        saveFailures = []
        Task {
            for (index, record) in chosen.enumerated() {
                saving = "Saving \(index + 1) of \(chosen.count)…"
                do {
                    try await shrinker.saveAnyway(record)
                } catch {
                    saveFailures.append("\(record.name) (\(error.localizedDescription))")
                }
                accepted.remove(record.original)
            }
            saving = nil
        }
    }

    private func headline(shrunk: Int, saved: Int64, notShrunk: Int) -> String {
        var parts: [String] = []
        if shrunk > 0 {
            parts.append("\(Format.count(shrunk, "video")) shrunk, \(Format.bytes(saved)) saved once the originals are deleted")
        }
        if notShrunk > 0 {
            parts.append("\(Format.count(notShrunk, "video")) not shrunk, left as \(notShrunk == 1 ? "it was" : "they were")")
        }
        return parts.isEmpty ? "Nothing shrunk yet" : parts.joined(separator: ". ")
    }

    /// What happened, with the verdict first when no copy was saved
    private func outcome(_ record: ShrinkRecord, saved: String) -> String {
        record.kept.map { "Not shrunk, no copy saved: \($0). Tried \(record.sizes)." } ?? "\(record.summary). \(saved)"
    }

    private func jobRow(_ job: Shrinker.Job) -> some View {
        HStack(spacing: 12) {
            Thumbnail(asset: job.item.asset, pixels: 120)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 3) {
                Text("\(job.item.filename) · \(Format.bytes(job.item.size))").fontWeight(.medium)
                if job.phase == .encoding {
                    ProgressView(value: job.progress) { Text("Encoding, \(Int(job.progress * 100))%") }
                        .frame(maxWidth: 320)
                } else if job.phase == .downloading, let downloaded = job.downloaded, downloaded > 0, downloaded < 1 {
                    ProgressView(value: downloaded) { Text("Downloading from iCloud, \(Int(downloaded * 100))%") }
                        .frame(maxWidth: 320)
                } else if let error = job.error {
                    Text(error).foregroundStyle(.red).lineLimit(3)
                } else if let record = job.record {
                    Text(outcome(record, saved: "Copy saved to Photos"))
                        .foregroundStyle(record.copy == nil ? .secondary : .primary)
                } else if job.phase == .queued, let downloaded = job.downloaded {
                    Text(downloaded < 1 ? "Waiting, downloading from iCloud ahead of its turn, \(Int(downloaded * 100))%" : "Waiting, already downloaded")
                        .foregroundStyle(.secondary)
                } else {
                    Text(job.phase.label).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(8)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .modifier(Selectable(item: library.itemsById[job.item.id], selection: $selection, actions: actions))
    }

    private func recordRow(_ record: ShrinkRecord) -> some View {
        let original = library.itemsById[record.original]
        let copy = record.copy.flatMap { library.itemsById[$0] }
        let state = original == nil ? "Original deleted, space freed" : "Copy in Photos, original still here"
        let running = shrinker.jobs.contains { $0.phase.active && $0.item.id == record.original }
        let waiting = ShrinkRecords.preview(record) != nil && original != nil
        return HStack(spacing: 12) {
            if waiting {
                Toggle(
                    "Accept this copy",
                    isOn: Binding(
                        get: { accepted.contains(record.original) },
                        set: { isOn in
                            if isOn { accepted.insert(record.original) } else { accepted.remove(record.original) }
                        })
                )
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(saving != nil)
            }
            if let shown = original ?? copy {
                Thumbnail(asset: shown.asset, pixels: 120)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name).fontWeight(.medium)
                Text(outcome(record, saved: state)).font(.callout).foregroundStyle(.secondary)
                Text("\(record.from) → \(record.to)").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            if let copy { Button("Open Copy") { actions.open(copy) } }
            if record.reviewable, let original {
                if waiting {
                    Button("Compare…") { comparing = record }
                        .help("Switch between the original and the copy, then save the copy anyway if it looks fine")
                } else {
                    Button(running ? "Encoding…" : "Encode Again") {
                        shrinker.enqueue([original], preset: record.preset)
                    }
                    .disabled(running)
                    .help("The copy from the first try was not kept. Encodes it again and keeps it, so you can compare it with the original.")
                }
            }
        }
        .modifier(Selectable(item: original ?? copy, selection: $selection, actions: actions))
    }
}

/// Click shows the video in the right panel, where it plays and can be deleted or made a favorite; right-click
/// offers the same menu as in the grids
private struct Selectable: ViewModifier {
    let item: Item?
    @Binding var selection: Set<String>
    let actions: Actions

    func body(content: Content) -> some View {
        if let item {
            content
                .contentShape(Rectangle())
                .onTapGesture { selection = [item.id] }
                .overlay {
                    if selection.contains(item.id) {
                        RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
                .contextMenu { ItemMenu(items: [item], actions: actions) }
        } else {
            content
        }
    }
}
