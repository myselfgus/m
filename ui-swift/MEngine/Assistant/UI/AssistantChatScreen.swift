import SwiftUI

// MARK: - AssistantChatScreen — conteúdo conversacional (janela flutuante + menubar).
// Streaming estilo claude.ai: texto fluindo, ferramentas como cards, raciocínio à parte,
// botão parar. Peça técnica HealthOS §10. healthos-design (tokens HOS, SF Symbols, PT-BR).

struct AssistantChatScreen: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var vm = ChatViewModel(transport: MessagesAPITransport(), agent: AgentSeeds.clinico)
    @State private var draft = ""
    @State private var hasKey = KeychainCredentialStore().hasAPIKey
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !hasKey { keyBanner }
            transcript
            Divider()
            composer
        }
        .background(.background)
        .onAppear { hasKey = KeychainCredentialStore().hasAPIKey }
    }

    // MARK: Header (marca + seletor de agente + estado)

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold)).foregroundStyle(HOS.blue)
            Picker("Agente", selection: $vm.selectedAgent) {
                ForEach(AgentSeeds.all) { agent in
                    Text(agent.name).tag(agent)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            Spacer(minLength: 8)
            Text(vm.selectedAgent.model.label).font(.hosCaption).foregroundStyle(.secondary)
            if vm.isStreaming { ProgressView().controlSize(.small) }
            if !vm.messages.isEmpty {
                Button { vm.clear() } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Limpar conversa")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var keyBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.horizontal").foregroundStyle(HOS.review)
            Text("Adicione sua chave da Anthropic em Ajustes para conversar.")
                .font(.hosFootnote).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(HOS.review.opacity(0.10))
    }

    // MARK: Transcrição

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if vm.messages.isEmpty && !vm.isStreaming { emptyState }
                    ForEach(vm.messages) { msg in
                        AssistantBubble(message: msg).id(msg.id)
                    }
                    if vm.isStreaming {
                        if !vm.streamingThinking.isEmpty { ThinkingView(text: vm.streamingThinking) }
                        ForEach(vm.activeTools) { ToolCard(call: $0) }
                        if !vm.streamingText.isEmpty {
                            AssistantBubble(message: ChatMessage(role: .assistant, text: vm.streamingText))
                                .id("streaming")
                        }
                    }
                    if let err = vm.errorText, !vm.isStreaming {
                        ErrorRow(text: err)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
            .onChange(of: vm.streamingText) { _, _ in scroll(proxy) }
            .onChange(of: vm.messages.count) { _, _ in scroll(proxy) }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 18)).foregroundStyle(.secondary)
            Text("Pergunte ao assistente sobre o paciente ou o pipeline.")
                .font(.hosFootnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
    }

    // MARK: Composer

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Mensagem ao assistente", text: $draft, axis: .vertical)
                .textFieldStyle(.plain).font(.hosBody).lineLimit(1...5)
                .focused($inputFocused)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .recessedField()
                .onSubmit(sendOrNothing)
                .disabled(!hasKey)
            if vm.isStreaming {
                Button { vm.stop() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 22)) }
                    .buttonStyle(.plain).foregroundStyle(HOS.error).help("Parar")
            } else {
                Button(action: sendOrNothing) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 22)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(canSend ? HOS.blue : Color.secondary)
                    .disabled(!canSend).help("Enviar")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var canSend: Bool {
        hasKey && vm.canSend && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendOrNothing() {
        guard canSend else { return }
        vm.send(draft); draft = ""
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.18)) {
            if vm.isStreaming && !vm.streamingText.isEmpty { proxy.scrollTo("streaming", anchor: .bottom) }
            else if let last = vm.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }
}

// MARK: - Subviews

private struct AssistantBubble: View {
    let message: ChatMessage
    var body: some View {
        switch message.role {
        case .user:
            HStack { Spacer(minLength: 32)
                Text(message.text).font(.hosBody).foregroundStyle(.primary)
                    .padding(.horizontal, 11).padding(.vertical, 8)
                    .background(HOS.blue.opacity(0.16), in: RoundedRectangle(cornerRadius: HOS.rLg, style: .continuous))
            }
        case .assistant, .system:
            HStack { MarkdownText(text: message.text).font(.hosBody)
                    .padding(.horizontal, 11).padding(.vertical, 8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: HOS.rLg, style: .continuous))
                Spacer(minLength: 32) }
        case .tool:
            ToolCard(call: ToolCallVM(id: message.id.uuidString, name: message.toolName ?? "tool", state: .done, summary: message.text))
        case .error:
            ErrorRow(text: message.text)
        }
    }
}

private struct ToolCard: View {
    let call: ToolCallVM
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: call.state == .running ? "gearshape.2" : "checkmark.seal")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(HOS.info)
            Text(call.name).font(.hosMono).foregroundStyle(HOS.info)
            if let s = call.summary, !s.isEmpty {
                Text(s).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            if call.state == .running { ProgressView().controlSize(.mini) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(HOS.info.opacity(0.10), in: Capsule())
    }
}

private struct ThinkingView: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "brain").font(.system(size: 10)).foregroundStyle(.secondary)
            Text(text).font(.hosFootnote).foregroundStyle(.secondary).lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: HOS.rMd, style: .continuous))
    }
}

private struct ErrorRow: View {
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(HOS.error)
            Text(text).font(.hosFootnote).foregroundStyle(HOS.error).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(HOS.error.opacity(0.10), in: RoundedRectangle(cornerRadius: HOS.rMd, style: .continuous))
    }
}

#if os(macOS)
// MARK: - Conteúdo do MenuBarExtra — abre a janela flutuante (persistente, não some).
struct AssistantMenuBar: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Abrir assistente") { openWindow(id: "assistant") }
            .keyboardShortcut("j", modifiers: .command)
    }
}
#endif
