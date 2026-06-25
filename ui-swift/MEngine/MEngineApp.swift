import SwiftUI

@main
struct MEngineApp: App {
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 720)
        #endif

        #if os(macOS)
        // Presença na barra de menus: o mesmo painel conversacional (superfície expansível).
        MenuBarExtra("Assistente M-Engine", systemImage: "sparkle.magnifyingglass") {
            MenuBarAgentView()
        }
        .menuBarExtraStyle(.window)
        #endif
    }
}
