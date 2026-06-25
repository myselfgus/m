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
        // Janela flutuante do assistente — movível, redimensionável, não ocupa o dashboard.
        Window("Assistente", id: "assistant") {
            AssistantChatScreen()
                .environmentObject(settings)
                .frame(minWidth: 360, minHeight: 420)
        }
        .defaultSize(width: 420, height: 600)
        .windowResizability(.contentMinSize)
        .keyboardShortcut("j", modifiers: .command)

        // Presença na barra de menus: abre a janela flutuante (não some ao tirar o mouse).
        MenuBarExtra("Assistente M-Engine", systemImage: "sparkles") {
            AssistantMenuBar()
        }
        .menuBarExtraStyle(.menu)
        #endif
    }
}
