import SwiftUI
import MarkdownUI

/// Renderizador Markdown rico — usado tanto pelos balões do chat do assistente
/// quanto pelas views de documentos clínicos (BIRP/SOAP) e pelo "Espaço Mental ℳ".
///
/// Apoia-se em MarkdownUI (gonzalezreal/swift-markdown-ui), que entrega GFM completo:
/// títulos, listas, blocos de código (mono, sem realce sintático por padrão),
/// tabelas, citações e ênfase inline. O estilo segue os tokens HOS (claro/refinado,
/// separação por hairline, código em mono sobre superfície calma).
///
/// API mantida idêntica ao renderizador antigo: `MarkdownText(text:)`. Outros
/// arquivos do app dependem dessa assinatura.
///
/// Streaming: passamos o snapshot atual em `content`. A `View` é leve e a
/// identidade é estável (um único `Markdown`), então re-renderizar snapshots
/// crescentes durante o stream é barato — sem fan-out de observação.
///
/// LaTeX: NÃO coberto por esta lib. O pacote pretendido (SwiftStreamingMarkdown,
/// que embute iosMath) é iOS-only/UIKit e não compila no executável macOS, então
/// caímos para MarkdownUI. Renderização de LaTeX fica PENDENTE (precisa de uma
/// lib cross-platform como SwiftMath, integrável depois como bloco custom).
struct MarkdownText: View {
    let text: String

    init(text: String) {
        self.text = text
    }

    var body: some View {
        Markdown(text)
            .markdownTheme(.hos)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Tema HOS para MarkdownUI

private extension Theme {
    /// Tema content-first alinhado aos tokens HOS: tipografia do sistema,
    /// código mono sobre superfície calma, citações com barra azul sutil.
    static let hos = Theme()
        .text {
            ForegroundColor(HOS.ink)
            FontSize(13)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(12)
            BackgroundColor(HOS.ink.opacity(0.05))
            ForegroundColor(HOS.navy)
        }
        .strong { FontWeight(.semibold) }
        .link { ForegroundColor(HOS.blueDeep) }
        .heading1 { config in
            config.label
                .markdownMargin(top: 12, bottom: 6)
                .markdownTextStyle {
                    FontSize(22); FontWeight(.bold); ForegroundColor(HOS.ink)
                }
        }
        .heading2 { config in
            config.label
                .markdownMargin(top: 12, bottom: 6)
                .markdownTextStyle {
                    FontSize(17); FontWeight(.semibold); ForegroundColor(HOS.ink)
                }
        }
        .heading3 { config in
            config.label
                .markdownMargin(top: 10, bottom: 4)
                .markdownTextStyle {
                    FontSize(15); FontWeight(.semibold); ForegroundColor(HOS.ink)
                }
        }
        .heading4 { config in
            config.label
                .markdownMargin(top: 8, bottom: 4)
                .markdownTextStyle {
                    FontSize(13); FontWeight(.semibold); ForegroundColor(HOS.navy)
                }
        }
        .paragraph { config in
            config.label
                .markdownMargin(top: 0, bottom: 8)
                .lineSpacing(2)
        }
        .blockquote { config in
            config.label
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(HOS.blue.opacity(0.5))
                        .frame(width: 2.5)
                }
                .markdownTextStyle {
                    ForegroundColor(HOS.ink.opacity(0.75))
                }
        }
        .codeBlock { config in
            ScrollView(.horizontal, showsIndicators: false) {
                config.label
                    .relativeLineSpacing(.em(0.2))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(12)
                        ForegroundColor(HOS.ink)
                    }
                    .padding(12)
            }
            .background(HOS.ink.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: HOS.rMd, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HOS.rMd, style: .continuous)
                    .strokeBorder(HOS.hairline, lineWidth: 1)
            )
            .markdownMargin(top: 6, bottom: 10)
        }
        .table { config in
            config.label
                .markdownTableBorderStyle(.init(color: HOS.hairline, strokeStyle: .init(lineWidth: 1)))
                .markdownTableBackgroundStyle(
                    .alternatingRows(HOS.ink.opacity(0.02), Color.clear)
                )
                .markdownMargin(top: 6, bottom: 10)
        }
        .listItem { config in
            config.label.markdownMargin(top: 2, bottom: 2)
        }
}
