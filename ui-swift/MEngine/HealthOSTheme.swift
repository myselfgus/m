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
    static let divider = ink.opacity(0.08)
    static let glassTint = blue.opacity(0.04)
    static let glassHairline = Color.white.opacity(0.45)

    // ─── Raios ──────────────────────────────────────────────────────────
    static let rSm: CGFloat = 6
    static let rMd: CGFloat = 8
    static let rLg: CGFloat = 12
    static let rXl: CGFloat = 16

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
    // --shadow-floating: 0 8px 24px -4px rgba(0,0,0,.16), 0 2px 6px rgba(0,0,0,.08)
    func body(content: Content) -> some View {
        content
            .shadow(color: .black.opacity(0.16), radius: 12, x: 0, y: 8)
            .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 2)
    }
}

struct CardShadow: ViewModifier {
    // --shadow-card: elevação sutil para superfícies estáticas
    func body(content: Content) -> some View {
        content.shadow(color: .black.opacity(0.06), radius: 3, x: 0, y: 1)
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
                // glass-border: realce branco no topo decaindo (aresta de vidro)
                shape.stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.50), .white.opacity(0.10)],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.6)
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

// MARK: - Stat card (Home) — ícone em chip tintado + número rounded

struct StatCard: View {
    let symbol: String
    let value: String
    let label: String
    var tint: Color = HOS.tintBlue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: HOS.rMd, style: .continuous)
                    .fill(tint.opacity(0.16))
                    .frame(width: 30, height: 30)
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
            }
            Text(value)
                .font(.hosStat())
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
            Text(label)
                .font(.hosFootnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .healthCard()
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
        RadialGradient(
            colors: [HOS.blue.opacity(0.09), .clear],
            center: .topTrailing, startRadius: 0, endRadius: 520)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
