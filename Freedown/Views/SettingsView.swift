import SwiftUI

/// Freedown › Settings: what the app opens on and shows, what it looks for, and what it keeps on this Mac.
/// A change that needs a new scan starts it a second after the last change.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("This Mac", systemImage: "internaldrive") { MacSettings() }
            Tab("Photos & iCloud", systemImage: "photo.on.rectangle") { PhotosSettings() }
            Tab("Saved Data", systemImage: "archivebox") { DataSettings() }
        }
        .frame(width: 560, height: 560)
    }
}

// MARK: General

private struct GeneralSettings: View {
    @AppStorage(Settings.Key.startDestination.rawValue) private var start = Destination.cleanup.rawValue
    @AppStorage(Settings.Key.blurPhotos.rawValue) private var blurPhotos = false
    @AppStorage(Settings.Key.notifications.rawValue) private var notifications = true

    var body: some View {
        Form {
            Section {
                Picker("Open on", selection: $start) {
                    Text("The page used last").tag(Settings.lastPage)
                    Divider()
                    ForEach(Destination.allCases) { Text($0.label).tag($0.rawValue) }
                }
            }
            Section {
                Toggle("Blur photos and videos", isOn: $blurPhotos)
            } footer: {
                Footer("For sharing your screen: the grid and the details panel show a blur instead of the picture.")
            }
            Section {
                Toggle("Notify when long work ends", isOn: $notifications)
            } footer: {
                Footer("Shrinking, conversions and splits say when they end while you are in another app.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: This Mac

private struct MacSettings: View {
    @Environment(Library.self) private var library
    @AppStorage(Settings.Key.unusedAppDays.rawValue) private var unusedDays = Cleanup.defaultUnusedDays
    @AppStorage(Settings.Key.largeFileMegabytes.rawValue) private var largeFileMegabytes = Cleanup.defaultLargeFileMegabytes

    var body: some View {
        Form {
            Section {
                NumberSetting(title: "Apps count as unused after", value: $unusedDays, range: 7...730, step: 15, unit: "days")
                    .onChange(of: unusedDays) { library.rework(.cleanup) }
                LabeledContent("Apps to keep") {
                    if library.keptApps.isEmpty { Text("None").foregroundStyle(.secondary) }
                }
                ForEach(library.keptApps, id: \.self) { bundle in
                    RemovableRow(text: Self.appName(bundle), help: bundle) { library.unkeepApp(bundle) }
                }
            } header: {
                Text("Clean Up")
            } footer: {
                Footer("60 days at first. Right-click an app in Clean Up to keep it: it is never offered again. Remove it here to see it again.")
            }
            Section {
                NumberSetting(title: "Smallest large file", value: $largeFileMegabytes, range: 50...102_400, step: 100, unit: "MB")
                LabeledContent("Skipped") {
                    Button("Add…") { addSkipped() }
                }
                ForEach(library.skippedPaths, id: \.self) { path in
                    RemovableRow(text: Self.short(path), help: path) { library.unskip(path) }
                }
            } header: {
                Text("Large Files")
            } footer: {
                Footer(
                    "500 MB at first. A bigger size applies at once, a smaller one needs Look Again. Skipped files and folders are left out of searches: right-click a file in Large Files to skip it or its folder. A file no longer skipped shows after Look Again."
                )
            }
        }
        .formStyle(.grouped)
    }

    private func addSkipped() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = "Skip"
        if panel.runModal() == .OK {
            for url in panel.urls { library.skip(url.path) }
        }
    }

    private static func appName(_ bundle: String) -> String {
        guard let path = LaunchServices.path(bundle) else { return bundle }
        return FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
    }

    private static func short(_ path: String) -> String {
        path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }
}

// MARK: Photos & iCloud

private struct PhotosSettings: View {
    @Environment(Library.self) private var library
    @AppStorage(Settings.Key.similarSeconds.rawValue) private var similarSeconds = Int(Similar.defaultGap)
    @AppStorage(Settings.Key.similarBits.rawValue) private var similarBits = Similar.defaultMaxDistance
    @AppStorage(Settings.Key.accidentalScore.rawValue) private var accidentalScore = Double(Accidental.defaultMaxScore)
    @AppStorage(Settings.Key.minSavingPercent.rawValue) private var minSaving = Shrinker.defaultMinSavingPercent
    @AppStorage(Settings.Key.shrinkPreset.rawValue) private var preset = ShrinkPreset.high
    @AppStorage(Settings.minQualityKey(.high)) private var highQuality = ShrinkPreset.high.defaultMinQuality
    @AppStorage(Settings.minQualityKey(.small)) private var smallQuality = ShrinkPreset.small.defaultMinQuality
    @AppStorage(Settings.Key.driveMegabytes.rawValue) private var driveMegabytes = 1

    var body: some View {
        Form {
            Section {
                NumberSetting(title: "Taken within", value: $similarSeconds, range: 5...600, step: 15, unit: "seconds")
                Slider(
                    value: Binding(get: { Double(similarBits) }, set: { similarBits = Int($0.rounded()) }), in: 8...24, step: 2
                ) {
                    Text("Look alike")
                } minimumValueLabel: {
                    Text("Closely")
                } maximumValueLabel: {
                    Text("Loosely")
                }
            } header: {
                Text("Duplicates & Similar")
            } footer: {
                Footer(
                    "A minute and the middle at first. A longer time looks at more photos, which takes a while the first time. The groups update a second after a change."
                )
            }
            .onChange(of: similarSeconds) { library.rework(.analysis) }
            .onChange(of: similarBits) { library.rework(.analysis) }
            Section {
                Slider(value: $accidentalScore, in: -0.8 ... -0.3, step: 0.05) {
                    Text("Suggest")
                } minimumValueLabel: {
                    Text("Fewer")
                } maximumValueLabel: {
                    Text("More")
                }
                .onChange(of: accidentalScore) { library.rework(.analysis) }
            } header: {
                Text("Probably Accidental")
            } footer: {
                Footer(
                    "How low Vision's score must be for a photo with nobody in it, from \(String(format: "%.2f", Accidental.defaultMaxScore)) at first (now \(String(format: "%.2f", accidentalScore))). More catches more mistakes, and more photos worth keeping."
                )
            }
            Section {
                NumberSetting(title: "Smallest saving", value: $minSaving, range: 5...60, step: 5, unit: "%")
                Picker("Shrink preset", selection: $preset) {
                    ForEach(ShrinkPreset.allCases) { Text($0.label).tag($0) }
                }
                Stepper(value: $highQuality, in: 70...99, step: 1) {
                    LabeledContent("\(ShrinkPreset.high.label): quality bar", value: "\(Int(highQuality))")
                }
                Stepper(value: $smallQuality, in: 70...99, step: 1) {
                    LabeledContent("\(ShrinkPreset.small.label): quality bar", value: "\(Int(smallQuality))")
                }
            } header: {
                Text("Shrinking and HEIC")
            } footer: {
                Footer(
                    "20%, High quality, 93 and 88 at first. A shrunk video that saves less waits in Shrinking for a look; a HEIC copy that saves less is refused. The Shrink window opens on this preset and these bars, and changing them there changes them here."
                )
            }
            Section {
                NumberSetting(title: "Smallest file listed", value: $driveMegabytes, range: 1...1_000, step: 5, unit: "MB")
                    .onChange(of: driveMegabytes) { library.rework(.drive) }
            } header: {
                Text("iCloud Drive")
            } footer: {
                Footer("1 MB at first.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Saved data

private struct DataSettings: View {
    @Environment(Library.self) private var library
    @State private var size: Int64?
    @State private var forgetting = false
    @State private var clearing = false

    var body: some View {
        Form {
            Section {
                LabeledContent("On this Mac", value: size.map(Format.bytes) ?? "Measuring…")
                LabeledContent("Folder") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Settings.supportFolder]) }
                }
            } footer: {
                Footer(
                    "File sizes read from Photos, the analyses, the large-file search, shrink records and the saved-space history, plus refused copies waiting to be compared."
                )
            }
            Section {
                LabeledContent {
                    Button("Forget…") { forgetting = true }
                } label: {
                    Text("Analyses")
                    Text("Picture hashes and what Vision found, by photo")
                }
                LabeledContent {
                    Button("Clear…") { clearing = true }.disabled(library.savings.isEmpty)
                } label: {
                    Text("Saved-space history")
                    let count = library.savings.count
                    Text("\(count.formatted()) \(count == 1 ? "entry" : "entries"), \(Format.bytes(library.savings.reduce(0) { $0 + $1.bytes })) in all")
                }
            }
        }
        .formStyle(.grouped)
        .task { await measure() }
        .confirmationDialog("Forget the analyses?", isPresented: $forgetting) {
            Button("Forget Analyses", role: .destructive) {
                library.analysis.forget()
                Task { await measure() }
            }
        } message: {
            Text(
                "Duplicates & Similar, No People or Pets, Probably Accidental and Half-Frame Scans look at every photo again the next time each opens, which can take several minutes."
            )
        }
        .confirmationDialog("Clear the saved-space history?", isPresented: $clearing) {
            Button("Clear History", role: .destructive) {
                library.clearSavings()
                Task { await measure() }
            }
        } message: {
            Text("The saved totals in the sidebar start again from zero. Nothing in Photos or on the disk changes.")
        }
    }

    private func measure() async {
        size = await Task.detached(priority: .utility) { Settings.storedSize() }.value
    }
}

// MARK: Pieces

/// A whole number typed or stepped, kept within its range whatever is typed
private struct NumberSetting: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let unit: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, value: clamped, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                Text(unit).foregroundStyle(.secondary)
                Stepper(title, value: clamped, in: range, step: step).labelsHidden()
            }
        }
    }

    private var clamped: Binding<Int> {
        Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) })
    }
}

/// A line of a list kept in Settings, with a button that takes it out
private struct RemovableRow: View {
    let text: String
    let help: String
    let remove: () -> Void

    var body: some View {
        HStack {
            Text(text).help(help)
            Spacer()
            Button("Remove", systemImage: "minus.circle", action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Remove")
        }
    }
}

private struct Footer: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }
}
