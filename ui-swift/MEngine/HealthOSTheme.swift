import SwiftUI

// MARK: - HealthOS Design System (tokens) — refinado a partir do bundle healthdrive (HDrive v2).
// Liquid Glass THICK + shadow FLOATING, paleta da marca + stage tints + estados semânticos,
// tipografia macOS 26, marca connection-node nativa, capsules e stat cards.
// Fonte canônica: healthdrive/project/skill/healthos-design/references/tokens.css.

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: h).scanHexInt64(&v)
        let r, g, b: Double
        if h.count == 6 {
            r = Double((v >> 16) & 0xFF) / 255
            g = Double((v >> 8) & 0xFF) / 255
            b = Double(v & 0xFF) / 255
        } else { r = 0; g = 0; b = 0 }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

enum HOS {
    // ─── Marca (do logo) ───────────────────────────────────────────────
    static let ink = Color(hex: "1C2533")          // "health" — navy quase preto
    static let navy = Color(hex: "1C3A63")         // metade escura do ícone
    static let navyLt = Color(hex: "2E5388")
    static let blue = Color(hex: "3B82F6")         // "OS" + metade clara — tint do sistema
    static let blueBright = Color(hex: "4F8DF5")
    static let blueDeep = Color(hex: "1E5BC6")
    static let blueSoft = Color(hex: "3B82F6").opacity(0.12)

    // ─── Stage tints (STT · PROC · SPEECH · ASL · VDLP · GEM) ───────────
    static let stStt = Color(hex: "64748B")
    static let stProc = Color(hex: "3B82F6")
    static let stSpeech = Color(hex: "0EA5B7")
    static let stAsl = Color(hex: "5B5BD6")
    static let stVdlp = Color(hex: "8B5CF6")
    static let stGem = Color(hex: "1FA86F")

    // ─── Estados semânticos ─────────────────────────────────────────────
    static let complete = Color(hex: "1FA86F")     // gem_complete
    static let running = Color(hex: "3B82F6")
    static let review = Color(hex: "C2780C")        // needs_review
    static let pending = Color(hex: "64748B")
    static let error = Color(hex: "C2354A")
    static let degraded = Color(hex: "C2780C")
    static let info = Color(hex: "2C5BA0")
    static let queued = Color(hex: "7A8699")

    // ─── Stat-card tints (Home) ─────────────────────────────────────────
    static let tintBlue = Color(hex: "3B82F6")
    static let tintIndigo = Color(hex: "5B5BD6")
    static let tintPurple = Color(hex: "8B5CF6")
    static let tintTeal = Color(hex: "0EA5B7")

    // ─── Superfícies (system-adaptive via .background; estes são realces) ─
    // Hairlines fazem o trabalho que a sombra fazia: separação por linha sutil,
    // não por elevação. Sensibilidade content-first (Claude Desktop).
    static let divider = ink.opacity(0.06)        // separador entre linhas
    static let hairline = ink.opacity(0.08)       // borda de card/superfície
    static let glassTint = blue.opacity(0.035)
    static let glassHairline = Color.white.opacity(0.45)

    /// Material de superfície de conteúdo plana e calma (substitui o vidro pesado
    /// nas listas). Fino e adaptativo a claro/escuro — separação por hairline, não
    /// por elevação. Sensibilidade content-first (Claude Desktop).
    static let contentSurface: Material = .thinMaterial

    // ─── Raios ──────────────────────────────────────────────────────────
    static let rSm: CGFloat = 6
    static let rMd: CGFloat = 8
    static let rLg: CGFloat = 12
    static let rXl: CGFloat = 16
    static let rXxl: CGFloat = 20   // Liquid Glass arredondado (cards/rows da linguagem refrescada)
    static let rRow: CGFloat = 14   // raio de linha de lista (glass row)

    // ─── Espaçamento (grade de 8 pt) ────────────────────────────────────
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 20
    static let s6: CGFloat = 24
    static let s7: CGFloat = 28
    static let s8: CGFloat = 32

    // ─── Tiles planos (superfície de conteúdo achatada) ─────────────────
    /// Preenchimento de tile plano calmo (Claude-desktop): leve, content-first.
    static func tileFill(selected: Bool = false) -> Color {
        selected ? blue.opacity(0.10) : Color.primary.opacity(0.05)
    }
    /// Borda de um tile selecionado (realce sutil verde/azul).
    static let selectedHairline = blue.opacity(0.35)

    /// Tint do stage/documento por palavra-chave (nome do artefato ou stage).
    static func tint(forStage s: String) -> Color {
        let k = s.lowercased()
        if k.contains("birp") { return stProc }
        if k.contains("gem") { return stGem }
        if k.contains("dimensional") || k.contains("vdlp") { return stVdlp }
        if k.contains("asl") { return stAsl }
        if k.contains("soap_long") || k.contains("seguimento") { return tintTeal }
        if k.contains("soap") { return navy }
        if k.contains("transcri") || k.contains("stt") { return stStt }
        if k.contains("normalize") || k.contains("proc") { return stProc }
        return pending
    }

    /// Cor de um estado de job/stage.
    static func tint(forState s: String) -> Color {
        switch s.uppercased() {
        case "SUCCESS", "COMPLETE": return complete
        case "STARTED", "RUNNING", "PROGRESS": return running
        case "RETRY", "REVIEW", "NEEDS_REVIEW": return review
        case "FAILURE", "ERROR": return error
        case "DEGRADED": return degraded
        case "PENDING", "QUEUED": return queued
        default: return info
        }
    }
}

// MARK: - Tipografia (escala macOS 26 do design system)

extension Font {
    static let hosLargeTitle = Font.system(size: 26, weight: .bold)
    static let hosTitle1 = Font.system(size: 22, weight: .semibold)
    static let hosTitle2 = Font.system(size: 17, weight: .semibold)
    static let hosTitle3 = Font.system(size: 15, weight: .semibold)
    static let hosHeadline = Font.system(size: 13, weight: .semibold)
    static let hosBody = Font.system(size: 13, weight: .regular)
    static let hosCallout = Font.system(size: 12, weight: .regular)
    static let hosSubhead = Font.system(size: 11, weight: .medium)
    static let hosFootnote = Font.system(size: 11, weight: .regular)
    static let hosCaption = Font.system(size: 10, weight: .medium)
    static let hosMono = Font.system(size: 12, design: .monospaced)
    static func hosStat(_ size: CGFloat = 30) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
}

// MARK: - Elevação (shadow FLOATING do design system)

struct FloatingShadow: ViewModifier {
    // --shadow-floating: elevação para superfícies que de fato "flutuam".
    // Refinado: mais difuso e leve (sensibilidade content-first; menos peso de glass).
    func body(content: Content) -> some View {
        content
            .shadow(color: .black.opacity(0.10), radius: 16, x: 0, y: 8)
            .shadow(color: .black.opacity(0.05), radius: 3, x: 0, y: 1)
    }
}

struct CardShadow: ViewModifier {
    // --shadow-card: elevação quase imperceptível para superfícies estáticas.
    // Refinado: trocamos a sombra por uma dica mínima — hairlines fazem o trabalho.
    func body(content: Content) -> some View {
        content.shadow(color: .black.opacity(0.04), radius: 2, x: 0, y: 1)
    }
}

struct ModalShadow: ViewModifier {
    // --shadow-modal: sheets / modais (elevação máxima)
    func body(content: Content) -> some View {
        content
            .shadow(color: .black.opacity(0.24), radius: 32, x: 0, y: 24)
            .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 4)
    }
}

/// Campo "recessed" (input/well): afunda abaixo dos cards — sem sombra de elevação,
/// preenchimento sutil + hairline. Cria o degrau mais baixo da hierarquia.
struct RecessedField: ViewModifier {
    var cornerRadius: CGFloat = HOS.rMd
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(.quaternary, in: shape)
            .overlay(shape.strokeBorder(HOS.divider, lineWidth: 1))
    }
}

extension View {
    func floatingShadow() -> some View { modifier(FloatingShadow()) }
    func cardShadow() -> some View { modifier(CardShadow()) }
    func modalShadow() -> some View { modifier(ModalShadow()) }
    /// Superfície recessed para campos/wells.
    func recessedField(cornerRadius: CGFloat = HOS.rMd) -> some View { modifier(RecessedField(cornerRadius: cornerRadius)) }
}

// MARK: - Superfície de vidro (Liquid Glass: thin / regular / THICK)

enum GlassLevel {
    case thin, regular, thick
    var material: Material {
        switch self {
        case .thin: return .ultraThinMaterial
        case .regular: return .regularMaterial
        case .thick: return .thickMaterial   // glass-thick (0.86 / blur 32)
        }
    }
}

/// Superfície de vidro com borda-realce (glass-border) — base dos cards.
struct GlassSurface: ViewModifier {
    var level: GlassLevel = .thick
    var cornerRadius: CGFloat = HOS.rXl
    var tinted: Bool = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(level.material, in: shape)
            .overlay {
                if tinted { shape.fill(HOS.glassTint) }
            }
            .overlay {
                // Borda calma: hairline única em vez do realce branco de "vidro".
                // Conteúdo sobre cromo — a separação vem da linha, não do brilho.
                shape.strokeBorder(HOS.hairline, lineWidth: 0.75)
            }
            .clipShape(shape)
    }
}

extension View {
    /// Superfície de vidro nua (sem padding), nível configurável.
    func glassSurface(_ level: GlassLevel = .thick, cornerRadius: CGFloat = HOS.rXl, tinted: Bool = false) -> some View {
        modifier(GlassSurface(level: level, cornerRadius: cornerRadius, tinted: tinted))
    }
}

// MARK: - Glass card (THICK + FLOATING — default do design system refinado)

struct HealthCard: ViewModifier {
    var padding: CGFloat = 14
    var level: GlassLevel = .regular   // default leve; thick é opt-in p/ superfícies elevadas
    var floating: Bool = false         // sombra sutil (card); floating só onde "flutua" de fato
    var tinted: Bool = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .glassSurface(level, cornerRadius: HOS.rXl, tinted: tinted)
            .modifier(floating ? AnyViewModifier(FloatingShadow()) : AnyViewModifier(CardShadow()))
    }
}

/// Apaga a diferença de tipo entre dois modifiers num ternário.
struct AnyViewModifier: ViewModifier {
    private let apply: (AnyView) -> AnyView
    init<M: ViewModifier>(_ m: M) { apply = { AnyView($0.modifier(m)) } }
    func body(content: Content) -> some View { apply(AnyView(content)) }
}

extension View {
    /// Card de vidro (default: regular + sombra sutil — nível RESTING).
    func healthCard(padding: CGFloat = 14, level: GlassLevel = .regular, floating: Bool = false, tinted: Bool = false) -> some View {
        modifier(HealthCard(padding: padding, level: level, floating: floating, tinted: tinted))
    }

    /// Nível RAISED — thick + floating. Use em popovers, item selecionado/destaque.
    func raisedCard(padding: CGFloat = 14, tinted: Bool = false) -> some View {
        modifier(HealthCard(padding: padding, level: .thick, floating: true, tinted: tinted))
    }

    /// Nível OVERLAY — thick + sombra modal. Use no container de sheets/modais.
    func overlaySurface(padding: CGFloat = 0) -> some View {
        modifier(HealthCard(padding: padding, level: .thick, floating: false))
            .modalShadow()
    }
}

// MARK: - Capsule / status pill

struct StatusPill: View {
    let text: String
    var color: Color = HOS.pending
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 9, weight: .semibold)) }
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(color.opacity(0.13), in: Capsule())
    }
}

// MARK: - Stat card (mantido como símbolo público; refinado e mais leve)
//
// Não é mais o centro do dashboard (as quatro "praças de vaidade" saíram).
// Permanece disponível para usos pontuais: superfície de conteúdo plana,
// hairline em vez de sombra, ícone monocromático discreto.

struct StatCard: View {
    let symbol: String
    let value: String
    let label: String
    var tint: Color = HOS.tintBlue

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                Text(label.uppercased())
                    .font(.hosCaption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.hosStat(28))
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(HOS.contentSurface, in: RoundedRectangle(cornerRadius: HOS.rLg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HOS.rLg, style: .continuous)
                .strokeBorder(HOS.hairline, lineWidth: 0.75)
        )
    }
}

// MARK: - Inline stat — resumo numérico em linha (não "praça")

/// Um número + rótulo discreto, para uma linha de resumo compacta no header.
/// Substitui as quatro grandes praças de contagem por uma tira sóbria.
struct InlineStat: View {
    let value: String
    let label: String
    var systemImage: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
            }
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
            Text(label)
                .font(.hosFootnote)
                .foregroundStyle(.secondary)
        }
        .fixedSize()
    }
}

// MARK: - Lista com hairlines (superfície de conteúdo única)

/// Container de conteúdo plano: uma superfície, hairlines entre as linhas.
/// O padrão "rows com separadores" pedido para as listas do dashboard —
/// conteúdo sobre cromo, sem praças de vidro pesadas.
struct HairlineList<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(HOS.contentSurface, in: RoundedRectangle(cornerRadius: HOS.rLg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HOS.rLg, style: .continuous)
                .strokeBorder(HOS.hairline, lineWidth: 0.75)
        )
    }
}

/// Cabeçalho de seção do dashboard: rótulo discreto + ação opcional à direita.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var systemImage: String? = nil
    let trailing: Trailing

    init(_ title: String, systemImage: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(title.uppercased())
                .font(.hosSubhead)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String, systemImage: String? = nil) {
        self.init(title, systemImage: systemImage) { EmptyView() }
    }
}

// MARK: - Action label (icon-only no iOS, texto+ícone no macOS)

struct ActionLabel: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        #if os(iOS)
        Image(systemName: systemImage)
            .accessibilityLabel(title)
        #else
        Label(title, systemImage: systemImage)
        #endif
    }
}

// MARK: - Marca do app (logo M / AppIcon)

/// Logo M do app (m-icon empacotado como AppIcon); fallback p/ SF Symbol.
struct BrandMark: View {
    var size: CGFloat = 22
    var body: some View {
        Group {
            #if os(macOS)
            if let img = NSImage(named: "AppIcon") {
                Image(nsImage: img).resizable()
            } else {
                Image(systemName: "waveform.circle.fill").resizable().foregroundStyle(HOS.blue)
            }
            #else
            if let ui = UIImage(named: "AppIcon") {
                Image(uiImage: ui).resizable()
            } else {
                Image(systemName: "waveform.circle.fill").resizable().foregroundStyle(HOS.blue)
            }
            #endif
        }
        .scaledToFit()
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityLabel("M-Engine")
    }
}

// MARK: - Wash radial azul (fundo de dashboard / empty states)

struct BlueWash: View {
    var body: some View {
        // Um único floreio de baixa opacidade: window background → tint azul/indigo/teal.
        // Mantido sutil (content-first); o radial dá profundidade sem competir com o conteúdo.
        ZStack {
            LinearGradient(
                colors: [.clear, HOS.tintIndigo.opacity(0.045), HOS.tintTeal.opacity(0.03)],
                startPoint: .top, endPoint: .bottom)
            RadialGradient(
                colors: [HOS.blue.opacity(0.10), .clear],
                center: .topTrailing, startRadius: 0, endRadius: 560)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Glass row (linha de lista arredondada — linguagem refrescada)

/// Linha de lista como superfície de vidro arredondada: ícone (em badge circular
/// opcional) + título headline + legenda secundária + acessório à direita.
/// Espaçamento generoso de 8 pt. Base das listas do dashboard e do detalhe.
struct GlassRow<Leading: View, Subtitle: View, Trailing: View>: View {
    var selected: Bool = false
    let leading: Leading
    let title: String
    let subtitle: Subtitle
    let trailing: Trailing

    init(title: String, selected: Bool = false,
         @ViewBuilder leading: () -> Leading,
         @ViewBuilder subtitle: () -> Subtitle,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.selected = selected
        self.leading = leading()
        self.subtitle = subtitle()
        self.trailing = trailing()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: HOS.rRow, style: .continuous)
        HStack(spacing: HOS.s3) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.hosHeadline).foregroundStyle(.primary).lineLimit(1)
                subtitle
            }
            Spacer(minLength: HOS.s2)
            trailing
        }
        .padding(.horizontal, HOS.s3)
        .padding(.vertical, 11)
        .background(HOS.tileFill(selected: selected), in: shape)
        .overlay(shape.strokeBorder(selected ? HOS.selectedHairline : HOS.hairline, lineWidth: 0.75))
        .contentShape(Rectangle())
    }
}

extension GlassRow where Subtitle == _GlassRowText {
    init(title: String, subtitle: String? = nil, selected: Bool = false,
         @ViewBuilder leading: () -> Leading,
         @ViewBuilder trailing: () -> Trailing) {
        self.init(title: title, selected: selected, leading: leading,
                  subtitle: { _GlassRowText(text: subtitle) }, trailing: trailing)
    }
}

/// Legenda textual padrão de uma GlassRow (caption, secundária).
struct _GlassRowText: View {
    let text: String?
    var body: some View {
        if let text { Text(text).font(.hosCaption).foregroundStyle(.secondary).lineLimit(1) }
    }
}

// MARK: - Badge de ícone circular (avatar/glyph de linha)

/// Glyph SF Symbol num disco tint suave — o acessório-líder das glass rows.
struct IconBadge: View {
    let systemImage: String
    var tint: Color = HOS.blue
    var size: CGFloat = 34
    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: Circle())
    }
}

// MARK: - Cabeçalho de folha (sheet) — ícone em badge + título + legenda

/// Cabeçalho consistente para as folhas (Novo paciente, Nova consulta, etc.):
/// badge circular do ícone + título + legenda opcional + acessório à direita.
struct SheetHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    let systemImage: String
    var tint: Color = HOS.blue
    let trailing: Trailing

    init(_ title: String, subtitle: String? = nil, systemImage: String,
         tint: Color = HOS.blue, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: HOS.s3) {
            IconBadge(systemImage: systemImage, tint: tint, size: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.hosTitle1).foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle).font(.hosFootnote).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: HOS.s2)
            trailing
        }
    }
}

extension SheetHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil, systemImage: String, tint: Color = HOS.blue) {
        self.init(title, subtitle: subtitle, systemImage: systemImage, tint: tint) { EmptyView() }
    }
}

/// Rótulo de campo de formulário padronizado (uppercase, subhead, secundário).
struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.hosSubhead)
            .foregroundStyle(.secondary)
    }
}
