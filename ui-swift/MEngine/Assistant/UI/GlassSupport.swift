import SwiftUI

// MARK: - Liquid Glass helpers + animação de expansão (morph orb ↔ painel).
// Gate macOS 26 / iOS 26 com fallback de material (skill swiftui-liquid-glass).

extension View {
    /// Superfície de vidro com forma arredondada; `interactive` só em elementos clicáveis.
    @ViewBuilder
    func regularGlass(cornerRadius: CGFloat, interactive: Bool = false) -> some View {
        if #available(macOS 26, iOS 26, *) {
            glassEffect(interactive ? .regular.interactive() : .regular,
                        in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.thickMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(HOS.hairline, lineWidth: 0.75)
                )
        }
    }
}

extension Animation {
    /// Mola usada no morph orb ↔ painel do assistente.
    static var agentExpansion: Animation {
        .spring(response: 0.42, dampingFraction: 0.82, blendDuration: 0.08)
    }
}
