import SwiftUI

// MARK: - Liquid Glass helpers (macOS 26 / iOS 26) com fallback de material
//
// Centraliza a aplicação do Liquid Glass para o ícone expansível do assistente.
// Regras seguidas (skill swiftui-liquid-glass):
//  • API nativa `glassEffect` em vez de blur custom.
//  • `glassEffectID(_:in:)` + `@Namespace` para MORFAR entre orb colapsado e painel.
//  • `.interactive()` só em elementos clicáveis (o orb).
//  • Sempre atrás de `#available(macOS 26, *)`, com fallback `.thickMaterial`.
//  • Sem tint decorativo — tint só onde a cor tem significado (estado/marca).
//
// O agrupamento num único `GlassEffectContainer` (ver AssistantOrb) é o que permite
// que as duas superfícies (orb ↔ painel) compartilhem amostragem e refratem juntas.

extension View {
    /// Aplica Liquid Glass com identidade de morph compartilhada. Quando o `id` é o
    /// mesmo entre dois estados da hierarquia (orb e painel), o sistema interpola a
    /// superfície de vidro entre eles dentro de um `GlassEffectContainer`.
    ///
    /// - Parameters:
    ///   - id: identidade estável compartilhada entre estados que devem morfar.
    ///   - ns: namespace local do container.
    ///   - shape: forma da superfície (círculo no orb, rounded-rect no painel).
    ///   - interactive: ative apenas em superfícies que respondem a toque/ponteiro.
    ///   - tint: cor semântica opcional (marca/estado); `nil` = vidro neutro.
    @ViewBuilder
    func assistantGlass<S: Shape>(
        morph id: String,
        in ns: Namespace.ID,
        shape: S,
        interactive: Bool = false,
        tint: Color? = nil,
        fallback: Material = .thickMaterial
    ) -> some View {
        if #available(macOS 26, iOS 26, *) {
            self
                .glassEffect(glassConfig(interactive: interactive, tint: tint), in: shape)
                .glassEffectID(id, in: ns)
        } else {
            self
                .background(fallback, in: shape)
                .overlay(shape.stroke(HOS.hairline, lineWidth: 0.75))
        }
    }

    /// Liquid Glass simples (sem morph) com fallback — para sub-superfícies internas.
    @ViewBuilder
    func assistantGlass<S: Shape>(
        shape: S,
        interactive: Bool = false,
        tint: Color? = nil,
        fallback: Material = .regularMaterial
    ) -> some View {
        if #available(macOS 26, iOS 26, *) {
            self.glassEffect(glassConfig(interactive: interactive, tint: tint), in: shape)
        } else {
            self.background(fallback, in: shape)
        }
    }
}

@available(macOS 26, iOS 26, *)
private func glassConfig(interactive: Bool, tint: Color?) -> Glass {
    var g: Glass = .regular
    if let tint { g = g.tint(tint) }
    if interactive { g = g.interactive() }
    return g
}

// MARK: - Bolha de mensagem reutilizável
//
// Espelha o estilo de AssistantChatView.MessageBubble (que é `private`), reutilizável
// pelo painel flutuante. Mantida deliberadamente simples — render pesado fica fora do
// `body` e a identidade vem de `ChatMessage.id` (estável), conforme skill swiftui-performance.

struct AssistantMessageBubble: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 28)
                Text(message.text)
                    .font(.hosBody)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(HOS.blue.opacity(0.16), in: RoundedRectangle(cornerRadius: HOS.rLg, style: .continuous))
            }
        case .assistant, .system:
            HStack {
                MarkdownText(text: message.text)
                    .font(.hosBody)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: HOS.rLg, style: .continuous))
                Spacer(minLength: 28)
            }
        case .tool:
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(HOS.info)
                if let toolName = message.toolName {
                    Text(toolName).font(.hosMono).foregroundStyle(HOS.info)
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(HOS.info.opacity(0.10), in: Capsule())
        case .error:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(HOS.error)
                Text(message.text).font(.hosFootnote).foregroundStyle(HOS.error)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(HOS.error.opacity(0.10), in: RoundedRectangle(cornerRadius: HOS.rMd, style: .continuous))
        }
    }
}
