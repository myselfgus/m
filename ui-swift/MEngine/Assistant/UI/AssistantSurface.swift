import SwiftUI

// MARK: - Superfície expansível do assistente (ícone → painel) com morph de Liquid Glass.
// Adaptada ao ChatViewModel (transporte B / Messages API direta). Skills: swiftui-liquid-glass,
// swiftui-patterns, swiftui-performance.

enum AgentSurfaceContext {
    case dashboard, menuBar
    var expandedSize: CGSize {
        switch self {
        case .dashboard: CGSize(width: 720, height: 620)
        case .menuBar:   CGSize(width: 430, height: 620)
        }
    }
    var collapsedSize: CGSize {
        switch self {
        case .dashboard: CGSize(width: 64, height: 64)
        case .menuBar:   CGSize(width: 64, height: 64)
        }
    }
}

struct ExpandableAgentSurface: View {
    @Binding var isExpanded: Bool
    let context: AgentSurfaceContext
    @State private var vm = ChatViewModel(transport: MessagesAPITransport(), agent: AgentSeeds.clinico)
    @Namespace private var glassNS

    var body: some View {
        GlassEffectContainerCompat {
            Group {
                if isExpanded {
                    AgentPanelView(vm: vm, isExpanded: $isExpanded, context: context)
                        .frame(width: context.expandedSize.width, height: context.expandedSize.height)
                        .regularGlass(cornerRadius: 28, interactive: true)
                        .glassMorphID("agent-surface", in: glassNS)
                        .transition(.scale(scale: 0.86, anchor: .bottomTrailing).combined(with: .opacity))
                } else {
                    LauncherButton(isStreaming: vm.isStreaming) {
                        withAnimation(.agentExpansion) { isExpanded = true }
                    }
                    .frame(width: context.collapsedSize.width, height: context.collapsedSize.height)
                    .regularGlass(cornerRadius: context.collapsedSize.width / 2, interactive: true)
                    .glassMorphID("agent-surface", in: glassNS)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
        }
        .animation(.agentExpansion, value: isExpanded)
    }
}

// MARK: - Compat: GlassEffectContainer + glassEffectID (macOS 26) com fallback.

struct GlassEffectContainerCompat<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26, iOS 26, *) {
            GlassEffectContainer { content }
        } else {
            content
        }
    }
}

extension View {
    @ViewBuilder
    func glassMorphID(_ id: String, in ns: Namespace.ID) -> some View {
        if #available(macOS 26, iOS 26, *) { glassEffectID(id, in: ns) } else { self }
    }
}

private struct LauncherButton: View {
    let isStreaming: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 26, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(HOS.blue)
                if isStreaming {
                    Circle().fill(HOS.complete).frame(width: 11, height: 11).offset(x: 6, y: -5)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Abrir assistente")
        .accessibilityLabel("Abrir assistente")
    }
}

// MARK: - Painel

struct AgentPanelView: View {
    @Bindable var vm: ChatViewModel
    @Binding var isExpanded: Bool
    let context: AgentSurfaceContext

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(vm: vm, isExpanded: $isExpanded, context: context)
            Divider().opacity(0.28)
            if !KeychainCredentialStore().hasAPIKey { keyBanner }
            MessageTimeline(vm: vm).frame(maxWidth: .infinity, maxHeight: .infinity)
            ComposerView(vm: vm).padding(14)
        }
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

private struct PanelHeader: View {
    @Bindable var vm: ChatViewModel
    @Binding var isExpanded: Bool
    let context: AgentSurfaceContext

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkle.magnifyingglass").font(.title3.weight(.semibold)).foregroundStyle(HOS.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Assistente").font(.headline)
                Text(vm.selectedAgent.model.displayName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !vm.tokenUsage.isEmpty {
                Text(vm.tokenUsage).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Picker("Agente", selection: $vm.selectedAgent) {
                ForEach(vm.agents) { Text($0.shortName).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu)
            .frame(maxWidth: context == .menuBar ? 120 : 170)
            if !vm.messages.isEmpty {
                Button { vm.resetConversation() } label: { Image(systemName: "plus.message") }
                    .buttonStyle(.borderless).help("Novo fio")
            }
            Button { withAnimation(.agentExpansion) { isExpanded = false } } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("Recolher").keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }
}

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
            if message.role == .user { Spacer(minLength: 40) }
            MarkdownText(text: message.text)
                .font(.body).textSelection(.enabled)
                .padding(14).frame(maxWidth: 560, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(message.role == .user ? HOS.blue.opacity(0.14) : Color.primary.opacity(0.055))
                }
            if message.role != .user { Spacer(minLength: 40) }
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

// MARK: - Presença na menubar (mesma superfície, sempre expandida)

#if os(macOS)
struct MenuBarAgentView: View {
    @State private var isExpanded = true
    var body: some View {
        ExpandableAgentSurface(isExpanded: $isExpanded, context: .menuBar)
            .padding(12)
            .frame(width: 454, height: 640)
            .onAppear { isExpanded = true }
    }
}
#endif
