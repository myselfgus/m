import Foundation

// MARK: - MessagesAPITransport (B) — cliente Swift nativo direto na Messages API.
//
// Streaming SSE via URLSession.bytes; traduz o stream em AgentEvent; loop interno de
// tool use (client tools executadas em Swift). Peça técnica HealthOS §6.4.
// PHI: a chave vive no Keychain (dev) — em produção, trocar por relay `.proxied`.

final class MessagesAPITransport: AgentTransport {
    private let credentials: KeychainCredentialStore
    private let registry: ClientToolRegistry
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let anthropicVersion = "2023-06-01"
    private let maxToolTurns = 16   // cap do loop (evita agente preso)

    init(credentials: KeychainCredentialStore = .init(),
         registry: ClientToolRegistry = EmptyToolRegistry()) {
        self.credentials = credentials
        self.registry = registry
    }

    func run(_ history: [ChatMessage], agent: AgentDefinition) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let key = try credentials.apiKey()
                    var messages = Self.apiMessages(from: history)
                    var turns = 0
                    while true {
                        turns += 1
                        let turn = try await streamOneTurn(messages: messages, agent: agent, key: key) {
                            continuation.yield($0)
                        }
                        messages.append(["role": "assistant", "content": turn.assistantContent])

                        guard turn.stopReason == "tool_use", !turn.toolUses.isEmpty, turns <= maxToolTurns else {
                            continuation.yield(.stopped(reason: turn.stopReason ?? "end_turn"))
                            break
                        }
                        // Executa as client tools pedidas e devolve os tool_result.
                        var results: [[String: Any]] = []
                        for tu in turn.toolUses {
                            let out: ToolOutput
                            do { out = try await registry.execute(name: tu.name, inputJSON: tu.inputJSON) }
                            catch { out = ToolOutput(summary: "erro", content: "erro: \(error.localizedDescription)") }
                            continuation.yield(.toolResult(id: tu.id, summary: out.summary))
                            results.append([
                                "type": "tool_result",
                                "tool_use_id": tu.id,
                                "content": out.content,
                            ])
                        }
                        messages.append(["role": "user", "content": results])
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Um turno (uma chamada stream=true)

    private func streamOneTurn(messages: [[String: Any]],
                               agent: AgentDefinition,
                               key: String,
                               emit: @escaping (AgentEvent) -> Void) async throws -> AssistantTurn {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")

        var body: [String: Any] = [
            "model": agent.model.rawValue,
            "max_tokens": agent.maxTokens,
            "stream": true,
            "system": agent.systemPrompt,
            "messages": messages,
        ]
        let tools = registry.specs(for: agent)
        if !tools.isEmpty { body["tools"] = tools }
        if agent.model.acceptsSampling, let t = agent.temperature { body["temperature"] = t }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            // Tenta ler corpo de erro do stream.
            var errBody = ""
            for try await line in bytes.lines { errBody += line; if errBody.count > 600 { break } }
            throw AgentError.http(status: http.statusCode, body: errBody)
        }

        var turn = AssistantTurn()
        for try await sse in SSEParser.events(bytes) {
            guard let data = sse.data.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            switch type {
            case "message_start":
                if let m = obj["message"] as? [String: Any], let id = m["id"] as? String {
                    emit(.started(messageID: id))
                }
            case "content_block_start":
                turn.openBlock(obj, emit: emit)
            case "content_block_delta":
                turn.applyDelta(obj, emit: emit)
            case "content_block_stop":
                turn.closeBlock(obj, emit: emit)
            case "message_delta":
                if let d = obj["delta"] as? [String: Any], let r = d["stop_reason"] as? String {
                    turn.stopReason = r
                }
                if let u = obj["usage"] as? [String: Any], let o = u["output_tokens"] as? Int {
                    emit(.usage(input: u["input_tokens"] as? Int ?? 0, output: o))
                }
            case "message_stop":
                return turn
            case "error":
                throw AgentError.stream(String(describing: obj["error"] ?? obj))
            default:
                break   // ping etc.
            }
        }
        return turn
    }

    /// Converte o histórico (ChatMessage) em mensagens da API (apenas user/assistant de texto).
    private static func apiMessages(from history: [ChatMessage]) -> [[String: Any]] {
        history.compactMap { msg in
            switch msg.role {
            case .user:      return ["role": "user", "content": msg.text]
            case .assistant: return ["role": "assistant", "content": msg.text]
            default:         return nil   // tool/error/system não voltam ao modelo como turno
            }
        }
    }
}

// MARK: - Acumulador de blocos do turno (por índice)
//
// Reconstrói tool_use.input concatenando `partial_json` (os chunks NÃO respeitam fronteira
// de JSON — só parsear no content_block_stop). Mantém simples e testável (§6.4).

struct AssistantTurnToolUse: Sendable { let id: String; let name: String; let inputJSON: String }

struct AssistantTurn {
    private struct Block { var type: String; var id: String?; var name: String?; var text = ""; var partialJSON = "" }
    private var blocks: [Int: Block] = [:]
    private(set) var text = ""
    var stopReason: String?

    mutating func openBlock(_ obj: [String: Any], emit: (AgentEvent) -> Void) {
        guard let index = obj["index"] as? Int,
              let cb = obj["content_block"] as? [String: Any],
              let type = cb["type"] as? String else { return }
        var b = Block(type: type, id: cb["id"] as? String, name: cb["name"] as? String)
        if type == "text", let t = cb["text"] as? String { b.text = t }
        blocks[index] = b
        if type == "tool_use", let id = b.id, let name = b.name {
            emit(.toolUseStarted(id: id, name: name))
        }
    }

    mutating func applyDelta(_ obj: [String: Any], emit: (AgentEvent) -> Void) {
        guard let index = obj["index"] as? Int,
              let delta = obj["delta"] as? [String: Any],
              let dtype = delta["type"] as? String else { return }
        switch dtype {
        case "text_delta":
            let t = delta["text"] as? String ?? ""
            blocks[index]?.text += t; text += t; emit(.text(t))
        case "thinking_delta":
            emit(.thinking(delta["thinking"] as? String ?? ""))
        case "input_json_delta":
            blocks[index]?.partialJSON += delta["partial_json"] as? String ?? ""
        case "citations_delta":
            if let c = delta["citation"] as? [String: Any], let cited = c["cited_text"] as? String {
                emit(.citation(cited))
            }
        default:
            break
        }
    }

    mutating func closeBlock(_ obj: [String: Any], emit: (AgentEvent) -> Void) {
        guard let index = obj["index"] as? Int, let b = blocks[index] else { return }
        if b.type == "tool_use", let id = b.id, let name = b.name {
            emit(.toolUseReady(id: id, name: name, inputJSON: b.partialJSON))
        }
    }

    /// Client tools (as que ESTE app executa) pedidas neste turno.
    var toolUses: [AssistantTurnToolUse] {
        blocks.values.compactMap { b in
            guard b.type == "tool_use", let id = b.id, let name = b.name else { return nil }
            return AssistantTurnToolUse(id: id, name: name, inputJSON: b.partialJSON)
        }
    }

    /// Conteúdo da mensagem `assistant` para reenviar no próximo turno (texto + tool_use).
    var assistantContent: [[String: Any]] {
        var out: [[String: Any]] = []
        for index in blocks.keys.sorted() {
            guard let b = blocks[index] else { continue }
            switch b.type {
            case "text":
                if !b.text.isEmpty { out.append(["type": "text", "text": b.text]) }
            case "tool_use":
                if let id = b.id, let name = b.name {
                    let input = (try? JSONSerialization.jsonObject(with: Data(b.partialJSON.utf8))) ?? [:]
                    out.append(["type": "tool_use", "id": id, "name": name, "input": input])
                }
            default:
                break
            }
        }
        if out.isEmpty { out.append(["type": "text", "text": text]) }
        return out
    }
}
