import SwiftUI

@main
struct FreedownApp: App {
    /// The unit tests run inside the app: it then leaves the library alone
    static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    @State private var library: Library
    @State private var shrinker: Shrinker
    @AppStorage(Settings.Key.thumbnailSize.rawValue) private var thumbnailSize = GridView.defaultCardWidth

    init() {
        let library = Library()
        _library = State(initialValue: library)
        _shrinker = State(initialValue: Shrinker(library: library))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .environment(shrinker)
        }
        // A fixed minimum size here fights the split view's own column sizes and loops the layout
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Reload Library") { Task { await library.reload() } }
                    .keyboardShortcut("r")
                Divider()
                Button("Bigger Thumbnails") { thumbnailSize = min(GridView.cardWidths.upperBound, thumbnailSize + 50) }
                    .keyboardShortcut("+")
                Button("Smaller Thumbnails") { thumbnailSize = max(GridView.cardWidths.lowerBound, thumbnailSize - 50) }
                    .keyboardShortcut("-")
            }
        }
        // The app's own Settings enum holds the keys, so SwiftUI's scene is named in full
        SwiftUI.Settings {
            SettingsView()
                .environment(library)
        }
    }
}
