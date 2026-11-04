import Foundation

/// Asks Finder to do what macOS keeps other apps from doing: trash a file kept for the app that made it, an
/// app installed by an administrator, or empty the Trash. The first time, macOS asks whether Freedown may
/// control Finder.
enum Finder {
    /// Moves a file to the Trash, as dragging it there would. Returns why it did not, or nil once it is gone.
    nonisolated static func trash(_ file: URL) -> String? {
        // The path goes in as an argument, so no character in it can break the script
        if let problem = run("tell application \"Finder\" to delete (POSIX file (item 1 of argv) as alias)", file.path) {
            return problem
        }
        return FileManager.default.fileExists(atPath: file.path) ? "Finder could not move it to the Trash" : nil
    }

    /// Deletes what the Trash holds, for good. Returns why it did not, or nil.
    nonisolated static func emptyTrash() -> String? {
        run("tell application \"Finder\" to empty trash")
    }

    private static func run(_ line: String, _ arguments: String...) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = ["-e", "on run argv", "-e", line, "-e", "end run"] + arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return error.localizedDescription
        }
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        if process.terminationStatus == 0 { return nil }
        // -1743: the user said no when macOS asked
        if message.contains("-1743") {
            return "Freedown may not control Finder: allow it in System Settings › Privacy & Security › Automation"
        }
        return message.isEmpty ? "Finder refused" : message.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
