import UIKit

/// Debug-only log written to the app container so it can be pulled with
/// `devicectl device copy from --domain-type appDataContainer`. Rotates to `diagnostics.old.log` at 2 MB.
@MainActor
enum DiagnosticsLog {
    private static let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
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
        let state = switch UIApplication.shared.applicationState {
        case .active: "FG"
        case .inactive: "IN"
        case .background: "BG"
        @unknown default: "??"
        }
        let time = Date.now.formatted(
            .dateTime.month(.twoDigits).day(.twoDigits).hour().minute().second().secondFraction(.fractional(2))
        )
        let data = Data("[\(time) \(state)] \(message())\n".utf8)
        guard let handle = openHandle() else { return }
        handle.write(data)
        size += UInt64(data.count)
        if size > maxSize { rotate() }
        #endif
    }
}
