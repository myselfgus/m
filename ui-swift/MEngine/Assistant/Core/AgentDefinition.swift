import Foundation

// MARK: - Configuração de agentes (código + UI) — peça técnica HealthOS §5.
// Um Codable que serve de seed em código, é serializável e editável na UI.

enum ClaudeModelID: String, Codable, CaseIterable, Identifiable {
    case opus48   = "claude-opus-4-8"
    case sonnet46 = "claude-sonnet-4-6"
    case haiku45  = "claude-haiku-4-5"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .opus48: return "Opus 4.8"
        case .sonnet46: return "Sonnet 4.6"
        case .haiku45: return "Haiku 4.5"
        }
    }
    var displayName: String { label }
    /// Opus 4.8 usa adaptive thinking e NÃO aceita parâmetros de sampling.
    var acceptsSampling: Bool { self != .opus48 }
}

enum Effort: String, Codable, CaseIterable, Identifiable {
    case low, medium, high, xhigh
    var id: String { rawValue }
}

/// Ferramentas server-side (a Anthropic executa) ligáveis por agente.
struct ServerTools: Codable, Equatable, Hashable {
    var webSearch = false
    var webFetch = false
    var codeExecution = false   // "sandbox incluído" (ZDR-elegível)
    var memory = false
}

struct AgentDefinition: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var model: ClaudeModelID
    var systemPrompt: String
    var effort: Effort = .high
    var maxTokens: Int = 8_000
    var temperature: Double? = nil          // ignorado p/ Opus 4.8
    var server: ServerTools = .init()
    var clientToolIDs: [String] = []        // nomes de client tools habilitadas
    var permission: PermissionMode = .ask

    enum PermissionMode: String, Codable, CaseIterable, Identifiable {
        case ask, acceptReads, acceptAll
        var id: String { rawValue }
    }

    /// Nome curto p/ pickers compactos (antes do " — ", senão a 1ª palavra).
    var shortName: String {
        if let head = name.components(separatedBy: " — ").first, head != name { return head }
        return name.components(separatedBy: " ").first ?? name
    }
}

// MARK: - Seeds versionados (defaults). UI faz override por cima (AgentRegistry — P2/P6).

enum AgentSeeds {
    static let clinico = AgentDefinition(
        id: "clinico-espaco-mental",
        name: "Clínico — Espaço Mental ℳ",
        model: .opus48,
        systemPrompt: """
        Você é um copiloto clínico do HealthOS para o Dr. Gustavo, sobre a tríade ASL+VDLP+GEM. \
        Nunca produza escores numéricos no corpo; ancore afirmações na fala literal do paciente. \
        Artefatos derivados (SOAP/referral/prescrição) são RASCUNHO, presos à sessão, e nunca \
        viram efetivos automaticamente. Responda em português do Brasil, de forma concisa e clínica.
        """,
        effort: .high,
        server: ServerTools(codeExecution: true),
        clientToolIDs: [],
        permission: .ask
    )

    static let geral = AgentDefinition(
        id: "geral",
        name: "Geral — rápido",
        model: .sonnet46,
        systemPrompt: "Assistente geral do HealthOS. Conciso, PT-BR. Sem identificadores de paciente além do necessário.",
        server: ServerTools()
    )

    static let all: [AgentDefinition] = [clinico, geral]
}
