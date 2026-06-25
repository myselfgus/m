import SwiftUI
import Observation

// MARK: - ChatViewModel — estado de streaming da conversa. Peça técnica HealthOS §9.
// Consome AsyncThrowingStream<AgentEvent> do transporte (B hoje). UI lê este estado.

@MainActor
@Observable
final class ChatViewModel {
    var messages: [ChatMessage] = []
    var streamingText = ""
    var streamingThinking = ""
    var activeTools: [ToolCallVM] = []
    var isStreaming = false
    var errorText: String?
    var selectedAgent: AgentDefinition
    var composerText = ""
    var tokenUsage = ""
    let agents: [AgentDefinition] = AgentSeeds.all

    private let transport: AgentTransport
    private var streamTask: Task<Void, Never>?

    init(transport: AgentTransport, agent: AgentDefinition) {
        self.transport = transport
        self.selectedAgent = agent
    }

    var canSend: Bool { !isStreaming }

    /// Envia o texto do composer (usado pela UI nova).
    func submitComposer() {
        let t = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        send(t)
        composerText = ""
    }

    func stopStreaming() { stop() }
    func resetConversation() { clear() }

    func send(_ userText: String) {
        let text = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        messages.append(ChatMessage(role: .user, text: text))
        streamingText = ""; streamingThinking = ""; activeTools = []; errorText = nil
        isStreaming = true
        let history = messages
        let agent = selectedAgent
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in transport.run(history, agent: agent) {
                    self.apply(event)
                }
            } catch {
                self.finish(withError: error)
            }
        }
    }

    /// Botão "parar" (como no claude.ai).
    func stop() {
        streamTask?.cancel()
        flushStreamingIntoMessage(reason: "stopped")
        isStreaming = false
    }

    func clear() {
        stop()
        messages = []; streamingText = ""; streamingThinking = ""; activeTools = []; errorText = nil
    }

    private func apply(_ e: AgentEvent) {
        switch e {
        case .started:
            break
        case .text(let t):
            streamingText += t
        case .thinking(let t):
            streamingThinking += t
        case .toolUseStarted(let id, let name):
            activeTools.append(ToolCallVM(id: id, name: name, state: .running, summary: nil))
        case .toolUseReady:
            break
        case .toolResult(let id, let summary):
            if let i = activeTools.firstIndex(where: { $0.id == id }) {
                activeTools[i].state = .done
                activeTools[i].summary = summary
            }
        case .citation:
            break
        case .usage(let input, let output):
            if input > 0 || output > 0 { tokenUsage = "\(input)→\(output) tok" }
        case .stopped:
            flushStreamingIntoMessage(reason: "end_turn")
            isStreaming = false
        }
    }

    private func flushStreamingIntoMessage(reason: String) {
        let body = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { streamingText = ""; return }
        messages.append(ChatMessage(role: .assistant, text: streamingText))
        streamingText = ""; streamingThinking = ""
    }

    private func finish(withError error: Error) {
        errorText = error.localizedDescription
        if !streamingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(ChatMessage(role: .assistant, text: streamingText))
        }
        messages.append(ChatMessage(role: .error, text: error.localizedDescription))
        streamingText = ""; isStreaming = false
    }
}

/// Estado de uma chamada de ferramenta exibida na UI.
struct ToolCallVM: Identifiable {
    let id: String
    let name: String
    var state: State
    var summary: String?
    enum State { case running, done }
}
