import SwiftUI

/// Coluna direita "Assistente": chat com o agente do M-Engine via WebSocket.
/// Quando `slug` está presente, o assistente opera no contexto desse paciente.
struct AssistantChatView: View {
    /// Quando presente (iOS sheet), o header mostra um botão de fechar.
    var onClose: (() -> Void)? = nil

    @EnvironmentObject private var settings: AppSettings
    @StateObject private var session = AssistantSession.placeholder
    @State private var draft = ""
    @State private var live: AssistantSession?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            inputBar
        }
        .background(.thickMaterial)
        .task { startSession() }
        .onDisappear { live?.disconnect() }
    }

    // MARK: - Cabeçalho

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(HOS.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text("Assistente").font(.hosTitle3).foregroundStyle(.primary)
                Text("Sonnet 4.6 · contexto geral").font(.hosCaption).foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(
                text: bound.connected ? "Conectado" : "Conectando…",
                color: bound.connected ? HOS.complete : HOS.pending,
                systemImage: bound.connected ? "circle.fill" : "circle.dotted"
            )
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Fechar assistente")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: - Transcrição

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if bound.messages.isEmpty {
                        emptyState
                    }
                    ForEach(bound.messages) { msg in
                        MessageBubble(message: msg).id(msg.id)
                    }
                    if bound.thinking {
                        thinkingRow.id("thinking")
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: bound.messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: bound.thinking) { _, _ in scrollToBottom(proxy) }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
            Text("Pergunte ao assistente sobre o paciente ou o pipeline.")
                .font(.hosFootnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private var thinkingRow: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("pensando…").font(.hosFootnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Entrada

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Mensagem ao assistente", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.hosBody)
                .lineLimit(1...4)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: HOS.rMd, style: .continuous))
                .onSubmit(sendDraft)
                #if os(iOS)
                .textInputAutocapitalization(.sentences)
                #endif
            Button(action: sendDraft) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSend ? HOS.blue : Color.secondary)
            .disabled(!canSend)
            .help("Enviar")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Lógica

    /// Sessão observada: a real (`live`) assim que disponível, senão o placeholder.
    private var bound: AssistantSession { live ?? session }

    private var canSend: Bool {
        bound.connected && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func startSession() {
        live?.disconnect()
        guard let base = URL(string: settings.baseURL) else { return }
        let s = AssistantSession(baseURL: base, apiKey: settings.apiKey)
        live = s
        s.connect()
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, bound.connected else { return }
        bound.send(text)
        draft = ""
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if bound.thinking {
                proxy.scrollTo("thinking", anchor: .bottom)
            } else if let last = bound.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

// MARK: - Balão de mensagem

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 32)
                Text(message.text)
                    .font(.hosBody)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(HOS.blue.opacity(0.16), in: RoundedRectangle(cornerRadius: HOS.rLg, style: .continuous))
            }
        case .assistant, .system:
            HStack {
                MarkdownText(text: message.text)
                    .font(.hosBody)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: HOS.rLg, style: .continuous))
                Spacer(minLength: 32)
            }
        case .tool:
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(HOS.info)
                if let toolName = message.toolName {
                    Text(toolName).font(.hosMono).foregroundStyle(HOS.info)
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(HOS.info.opacity(0.10), in: Capsule())
        case .error:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(HOS.error)
                Text(message.text).font(.hosFootnote).foregroundStyle(HOS.error)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(HOS.error.opacity(0.10), in: RoundedRectangle(cornerRadius: HOS.rMd, style: .continuous))
        }
    }
}

private extension AssistantSession {
    /// Placeholder inerte para satisfazer `@StateObject` antes de a sessão real existir.
    static var placeholder: AssistantSession {
        AssistantSession(baseURL: URL(string: "http://invalid")!, apiKey: nil)
    }
}
