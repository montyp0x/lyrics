import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct LyricsApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    #endif
    @State private var engine = LyricsEngine()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(engine)
                .task { engine.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { engine.appDidBecomeActive() }
                }
        }
        #if os(macOS)
        .defaultSize(width: 420, height: 680)
        #endif
        #if os(macOS)
        MenuBarExtra(
            isInserted: Binding(get: { engine.menuBarEnabled }, set: { engine.menuBarEnabled = $0 })
        ) {
            MacMenuBarView()
                .environment(engine)
                .task { engine.start() }
        } label: {
            MacMenuBarLabel(
                snapshot: engine.snapshot,
                lyrics: engine.lyrics,
                currentIndex: engine.currentIndex
            )
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(engine)
                .frame(minWidth: 480, minHeight: 520)
        }
        #endif
    }
}

#if os(macOS)
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    /// The menu bar extra is the reason to keep running after the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
#endif
