import SwiftUI

struct ReplaceRequest: Identifiable {
    let id = UUID()
    let items: [Item]
    let kind: Replacement
    /// Marked one by one: every one of them is meant to change
    var handPicked = false
}

/// Remove Motion and Keep Edited Version: what will happen, the choices that matter, then the progress.
struct ReplaceSheet: View {
    let request: ReplaceRequest
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var keepFavorites: Bool
    @State private var message: String?
    @State private var done = 0
    @State private var outcome: Library.ReplaceOutcome?

    init(request: ReplaceRequest) {
        self.request = request
        // Marked one by one, or only favorites picked: they are meant to change
        _keepFavorites = State(initialValue: !request.handPicked && !request.items.allSatisfy(\.favorite))
    }

    private var kind: Replacement { request.kind }

    private var targets: [Item] {
        request.items.filter { item in
            kind.applies(to: item) && !(kind == .removeMotion && keepFavorites && item.favorite)
        }
    }

    var body: some View {
        let targets = targets
        let saving = kind.saving(of: targets)
        // What the toggle leaves out, said with it, so a short list is never a surprise
        let favorites = request.items.filter { kind.applies(to: $0) && $0.favorite }.count
        VStack(alignment: .leading, spacing: 14) {
            Text("\(kind.title): \(Format.count(targets.count, "item")), frees about \(Format.bytes(saving))")
                .font(.title2.weight(.semibold))
            if kind == .removeMotion {
                Text(
                    "Each Live Photo is replaced by its still, as it looks now (with its edit), with the same date, place, favorite and albums. The motion is gone for good once Recently Deleted is emptied."
                )
                if favorites > 0 {
                    Toggle("Leave the \(Format.count(favorites, "favorite")) as Live Photos", isOn: $keepFavorites)
                }
            } else if kind == .convertToHEIC {
                Text(
                    "Each photo is saved again as HEIC and checked against its JPEG: it takes the JPEG's place, with the same date, place, favorite and albums, only if it scores \(Int(Stills.minScore)) or more out of 100 (the same to the eye) and saves at least \(Shrinker.minSavingText). Photos with an HDR layer are left as they are. A refused photo stays a JPEG and is not offered again. The figure above is an estimate from what passed on this library, refusals included; the space freed is measured once converted."
                )
            } else {
                Text(
                    "Each item is replaced by its edited version alone, with the same date, place, favorite and albums. A Live Photo stays a Live Photo, with its edited motion. The edit can no longer be undone, and the original is gone for good once Recently Deleted is emptied."
                )
            }
            Text(
                "Names of people tagged in these items need tagging again. macOS asks you to confirm each batch of up to 200, and nothing changes in a batch you refuse. Deleted items stay in Recently Deleted for 30 days, where you can get them back."
            )
            .foregroundStyle(.secondary)

            if let outcome {
                Text(summary(outcome)).fontWeight(.medium)
            } else if let message {
                ProgressView(value: Double(done), total: Double(max(targets.count, 1))) {
                    Text("\(message) \(done) of \(targets.count)")
                }
            }

            HStack {
                Spacer()
                if outcome != nil {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(message != nil)
                    Button(kind.title) { start(targets) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(targets.isEmpty || message != nil)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .interactiveDismissDisabled(message != nil && outcome == nil)
    }

    private func start(_ targets: [Item]) {
        message = "Starting…"
        Notifier.ask()
        Task {
            let outcome = await library.replace(targets, kind: kind) { text, count in
                message = text
                done = count
            }
            self.outcome = outcome
            Notifier.post("\(kind.title) done", summary(outcome))
        }
    }

    private func summary(_ outcome: Library.ReplaceOutcome) -> String {
        var parts = ["\(Format.count(outcome.replaced, "item")) replaced, \(Format.bytes(outcome.freed)) freed, as measured in Photos."]
        if outcome.cancelled { parts.append("You refused a deletion, so that batch and the ones after it were left as they were.") }
        if !outcome.failed.isEmpty {
            parts.append("Left out: \(outcome.failed.prefix(5).joined(separator: ", "))\(outcome.failed.count > 5 ? "…" : "").")
        }
        if !outcome.warnings.isEmpty {
            parts.append("Check these in Photos: \(outcome.warnings.prefix(5).joined(separator: ", "))\(outcome.warnings.count > 5 ? "…" : "").")
        }
        return parts.joined(separator: " ")
    }
}
