import SwiftUI

#if os(macOS)
/// Presença do assistente na barra de menus do macOS.
///
/// O mesmo painel conversacional (FloatingAssistantPanel) hospedado num `MenuBarExtra`
/// de estilo `.window` — que já se apresenta como um painel flutuante ancorado ao ícone
/// da menubar, com material do sistema (Liquid Glass no macOS 26). É a forma nativa do
/// "menubar conversacional flutuando sobre a tela".
///
/// Integração aditiva (no `@main App`, sem alterar a janela principal):
/// ```swift
/// var body: some Scene {
///     WindowGroup { ContentView().environmentObject(settings) }
///     MenuBarAssistantScene(settings: settings)   // ← acrescente esta linha
/// }
/// ```
struct MenuBarAssistantScene: Scene {
    @ObservedObject var settings: AppSettings

    var body: some Scene {
        MenuBarExtra {
            FloatingAssistantPanel()
                .environmentObject(settings)
                .frame(width: 360, height: 520)
        } label: {
            // Ícone curto e legível (regra de menubar da skill swiftui-patterns).
            Image(systemName: "sparkles")
                .accessibilityLabel("Assistente M-Engine")
        }
        .menuBarExtraStyle(.window)
    }
}
#endif
