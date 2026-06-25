import SwiftUI

/// Ícone expansível do assistente — colapsado é um "orb" flutuante; ao tocar, MORFA
/// fluidamente no painel conversacional que flutua sobre a tela (estilo menubar
/// conversacional). É o produto que substitui o chat lateral no dashboard.
///
/// Uso (aditivo, sem tocar no resto do dashboard):
/// ```swift
/// SomeDashboardView()
///     .overlay(alignment: .bottomTrailing) { AssistantOrb() }
/// ```
///
/// Liquid Glass (skill swiftui-liquid-glass):
///  • `GlassEffectContainer` envolve orb e painel para que a superfície de vidro
///    compartilhe amostragem e refrate junto durante o morph.
///  • `glassEffectID("assistant-surface")` é idêntico nos dois estados → o sistema
///    interpola círculo↔retângulo (o painel "nasce" do ícone).
///  • `.interactive()` só no orb (clicável).
///  • Tudo atrás de `#available(macOS 26, *)` com fallback de material.
///
/// Performance (skill swiftui-performance):
///  • Estado mínimo (`expanded`); a sessão WebSocket vive dentro do painel.
///  • Animação escopada via `withAnimation` na troca de estado, não na raiz.
struct AssistantOrb: View {
    /// Contexto opcional de paciente para a conversa.
    var contextSlug: String? = nil
    /// Tamanho do orb colapsado.
    var orbSize: CGFloat = 56
    /// Margem em relação ao canto.
    var inset: CGFloat = 20

    @State private var expanded = false
    @Namespace private var glassNS

    private let surfaceID = "assistant-surface"
    private let panelWidth: CGFloat = 360
    private let panelMaxHeight: CGFloat = 540

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Captura toques fora do painel para recolher (invisível, sem escurecer:
            // sensação de painel flutuante, não de modal).
            if expanded {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { collapse() }
                    .transition(.opacity)
            }
            morphingSurface
                .padding(inset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Superfície que morfa (orb ↔ painel)

    @ViewBuilder
    private var morphingSurface: some View {
        if #available(macOS 26, iOS 26, *) {
            GlassEffectContainer(spacing: 20) {
                stateContent
            }
        } else {
            stateContent
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        if expanded {
            panel
        } else {
            orb
        }
    }

    // MARK: - Estado colapsado (orb)

    private var orb: some View {
        Button(action: expand) {
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(HOS.blue)
                .frame(width: orbSize, height: orbSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .assistantGlass(morph: surfaceID, in: glassNS, shape: Circle(),
                        interactive: true, tint: HOS.blue.opacity(0.10))
        .floatingShadow()
        .help("Abrir assistente")
        .accessibilityLabel("Abrir assistente")
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    // MARK: - Estado expandido (painel flutuante)

    private var panel: some View {
        FloatingAssistantPanel(contextSlug: contextSlug, onCollapse: collapse)
            .frame(width: panelWidth)
            .frame(maxHeight: panelMaxHeight)
            .assistantGlass(morph: surfaceID, in: glassNS,
                            shape: RoundedRectangle(cornerRadius: HOS.rXl, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: HOS.rXl, style: .continuous))
            .floatingShadow()
            .transition(.opacity)
    }

    // MARK: - Ações

    private func expand() {
        withAnimation(.smooth(duration: 0.42)) { expanded = true }
    }

    private func collapse() {
        withAnimation(.smooth(duration: 0.38)) { expanded = false }
    }
}

#if DEBUG
#Preview("Orb sobre dashboard") {
    ZStack {
        BlueWash()
        Text("Dashboard").foregroundStyle(.secondary)
    }
    .frame(width: 900, height: 640)
    .overlay(alignment: .bottomTrailing) {
        AssistantOrb()
            .environmentObject(AppSettings())
    }
}
#endif
