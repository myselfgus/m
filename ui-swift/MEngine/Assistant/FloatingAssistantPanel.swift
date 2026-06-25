import SwiftUI

/// Conteúdo do agente conversacional flutuante — header + transcrição + entrada.
///
/// É o "miolo" compartilhado pelo ícone expansível (AssistantOrb, no dashboard) e pela
/// presença na menubar (MenuBarExtra). Renderiza-se sobre fundo transparente: a superfície
/// de Liquid Glass é provida por quem hospeda (o orb morfa o vidro; a menubar aplica vidro
/// próprio). Reutiliza `AssistantSession` (WebSocket) — não reimplementa transporte.
///
/// Substitui, em forma flutuante, o `AssistantChatView` lateral (inspector/sheet).
struct FloatingAssistantPanel: View {
    /// Contexto opcional de paciente (slug). `nil` = conversa geral persistente.
    var contextSlug: String? = nil
    /// Acionado pelo botão de colapsar (orb) ou fechar. `nil` = sem botão (menubar).
    var onCollapse: (() -> Void)? = nil

    @EnvironmentObject private var settings: AppSettings
    @StateObject private var session = AssistantSession.inert
    @State private var live: AssistantSession?
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    /// Sessão observada: a real (`live`) assim que conectada, senão um placeholder inerte.
    private var bound: AssistantSession { live ?? session }

    private var canSend: Bool {
        bound.connected && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            transcript
            Divider().opacity(0.5)
            inputBar
        }
        .task(id: settings.baseURL) { startSession() }
        .onDisappear { live?.disconnect() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(HOS.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text("Assistente").font(.hosTitle3).foregroundStyle(.primary)
                Text(contextSlug == nil ? "Sonnet 4.6 · contexto geral" : "contexto: \(contextSlug!)")
                    .font(.hosCaption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            StatusDot(connected: bound.connected)
            if let onCollapse {
                Button(action: onCollapse) {
                    Image(systemName: "chevron.down.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Recolher assistente")
                .accessibilityLabel("Recolher assistente")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - Transcrição

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if bound.messages.isEmpty { emptyState }
                    ForEach(bound.messages) { msg in
                        AssistantMessageBubble(message: msg).id(msg.id)
                    }
                    if bound.thinking { thinkingRow.id("thinking") }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
            .onChange(of: bound.messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: bound.thinking) { _, _ in scrollToBottom(proxy) }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 18)).foregroundStyle(.secondary)
            Text("Pergunte ao assistente sobre o paciente ou o pipeline.")
                .font(.hosFootnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
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
                .focused($inputFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .recessedField()
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
    }

    // MARK: - Lógica

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

// MARK: - Indicador de conexão compacto

private struct StatusDot: View {
    let connected: Bool
    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(connected ? HOS.complete : HOS.pending)
                .frame(width: 7, height: 7)
            Text(connected ? "Conectado" : "Conectando…")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

private extension AssistantSession {
    /// Placeholder inerte para satisfazer `@StateObject` antes da sessão real existir.
    static var inert: AssistantSession {
        AssistantSession(baseURL: URL(string: "http://invalid")!, apiKey: nil)
    }
}
