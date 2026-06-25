import Foundation

// MARK: - Parser SSE (text/event-stream sobre POST) — peça técnica HealthOS §6.2.
// Messages API usa POST + event-stream, então não dá pra usar EventSource do WebKit:
// consumimos `URLSession.bytes` e quebramos em frames `event:`/`data:` (linha em branco
// separa frames). `data:` pode vir em múltiplas linhas — concatenamos com "\n".

struct SSEEvent: Sendable { let event: String; let data: String }

enum SSEParser {
    static func events(_ bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var event = "message"
                var data = ""
                do {
                    for try await line in bytes.lines {
                        if line.isEmpty {                       // fim de um frame
                            if !data.isEmpty {
                                continuation.yield(SSEEvent(event: event, data: data))
                            }
                            event = "message"; data = ""
                        } else if line.hasPrefix("event:") {
                            event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            let chunk = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            data += data.isEmpty ? chunk : "\n" + chunk
                        }
                        // linhas de comentário (":") e outros campos são ignorados
                    }
                    if !data.isEmpty { continuation.yield(SSEEvent(event: event, data: data)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
