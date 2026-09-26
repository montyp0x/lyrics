import UIKit

/// Debug-only log written to the app container so it can be pulled with
/// `devicectl device copy from --domain-type appDataContainer`.
@MainActor
enum DiagnosticsLog {
    private static let url = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("diagnostics.log")
    /// Reopened lazily: iOS relaunches the app at boot, before the first unlock makes Documents readable.
    private static var handle: FileHandle?

    private static func openHandle() -> FileHandle? {
        if let handle { return handle }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }

    static func write(_ message: @autoclosure () -> String) {
        #if DEBUG
        let state = switch UIApplication.shared.applicationState {
        case .active: "FG"
        case .inactive: "IN"
        case .background: "BG"
        @unknown default: "??"
        }
        let time = Date.now.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(2)))
        openHandle()?.write(Data("[\(time) \(state)] \(message())\n".utf8))
        #endif
    }
}
