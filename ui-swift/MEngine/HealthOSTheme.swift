import SwiftUI

// MARK: - HealthOS Design System (tokens) — adaptado do bundle healthdrive.
// Cores da marca, stage tints (STT/PROC/SPEECH/ASL/VDLP/GEM), estados semânticos,
// tipografia (SF Pro / SF Pro Rounded / SF Mono), glass cards, capsules e stat cards.

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
    // Marca
    static let ink = Color(hex: "1C2533")
    static let navy = Color(hex: "1C3A63")
    static let blue = Color(hex: "3B82F6")        // tint do sistema
    static let blueBright = Color(hex: "4F8DF5")
    static let blueDeep = Color(hex: "1E5BC6")

    // Stage tints (pipeline)
    static let stStt = Color(hex: "64748B")
    static let stProc = Color(hex: "3B82F6")
    static let stSpeech = Color(hex: "0EA5B7")
    static let stAsl = Color(hex: "5B5BD6")
    static let stVdlp = Color(hex: "8B5CF6")
    static let stGem = Color(hex: "1FA86F")

    // Estados semânticos
    static let complete = Color(hex: "1FA86F")
    static let running = Color(hex: "3B82F6")
    static let review = Color(hex: "C2780C")
    static let pending = Color(hex: "64748B")
    static let error = Color(hex: "C2354A")
    static let info = Color(hex: "2C5BA0")
    static let queued = Color(hex: "7A8699")

    // Stat-card tints (Home)
    static let tintBlue = Color(hex: "3B82F6")
    static let tintIndigo = Color(hex: "5B5BD6")
    static let tintPurple = Color(hex: "8B5CF6")
    static let tintTeal = Color(hex: "0EA5B7")

    // Raios
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

// MARK: - Glass card

struct HealthCard: ViewModifier {
    var padding: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: HOS.rXl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HOS.rXl, style: .continuous)
                    .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.06), radius: 3, x: 0, y: 1)
    }
}

extension View {
    func healthCard(padding: CGFloat = 14) -> some View { modifier(HealthCard(padding: padding)) }
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

// MARK: - Stat card (Home)

struct StatCard: View {
    let symbol: String
    let value: String
    let label: String
    var tint: Color = HOS.tintBlue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
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

/// Rótulo padrão de botão de ação. No iOS renderiza SOMENTE o ícone para
/// economizar viewport (o texto vira `accessibilityLabel` p/ VoiceOver); no
/// macOS, onde há espaço, mantém texto + ícone. Use no lugar de `Label(...)`
/// dentro de `Button { } label:` para que a regra de plataforma fique num só lugar.
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

// MARK: - Brand mark (mantém o m-icon do app)

struct BrandMark: View {
    var size: CGFloat = 22
    var body: some View {
        // Usa o ícone do app (m-icon) empacotado; fallback para SF Symbol.
        Group {
            #if os(macOS)
            if let img = NSImage(named: "AppIcon") {
                Image(nsImage: img).resizable()
            } else {
                Image(systemName: "waveform.circle.fill").resizable()
            }
            #else
            Image(systemName: "waveform.circle.fill").resizable()
            #endif
        }
        .scaledToFit()
        .frame(width: size, height: size)
        .foregroundStyle(HOS.blue)
    }
}
