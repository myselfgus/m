import SwiftUI

// MARK: - Coluna do assistente (inspector colapsável no dashboard).
// Sem orb, sem morph, sem menubar: uma coluna lateral que recolhe (escondida) ↔ expande (chat).
// Adaptada ao ChatViewModel (transporte B / Messages API direta). Skills: swiftui-patterns.

/// Entrada pública: a conversa completa do assistente, pronta para viver num `.inspector`
/// (macOS) ou numa `.sheet` (iOS). Dona do seu próprio `ChatViewModel`.
struct AssistantColumn: View {
    @State private var vm = ChatViewModel(transport: MessagesAPITransport(), agent: AgentSeeds.clinico)

    var body: some View {
        VStack(spacing: 0) {
            AssistantHeader(vm: vm)
            Divider().opacity(0.28)
            if !KeychainCredentialStore().hasAPIKey { keyBanner }
            MessageTimeline(vm: vm).frame(maxWidth: .infinity, maxHeight: .infinity)
            ComposerView(vm: vm).padding(14)
        }
        .background(.bar)
    }

    private var keyBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.horizontal").foregroundStyle(HOS.review)
            Text("Adicione sua chave da Anthropic em Ajustes para conversar.")
                .font(.hosFootnote).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 8).background(HOS.review.opacity(0.10))
    }
}

// MARK: - Cabeçalho

private struct AssistantHeader: View {
    @Bindable var vm: ChatViewModel

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.title3.weight(.semibold)).foregroundStyle(HOS.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Assistente").font(.headline)
                    Text(vm.selectedAgent.model.displayName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !vm.tokenUsage.isEmpty {
                    Text(vm.tokenUsage).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                if !vm.messages.isEmpty {
                    Button { vm.resetConversation() } label: { Image(systemName: "plus.message") }
                        .buttonStyle(.borderless).help("Novo fio")
                }
            }
            HStack {
                Picker("Agente", selection: $vm.selectedAgent) {
                    ForEach(vm.agents) { Text($0.shortName).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu)
                Spacer()
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }
}

// MARK: - Timeline

private struct MessageTimeline: View {
    @Bindable var vm: ChatViewModel
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if vm.messages.isEmpty && !vm.isStreaming { emptyState }
                    ForEach(vm.messages) { MessageBubble(message: $0).id($0.id) }
                    ForEach(vm.activeTools) { ToolCallCard(call: $0) }
                    if vm.isStreaming, !vm.streamingText.isEmpty {
                        MessageBubble(message: ChatMessage(role: .assistant, text: vm.streamingText)).id("streaming")
                    }
                    if let err = vm.errorText, !vm.isStreaming { ErrorRow(text: err) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .onChange(of: vm.messages.count) { _, _ in bottom(proxy) }
            .onChange(of: vm.streamingText) { _, _ in bottom(proxy) }
        }
    }
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 18)).foregroundStyle(.secondary)
            Text("Pergunte ao assistente sobre o paciente ou o pipeline.")
                .font(.hosFootnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func bottom(_ p: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.18)) { p.scrollTo("bottom", anchor: .bottom) }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 24) }
            MarkdownText(text: message.text)
                .font(.body).textSelection(.enabled)
                .padding(14).frame(maxWidth: 520, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(message.role == .user ? HOS.blue.opacity(0.14) : Color.primary.opacity(0.055))
                }
            if message.role != .user { Spacer(minLength: 24) }
        }
    }
}

private struct ToolCallCard: View {
    let call: ToolCallVM
    var body: some View {
        HStack(spacing: 10) {
            if call.state == .running { ProgressView().controlSize(.small) }
            else { Image(systemName: "checkmark.circle.fill").foregroundStyle(HOS.complete) }
            VStack(alignment: .leading, spacing: 2) {
                Text(call.name).font(.caption.weight(.semibold))
                Text(call.summary ?? (call.state == .running ? "executando" : "concluído"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(HOS.info.opacity(0.10)) }
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

// MARK: - Composer

struct ComposerView: View {
    @Bindable var vm: ChatViewModel
    @FocusState private var focused: Bool
    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Mensagem", text: $vm.composerText, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...5).focused($focused)
                .padding(.horizontal, 13).padding(.vertical, 11)
                .background { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.055)) }
                .onSubmit { vm.submitComposer() }
            Button {
                vm.isStreaming ? vm.stopStreaming() : vm.submitComposer()
            } label: {
                Image(systemName: vm.isStreaming ? "stop.fill" : "arrow.up")
                    .font(.system(size: 14, weight: .bold)).frame(width: 34, height: 34)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.circle).tint(HOS.blue)
            .disabled(!vm.isStreaming && vm.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help(vm.isStreaming ? "Parar" : "Enviar")
        }
        .onAppear { focused = true }
    }
}
