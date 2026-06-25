import Foundation

// MARK: - AgentTransport — costura entre a UI conversacional e o motor (Claude).
//
// A UI consome SEMPRE `AsyncThrowingStream<AgentEvent>`, independente do transporte
// concreto (Messages API direto hoje; Foundation Models / sidecar no futuro).
// Trocar o motor = nova implementação deste protocolo, sem tocar UI/ViewModel.
// (Peça técnica HealthOS §3–§6.)

/// Eventos de domínio que a UI conhece — traduzidos do stream do transporte.
enum AgentEvent: Sendable {
    case started(messageID: String)
    case text(String)                                   // delta de texto
    case thinking(String)                               // delta de raciocínio
    case toolUseStarted(id: String, name: String)
    case toolUseReady(id: String, name: String, inputJSON: String)
    case toolResult(id: String, summary: String)        // após executar client tool
    case citation(String)
    case stopped(reason: String)
    case usage(input: Int, output: Int)
}

/// Transporte de um turno conversacional (com loop interno de tool use quando houver).
protocol AgentTransport: Sendable {
    /// Roda um turno a partir do histórico e do agente selecionado, emitindo eventos.
    func run(_ history: [ChatMessage], agent: AgentDefinition) -> AsyncThrowingStream<AgentEvent, Error>
}

// MARK: - Client tools (ponto de plugue do pipeline ℳ) — P3+.

/// Saída de uma client tool: `content` volta como `tool_result` ao modelo.
struct ToolOutput: Sendable { let summary: String; let content: String }

/// Uma ferramenta executada em Swift (asl/vdlp/gem/patient-memory/espacomental…).
protocol ClientTool: Sendable {
    static var toolName: String { get }
    static var schema: [String: Any] { get }
    func execute(inputJSON: String) async throws -> ToolOutput
}

/// Registro que despacha client tools por nome. Vazio no P0 (sem tools ainda).
protocol ClientToolRegistry: Sendable {
    /// Specs (nome + schema) das tools habilitadas para um agente — entram no body da API.
    func specs(for agent: AgentDefinition) -> [[String: Any]]
    /// Executa uma tool pelo nome com o input (JSON) acumulado do stream.
    func execute(name: String, inputJSON: String) async throws -> ToolOutput
}

/// Registro vazio (P0/P1): nenhum client tool. Server tools, quando ligadas, rodam no servidor.
struct EmptyToolRegistry: ClientToolRegistry {
    func specs(for agent: AgentDefinition) -> [[String: Any]] { [] }
    func execute(name: String, inputJSON: String) async throws -> ToolOutput {
        throw AgentError.unknownTool(name)
    }
}

// MARK: - Erros do transporte

enum AgentError: LocalizedError {
    case missingAPIKey
    case http(status: Int, body: String)
    case stream(String)
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Chave da Anthropic ausente. Adicione-a em Ajustes (Keychain)."
        case let .http(status, body):
            return "HTTP \(status): \(body.prefix(300))"
        case let .stream(msg):
            return "Erro no stream: \(msg)"
        case let .unknownTool(name):
            return "Ferramenta desconhecida: \(name)"
        }
    }
}
