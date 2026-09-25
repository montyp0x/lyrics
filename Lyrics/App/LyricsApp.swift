import SwiftUI

@main
struct LyricsApp: App {
    @State private var engine = LyricsEngine()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(engine)
                .task { engine.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { engine.appDidBecomeActive() }
                }
        }
    }
}
