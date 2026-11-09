import SwiftUI

/// Half-frame scans: each one with the cut marked, the two photos it will make, a slider to move the cut and
/// buttons to turn each half.
struct HalfFrameView: View {
    @Environment(Library.self) private var library
    /// The cut and turns changed by hand, by scan
    @State private var edits: [String: HalfFrameScan] = [:]
    /// Scans left out of the next split
    @State private var skipped: Set<String> = []
    /// Shows the scan-shaped photos where no strip was found too, cut in the middle
    @State private var showAll = false
    @State private var confirming = false
    @State private var message: String?
    @State private var done = 0
    @State private var outcome: Library.SplitOutcome?

    private static let scanHeight: CGFloat = 220

    private var scans: [HalfFrameScan] {
        let found = library.analysis.halfFrames ?? [:]
        return library.items.compactMap { item -> HalfFrameScan? in
            if let edited = edits[item.id] { return edited }
            if let gap = found[item.id] { return HalfFrameScan(item: item, gap: gap) }
            guard showAll, library.analysis.halfFrames != nil, HalfFrame.isCandidate(item) else { return nil }
            return HalfFrameScan(item: item, gap: HalfFrame.defaultGap, found: false)
        }
        .sorted { ($0.item.filename, $0.item.date) < ($1.item.filename, $1.item.date) }
    }

    var body: some View {
        let scans = scans
        let chosen = scans.filter { !skipped.contains($0.id) && ($0.found || edits[$0.id] != nil) }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Also show 3:2 photos where no strip was found", isOn: $showAll)
                Spacer()
                if let message, outcome == nil {
                    ProgressView(value: Double(done), total: Double(max(chosen.count, 1))) { Text(message) }.frame(width: 260)
                }
                Button("Split \(chosen.isEmpty ? "" : "\(Format.count(chosen.count, "Scan")) ")…") { confirming = true }
                    .prominent(when: !chosen.isEmpty && message == nil)
            }
            .padding(.horizontal, 16)
            if let outcome {
                Text(summary(outcome)).padding(.horizontal, 16)
            }
            if library.analysis.halfFrames == nil {
                ProgressView(value: library.analysis.halfFrameProgress) { Text("Looking for half-frame scans…") }
                    .padding(40)
                    .task { await library.findHalfFrames() }
            } else if scans.isEmpty {
                ContentUnavailableView(
                    "No half-frame scan", systemImage: "rectangle.split.2x1",
                    description: Text("Scans with two shots side by side show here once they are in Photos."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(scans) { row($0) }
                    }
                    .padding(16)
                }
            }
        }
        .confirmationDialog(
            "Split \(Format.count(chosen.count, "scan")) into \(chosen.count * 2) photos?", isPresented: $confirming
        ) {
            Button("Split") { split(chosen) }
        } message: {
            Text(
                "Each half becomes a photo with the scan's date, place, favorite and albums. The scans go to Recently Deleted for 30 days. macOS asks you to confirm each batch of up to 200."
            )
        }
    }

    // MARK: A scan

    private func row(_ scan: HalfFrameScan) -> some View {
        let aspect = CGFloat(scan.item.width) / CGFloat(max(scan.item.height, 1))
        let width = Self.scanHeight * aspect
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle(
                    isOn: Binding(
                        get: { !skipped.contains(scan.id) && (scan.found || edits[scan.id] != nil) },
                        set: { include in
                            if include {
                                skipped.remove(scan.id)
                                if edits[scan.id] == nil { edits[scan.id] = scan }
                            } else {
                                skipped.insert(scan.id)
                            }
                        })
                ) {
                    Text(scan.item.filename).fontWeight(.medium)
                }
                Text(scan.found ? "strip found" : "no strip found, cut in the middle").foregroundStyle(.secondary).font(.callout)
                Spacer()
                Text(Format.date(scan.item.date)).foregroundStyle(.secondary).font(.callout)
            }
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 6) {
                    // The scan with the strip that goes marked
                    Thumbnail(asset: scan.item.asset, pixels: 900, fit: true)
                        .frame(width: width, height: Self.scanHeight)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(.red.opacity(0.45))
                                .frame(width: max(2, width * (scan.gap.upperBound - scan.gap.lowerBound)))
                                .offset(x: width * scan.gap.lowerBound)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    Slider(value: cut(scan), in: HalfFrame.window) { Text("Cut") }
                        .frame(width: width)
                        .help("Move the cut to the strip between the two shots")
                }
                half(scan, 0, width: width)
                half(scan, 1, width: width)
            }
        }
    }

    /// One of the two photos, as it will be: cut out of the scan and turned
    private func half(_ scan: HalfFrameScan, _ index: Int, width: CGFloat) -> some View {
        let range = index == 0 ? 0...scan.gap.lowerBound : scan.gap.upperBound...1
        let halfWidth = width * (range.upperBound - range.lowerBound)
        let turned = scan.turns[index] % 2 != 0
        let side = max(halfWidth, Self.scanHeight)
        return VStack(spacing: 6) {
            Thumbnail(asset: scan.item.asset, pixels: 900, fit: true)
                .frame(width: width, height: Self.scanHeight)
                .offset(x: -width * range.lowerBound)
                .frame(width: halfWidth, height: Self.scanHeight, alignment: .leading)
                .clipped()
                .rotationEffect(.degrees(Double(90 * scan.turns[index])))
                // A turned half takes the other side's room
                .frame(width: turned ? Self.scanHeight : halfWidth, height: turned ? halfWidth : Self.scanHeight)
                .frame(width: side, height: side)
            HStack {
                Button("Turn Left", systemImage: "rotate.left") { turn(scan, index, by: -1) }
                Button("Turn Right", systemImage: "rotate.right") { turn(scan, index, by: 1) }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
    }

    /// The middle of the strip, moved by the slider; the strip keeps its width
    private func cut(_ scan: HalfFrameScan) -> Binding<Double> {
        Binding(
            get: { (scan.gap.lowerBound + scan.gap.upperBound) / 2 },
            set: { middle in
                let halfWidth = (scan.gap.upperBound - scan.gap.lowerBound) / 2
                var edited = scan
                edited.gap = (middle - halfWidth)...(middle + halfWidth)
                edits[scan.id] = edited
            })
    }

    private func turn(_ scan: HalfFrameScan, _ index: Int, by step: Int) {
        var edited = scan
        edited.turns[index] = (edited.turns[index] + step + 4) % 4
        edits[scan.id] = edited
    }

    // MARK: Split

    private func split(_ chosen: [HalfFrameScan]) {
        message = "Starting…"
        outcome = nil
        Notifier.ask()
        Task {
            let result = await library.splitHalfFrames(chosen) { text, count in
                message = text
                done = count
            }
            outcome = result
            message = nil
            edits = [:]
            Notifier.post("Half-frame scans split", summary(result))
        }
    }

    private func summary(_ outcome: Library.SplitOutcome) -> String {
        var parts = ["\(Format.count(outcome.split, "scan")) split into \(outcome.split * 2) photos."]
        if outcome.cancelled { parts.append("You refused a batch, so it and the ones after it were left as they were.") }
        if !outcome.failed.isEmpty {
            parts.append("Left out: \(outcome.failed.prefix(5).joined(separator: ", "))\(outcome.failed.count > 5 ? "…" : "").")
        }
        return parts.joined(separator: " ")
    }
}
