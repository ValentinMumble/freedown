import SwiftUI

struct ShrinkRequest: Identifiable {
    let id = UUID()
    let items: [Item]
}

struct ShrinkSheet: View {
    let items: [Item]
    let onStart: ([Item], ShrinkPreset) -> Void
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var preset: ShrinkPreset
    @State private var minQuality: Double

    init(items: [Item], onStart: @escaping ([Item], ShrinkPreset) -> Void) {
        self.items = items
        self.onStart = onStart
        let last = ShrinkPreset.last
        _preset = State(initialValue: last)
        _minQuality = State(initialValue: last.minQuality)
    }

    var body: some View {
        let eligible = items.filter { library.shrinkSkip($0) == nil }
        let skipped = items.compactMap { item in library.shrinkSkip(item).map { "\(item.filename): \($0)" } }
        let minutes = eligible.reduce(0) { $0 + $1.duration } / 60
        VStack(alignment: .leading, spacing: 14) {
            Text(eligible.isEmpty ? "Nothing to shrink" : "Shrink \(Format.count(eligible.count, "video")) (\(Format.bytes(eligible.reduce(0) { $0 + $1.size })))")
                .font(.title2.weight(.semibold))
            Text(
                "Each video is downloaded from iCloud if needed, re-encoded to HEVC with ffmpeg, then scored for quality (VMAF, 100 = identical). The copy goes into Photos with the same date, place, favorite and albums, only when it is at least \(Shrinker.minSavingText) smaller and good enough. Count about 2 to 3 times the length of the videos: here roughly \(max(1, Int(minutes * 2.5))) minutes."
            )
            Text(
                "Nothing is deleted: the originals stay until you delete them from Shrinking. Until then the copies take extra iCloud space\(library.storage?.free.map { " (\(Format.bytes($0)) free now)" } ?? "")."
            )
            .foregroundStyle(.secondary)
            if eligible.contains(where: \.edited) {
                Text(
                    "Edited videos (rotated, trimmed…) are shrunk as they look now: the copy keeps the edit, which can no longer be undone. Photos stores an edited video twice, so deleting its original frees both."
                )
                .foregroundStyle(.secondary)
            }
            if FFmpeg.ffmpeg == nil {
                Label("Needs ffmpeg. Install it with brew install ffmpeg, then try again.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Picker("Quality", selection: $preset) {
                ForEach(ShrinkPreset.allCases) { option in
                    Text("\(option.label): \(option.detail)").tag(option)
                }
            }
            .pickerStyle(.radioGroup)
            .onChange(of: preset) { minQuality = preset.minQuality }
            VStack(alignment: .leading, spacing: 4) {
                Stepper(value: $minQuality, in: 70...99, step: 1) {
                    Text("Keep a copy only if it scores at least \(Int(minQuality))")
                }
                Text(
                    "Out of 100. Around 93 the copy is hard to tell apart, around 88 slightly softer. Copies below it wait in Shrinking, where you can compare them and save them anyway. Remembered for \(preset.label)\(minQuality == preset.defaultMinQuality ? "" : " (default \(Int(preset.defaultMinQuality)))")."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if !skipped.isEmpty {
                Text("Left out: " + skipped.joined(separator: "; ")).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start") {
                    // Saved first: each job reads it when queued
                    preset.minQuality = minQuality
                    ShrinkPreset.last = preset
                    onStart(eligible, preset)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(eligible.isEmpty || FFmpeg.ffmpeg == nil)
            }
        }
        .padding(20)
        .frame(width: 540)
    }
}
