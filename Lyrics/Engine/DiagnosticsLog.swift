import os
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Debug-only log written to the app container so it can be pulled with
/// `devicectl device copy from --domain-type appDataContainer`. Rotates to `diagnostics.old.log` at 2 MB.
@MainActor
enum DiagnosticsLog {
    #if os(macOS)
    /// Inside the sandbox this is the app container, not the user's Documents folder.
    private static let directory: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    #else
    private static let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    #endif
    private static let url = directory.appendingPathComponent("diagnostics.log")
    private static let oldURL = directory.appendingPathComponent("diagnostics.old.log")
    private static let maxSize: UInt64 = 2_000_000

    /// Reopened lazily: iOS relaunches the app at boot, before the first unlock makes Documents readable.
    private static var handle: FileHandle?
    private static var size: UInt64 = 0

    private static func openHandle() -> FileHandle? {
        if let handle { return handle }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        size = (try? handle?.seekToEnd()) ?? 0
        return handle
    }

    private static func rotate() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: oldURL)
        try? FileManager.default.moveItem(at: url, to: oldURL)
    }

    static func write(_ message: @autoclosure () -> String) {
        #if DEBUG
        #if os(iOS)
        let state = switch UIApplication.shared.applicationState {
        case .active: "FG"
        case .inactive: "IN"
        case .background: "BG"
        @unknown default: "??"
        }
        #else
        let state = NSApplication.shared.isActive ? "FG" : "BG"
        #endif
        let time = Date.now.formatted(
            .dateTime.month(.twoDigits).day(.twoDigits).hour().minute().second().secondFraction(.fractional(2))
        )
        let line = "[\(time) \(state)] \(message())"
        #if os(macOS)
        Logger(subsystem: "com.ramych.lyrics.mac", category: "diagnostics").notice("\(line, privacy: .public)")
        #endif
        let data = Data("\(line)\n".utf8)
        guard let handle = openHandle() else { return }
        handle.write(data)
        size += UInt64(data.count)
        if size > maxSize { rotate() }
        #endif
    }
}
