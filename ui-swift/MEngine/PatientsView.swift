import SwiftUI
import UniformTypeIdentifiers

/// Detalhe do paciente (HealthOS — Pacientes): cabeçalho com nome de exibição +
/// capsules, consultas agrupadas em C1/C2/C3 (cada uma com sua data) listando os
/// documentos. Tocar num documento abre o editor de Markdown. O perfil
/// (nome completo, CPF, telefone, idade) é editável via folha.
struct PatientDetailView: View {
    @EnvironmentObject private var settings: AppSettings
    let slug: String
    /// Chamado quando o paciente é apagado (para a sidebar limpar a navegação
    /// e recarregar a listagem).
    var onDeleted: () -> Void = {}

    @State private var profile: PatientProfile?
    @State private var consultations: [Consultation] = []
    @State private var dossier: PatientInfo?
    @State private var loading = false
    @State private var errorText: String?
    @State private var showProfileEditor = false
    /// Aba ativa do detalhe (mock healthdrive: Chat · Arquivos · Pipeline; +Sessões no iOS).
    @State private var tab: DetailTab = .pipeline
    /// Documento selecionado na aba Arquivos (split macOS). nil = nenhum.
    @State private var selectedDoc: DocRoute?

    /// Abas do detalhe do paciente (segmented).
    enum DetailTab: String, CaseIterable, Identifiable {
        case chat, arquivos, pipeline
        #if os(iOS)
        case sessoes
        #endif
        var id: String { rawValue }
        var label: String {
            switch self {
            case .chat: return "Chat"
            case .arquivos: return "Arquivos"
            case .pipeline: return "Pipeline"
            #if os(iOS)
            case .sessoes: return "Sessões"
            #endif
            }
        }
        var icon: String {
            switch self {
            case .chat: return "message"
            case .arquivos: return "folder"
            case .pipeline: return "arrow.triangle.branch"
            #if os(iOS)
            case .sessoes: return "calendar"
            #endif
            }
        }
    }

    // Criação de consulta / documento.
    @State private var showNewConsultation = false
    /// Consulta-alvo da folha "Novo documento" (nil = folha fechada).
    @State private var docTarget: Consultation?
    /// Consulta-alvo do importador de arquivo (nil = importador fechado).
    @State private var importTarget: Consultation?

    // Exclusão (paciente / consulta / documento).
    @Environment(\.dismiss) private var dismiss
    /// Confirmação de exclusão do paciente (toolbar/menu de detalhe).
    @State private var confirmDeletePatient = false
    /// Consulta pendente de confirmação de exclusão (nil = sem diálogo).
    @State private var consultationToDelete: Consultation?
    /// Documento pendente de confirmação de exclusão (nil = sem diálogo).
    @State private var documentToDelete: DocRoute?
    /// Operação destrutiva em andamento (mostra progresso e desabilita ações).
    @State private var deleting = false
    /// Erro de uma operação destrutiva (exibido em alerta).
    @State private var deleteError: String?

    /// Rota de documento dentro de uma consulta.
    struct DocRoute: Hashable, Identifiable {
        let consultationId: String
        let name: String
        var id: String { "\(consultationId)/\(name)" }
    }

    /// Overlay de progresso de exclusão (extraído do `body` p/ aliviar o type-checker).
    @ViewBuilder
    private var deletingOverlay: some View {
        if deleting {
            ZStack {
                Color.black.opacity(0.06).ignoresSafeArea()
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Apagando…").font(.hosFootnote).foregroundStyle(.secondary)
                }
                .padding(20)
                .raisedCard()
            }
            .transition(.opacity)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                segmentedTabs
                Divider()
                tabContent
            }
            .background(.background)
            .overlay { deletingOverlay }
            .navigationDestination(for: DocRoute.self) { route in
                DocumentEditorView(slug: slug, consultationId: route.consultationId, name: route.name)
            }
        }
        .navigationTitle(profile?.displayName ?? slug)
        .task { await load() }
        .sheet(isPresented: $showProfileEditor) {
            if let profile {
                ProfileEditorView(profile: profile) { updated in
                    self.profile = updated
                }
            }
        }
        .sheet(isPresented: $showNewConsultation) {
            NewConsultationView(slug: slug) { _ in
                Task { await load() }
            }
        }
        .sheet(item: $docTarget) { consultation in
            NewDocumentView(slug: slug, consultationId: consultation.id) {
                Task { await load() }
            }
        }
        .fileImporter(isPresented: importerBinding, allowedContentTypes: importTypes) { result in
            if case let .success(url) = result, let target = importTarget {
                Task { await uploadFile(url, to: target) }
            }
            importTarget = nil
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { showNewConsultation = true } label: {
                        Label("Nova consulta", systemImage: "calendar.badge.plus")
                    }
                    Button { showProfileEditor = true } label: {
                        Label("Editar perfil", systemImage: "person.text.rectangle")
                    }
                    .disabled(profile == nil)
                    Divider()
                    Button(role: .destructive) {
                        confirmDeletePatient = true
                    } label: {
                        Label("Apagar paciente", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(deleting)
            }
        }
        .confirmationDialog(
            "Apagar \(profile?.displayName ?? slug)? As consultas vão para a lixeira.",
            isPresented: $confirmDeletePatient,
            titleVisibility: .visible
        ) {
            Button("Apagar paciente", role: .destructive) {
                Task { await deletePatient() }
            }
            Button("Cancelar", role: .cancel) {}
        }
        .confirmationDialog(
            consultationToDelete.map { "Apagar a consulta \($0.id)? Os documentos vão para a lixeira." } ?? "",
            isPresented: deleteConsultationBinding,
            titleVisibility: .visible,
            presenting: consultationToDelete
        ) { consultation in
            Button("Apagar consulta", role: .destructive) {
                Task { await deleteConsultation(consultation) }
            }
            Button("Cancelar", role: .cancel) {}
        }
        .confirmationDialog(
            documentToDelete.map { "Apagar o documento \($0.name)?" } ?? "",
            isPresented: deleteDocumentBinding,
            titleVisibility: .visible,
            presenting: documentToDelete
        ) { route in
            Button("Apagar documento", role: .destructive) {
                Task { await deleteDocument(route) }
            }
            Button("Cancelar", role: .cancel) {}
        }
        .alert("Não foi possível apagar", isPresented: deleteErrorBinding) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    /// Binding booleano para o alerta de erro de exclusão.
    private var deleteErrorBinding: Binding<Bool> {
        Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })
    }

    /// Binding booleano para o diálogo de exclusão de consulta.
    private var deleteConsultationBinding: Binding<Bool> {
        Binding(get: { consultationToDelete != nil }, set: { if !$0 { consultationToDelete = nil } })
    }

    /// Binding booleano para o diálogo de exclusão de documento.
    private var deleteDocumentBinding: Binding<Bool> {
        Binding(get: { documentToDelete != nil }, set: { if !$0 { documentToDelete = nil } })
    }

    /// Binding booleano derivado de `importTarget` para o `.fileImporter`.
    private var importerBinding: Binding<Bool> {
        Binding(get: { importTarget != nil }, set: { if !$0 { importTarget = nil } })
    }

    private var importTypes: [UTType] {
        [.plainText, .text, .pdf, .rtf, .audio, .movie, .image, .data]
    }

    // MARK: - Cabeçalho

    /// Legenda do paciente: idade (quando houver) + nº de consultas. Sexo não é
    /// exposto pelo backend, então não é inventado.
    private var subtitle: String {
        var parts: [String] = []
        if let age = profile?.age { parts.append("\(age) anos") }
        parts.append(consultations.count == 1 ? "1 consulta" : "\(consultations.count) consultas")
        return parts.joined(separator: " · ")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            PatientAvatar(name: profile?.displayName ?? slug, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile?.displayName ?? slug).font(.hosTitle1).foregroundStyle(.primary)
                Text(subtitle).font(.hosCallout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button { showNewConsultation = true } label: {
                ActionLabel("Nova consulta", systemImage: "calendar.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(HOS.blue)
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Atualizar")
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    /// Controle segmentado de abas (Chat · Arquivos · Pipeline [· Sessões]).
    private var segmentedTabs: some View {
        Picker("", selection: $tab) {
            ForEach(DetailTab.allCases) { t in
                Label(t.label, systemImage: t.icon).tag(t)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }

    // MARK: - Conteúdo por aba

    @ViewBuilder
    private var tabContent: some View {
        if loading && consultations.isEmpty && profile == nil {
            Spacer(); ProgressView("Carregando…"); Spacer()
        } else if let errorText, consultations.isEmpty {
            Spacer()
            ContentUnavailableView("Erro", systemImage: "exclamationmark.triangle", description: Text(errorText))
            Spacer()
        } else {
            switch tab {
            case .chat: chatTab
            case .arquivos: filesTab
            case .pipeline: pipelineTab
            #if os(iOS)
            case .sessoes: sessoesTab
            #endif
            }
        }
    }

    // MARK: Aba Chat (assistente clínico primado com o dossiê real)

    private var chatTab: some View {
        AssistantColumn(patient: PatientChatContext(
            slug: slug,
            displayName: profile?.displayName ?? slug,
            dossier: dossierPrimer))
        .id(slug)   // recria a conversa ao trocar de paciente
    }

    /// String do dossiê real (info.json) injetada no agente. nil se nada disponível.
    private var dossierPrimer: String? {
        guard let d = dossier else { return nil }
        var lines: [String] = []
        if let s = d.summary, !s.isEmpty { lines.append("Resumo: \(s)") }
        if !d.icdCodes.isEmpty { lines.append("CIDs: \(d.icdCodes.joined(separator: ", "))") }
        if !d.medications.isEmpty { lines.append("Medicações: \(d.medications.joined(separator: ", "))") }
        if !d.topics.isEmpty { lines.append("Tópicos: \(d.topics.joined(separator: ", "))") }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: Aba Arquivos (árvore de consultas → documentos + viewer)

    @ViewBuilder
    private var filesTab: some View {
        if consultations.allSatisfy({ $0.documents.isEmpty }) {
            emptyFiles
        } else {
            #if os(macOS)
            HStack(spacing: 0) {
                fileTree.frame(width: 260)
                Divider()
                fileViewer.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            #else
            ScrollView { fileTree.padding(.vertical, 8) }
            #endif
        }
    }

    private var fileTree: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(consultations) { c in
                    if !c.documents.isEmpty {
                        Text(c.id + (c.date.map { " · \($0)" } ?? ""))
                            .font(.hosSubhead).foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
                        ForEach(c.documents, id: \.self) { name in
                            fileTreeRow(consultation: c, name: name)
                        }
                    }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func fileTreeRow(consultation c: Consultation, name: String) -> some View {
        let route = DocRoute(consultationId: c.id, name: name)
        #if os(macOS)
        Button { selectedDoc = route } label: {
            fileTreeLabel(name: name, selected: selectedDoc == route)
        }
        .buttonStyle(.plain)
        .contextMenu { deleteDocButton(route) }
        #else
        NavigationLink(value: route) {
            fileTreeLabel(name: name, selected: false)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) { deleteDocButton(route) }
        #endif
    }

    private func fileTreeLabel(name: String, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: DocMeta.icon(for: name))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(HOS.tint(forStage: name))
                .frame(width: 16)
            Text(name).font(.hosCallout).foregroundStyle(.primary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(selected ? HOS.blue.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: HOS.rSm, style: .continuous))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func deleteDocButton(_ route: DocRoute) -> some View {
        Button(role: .destructive) { documentToDelete = route } label: {
            Label("Apagar documento", systemImage: "trash")
        }
    }

    #if os(macOS)
    @ViewBuilder
    private var fileViewer: some View {
        if let route = selectedDoc {
            DocumentEditorView(slug: slug, consultationId: route.consultationId, name: route.name)
                .id(route.id)
        } else {
            ContentUnavailableView("Selecione um documento", systemImage: "doc.text",
                                   description: Text("Escolha um arquivo do dossiê à esquerda."))
        }
    }
    #endif

    private var emptyFiles: some View {
        VStack { Spacer()
            ContentUnavailableView {
                Label("Sem arquivos", systemImage: "folder")
            } description: {
                Text("Nenhum documento gerado para este paciente ainda. Rode o pipeline numa consulta.")
            }
            Spacer()
        }
    }

    // MARK: Aba Pipeline (session cards + stage chips + run controls)

    @ViewBuilder
    private var pipelineTab: some View {
        if consultations.isEmpty {
            emptyConsultations
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(consultations) { c in sessionCard(c) }
                }
                .padding(20)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func sessionCard(_ consultation: Consultation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Consulta \(consultation.id)").font(.hosTitle3)
                    Text((consultation.date ?? "—") + " · pt-BR")
                        .font(.hosMono).foregroundStyle(.secondary)
                }
                Spacer()
                sessionStatusPill(consultation)
            }
            StageChipRow(documents: consultation.documents)
            Divider().padding(.vertical, 2)
            consultationActions(consultation)
            PipelineControl(slug: slug, consultation: consultation) {
                Task { await load() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .healthCard()
    }

    /// Estado da consulta derivado dos documentos: gem_complete / needs_review / sem análise.
    @ViewBuilder
    private func sessionStatusPill(_ c: Consultation) -> some View {
        let kinds = HomeView.docKinds(c.documents)
        if kinds.contains("GEM") {
            StatusPill(text: "gem_complete", color: HOS.complete, systemImage: "checkmark.seal.fill")
        } else if !kinds.isEmpty {
            StatusPill(text: "needs_review", color: HOS.review, systemImage: "exclamationmark.triangle.fill")
        } else {
            StatusPill(text: "sem análise", color: HOS.pending)
        }
    }

    private var emptyConsultations: some View {
        VStack { Spacer()
            ContentUnavailableView {
                Label("Sem consultas", systemImage: "calendar.badge.exclamationmark")
            } description: {
                Text("Nenhuma consulta registrada para este paciente.")
            } actions: {
                Button { showNewConsultation = true } label: {
                    ActionLabel("Nova consulta", systemImage: "calendar.badge.plus")
                }
                .buttonStyle(.borderedProminent).tint(HOS.blue)
            }
            Spacer()
        }
    }

    #if os(iOS)
    // MARK: Aba Sessões (histórico de consultas — sem player; backend não faz streaming)

    @ViewBuilder
    private var sessoesTab: some View {
        if consultations.isEmpty {
            emptyConsultations
        } else {
            ScrollView {
                VStack(spacing: HOS.s2) {
                    ForEach(consultations) { c in
                        GlassRow(title: "Consulta \(c.id)", subtitle: c.date) {
                            Text(c.id)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(HOS.blue)
                                .frame(width: 34, height: 34)
                                .background(HOS.blue.opacity(0.12), in: Circle())
                        } trailing: {
                            sessionStatusPill(c)
                        }
                    }
                }
                .padding(16)
            }
        }
    }
    #endif

    /// Ações por consulta: novo documento, importar arquivo e menu (•••) com
    /// "Apagar consulta".
    private func consultationActions(_ consultation: Consultation) -> some View {
        HStack(spacing: 10) {
            Button { docTarget = consultation } label: {
                ActionLabel("Novo documento", systemImage: "doc.badge.plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button { importTarget = consultation } label: {
                ActionLabel("Importar arquivo", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Spacer()
            Menu {
                Button { docTarget = consultation } label: {
                    Label("Novo documento", systemImage: "doc.badge.plus")
                }
                Button { importTarget = consultation } label: {
                    Label("Importar arquivo", systemImage: "square.and.arrow.down")
                }
                Divider()
                Button(role: .destructive) {
                    consultationToDelete = consultation
                } label: {
                    Label("Apagar consulta", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("Ações da consulta \(consultation.id)")
            .disabled(deleting)
        }
    }

    private func load() async {
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            let client = try settings.makeClient()
            async let cons = client.fetchConsultations(slug: slug)
            async let prof = try? client.fetchProfile(slug: slug)
            async let info = try? client.patientInfo(patientId: slug)
            consultations = try await cons
            profile = await prof
            dossier = await info
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Apaga o paciente (soft-delete → lixeira) e sai do detalhe.
    private func deletePatient() async {
        deleting = true
        deleteError = nil
        defer { deleting = false }
        do {
            try await settings.makeClient().deletePatient(slug: slug)
            onDeleted()
            dismiss()
        } catch {
            deleteError = error.localizedDescription
        }
    }

    /// Apaga uma consulta e recarrega a lista.
    private func deleteConsultation(_ consultation: Consultation) async {
        deleting = true
        deleteError = nil
        defer { deleting = false }
        do {
            try await settings.makeClient()
                .deleteConsultation(slug: slug, consultationId: consultation.id)
            await load()
        } catch {
            deleteError = error.localizedDescription
        }
    }

    /// Apaga um documento de uma consulta e recarrega a lista.
    private func deleteDocument(_ route: DocRoute) async {
        deleting = true
        deleteError = nil
        defer { deleting = false }
        do {
            try await settings.makeClient()
                .deleteDocument(slug: slug, consultationId: route.consultationId, name: route.name)
            await load()
        } catch {
            deleteError = error.localizedDescription
        }
    }

    /// Sobe um arquivo arbitrário para uma consulta e recarrega a lista.
    private func uploadFile(_ url: URL, to consultation: Consultation) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            _ = try await settings.makeClient()
                .uploadFile(slug: slug, consultationId: consultation.id, fileURL: url)
            await load()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Metadados de documento (ícone / título / rótulo curto por nome de arquivo)

/// Deriva apresentação de um documento clínico a partir do nome do arquivo.
enum DocMeta {
    static func icon(for name: String) -> String {
        let k = name.lowercased()
        if k.contains("birp") { return "bolt.heart.fill" }
        if k.contains("gem") { return "point.3.connected.trianglepath.dotted" }
        if k.contains("vdlp") || k.contains("dimensional") { return "chart.dots.scatter" }
        if k.contains("asl") { return "brain.head.profile" }
        if k.contains("soap_long") { return "chart.line.uptrend.xyaxis" }
        if k.contains("soap") { return "doc.text.fill" }
        if k.contains("transcri") { return "waveform" }
        if k.contains(".json") { return "curlybraces" }
        return "doc"
    }

    static func title(for name: String) -> String {
        let k = name.lowercased()
        if k.contains("birp") { return "Nota BIRP" }
        if k.contains("gem") { return "GEM — grafo" }
        if k.contains("vdlp") || k.contains("dimensional") { return "VDLP — dimensional" }
        if k.contains("asl") { return "ASL — linguística" }
        if k.contains("soap_long") { return "SOAP — Seguimento" }
        if k.contains("soap") { return "SOAP — Sumário" }
        if k.contains("transcri") { return "Transcrição" }
        return name
    }

    static func kind(for name: String) -> String {
        let k = name.lowercased()
        if k.contains("birp") { return "BIRP" }
        if k.contains("gem") { return "GEM" }
        if k.contains("vdlp") || k.contains("dimensional") { return "VDLP" }
        if k.contains("asl") { return "ASL" }
        if k.contains("soap_long") { return "Seguimento" }
        if k.contains("soap") { return "Sumário" }
        if k.contains("transcri") { return "STT" }
        return "doc"
    }
}

// MARK: - Linha de stage chips (presença derivada dos documentos)

/// Tira de pílulas de estágio (STT · ASL · VDLP · GEM · BIRP) — cada uma "done"
/// (tint cheio + ✓) quando o artefato existe nos documentos, ou apagada quando
/// ausente. Presença é derivada dos nomes de arquivos reais — nunca inventada.
struct StageChipRow: View {
    let documents: [String]

    private static let stages: [(key: String, label: String)] = [
        ("transcri", "STT"), ("asl", "ASL"), ("vdlp", "VDLP"), ("gem", "GEM"), ("birp", "BIRP"),
    ]

    private func present(_ key: String) -> Bool {
        let blob = documents.joined(separator: " ").lowercased()
        if key == "vdlp" { return blob.contains("vdlp") || blob.contains("dimensional") }
        return blob.contains(key)
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Self.stages, id: \.key) { stage in
                let on = present(stage.key)
                let tint = HOS.tint(forStage: stage.key == "transcri" ? "stt" : stage.key)
                HStack(spacing: 4) {
                    Text(stage.label).font(.system(size: 11, weight: .bold))
                    Image(systemName: on ? "checkmark" : "minus")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(on ? tint : Color.secondary.opacity(0.55))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(on ? tint.opacity(0.13) : HOS.tileFill(),
                            in: RoundedRectangle(cornerRadius: HOS.rMd, style: .continuous))
            }
        }
    }
}

/// Chips em fluxo (wrap) para tags/CID/medicamentos/tópicos.
struct FlowChips: View {
    let items: [String]
    var color: Color
    var symbol: String

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                StatusPill(text: it, color: color, systemImage: symbol)
            }
        }
    }
}

// MARK: - Controle de pipeline por consulta

/// Linha de disparo de stages do pipeline para uma consulta específica.
/// Carrega os stages disponíveis (`GET /stages`, com fallback estático),
/// permite escolher o modelo (cc / opus / sonnet, padrão cc) e dispara cada
/// stage via `POST /jobs/{stage}`, acompanhando o job por polling (~2s) e
/// exibindo o estado (na fila / processando / completo / erro) com StatusPill.
struct PipelineControl: View {
    @EnvironmentObject private var settings: AppSettings
    let slug: String
    let consultation: Consultation
    /// Chamado quando um stage termina com sucesso (para recarregar documentos).
    var onStageComplete: () -> Void = {}

    /// Modelos oferecidos para os stages (rótulo curto → valor da API).
    enum StageModel: String, CaseIterable, Identifiable {
        case cc, opus, sonnet
        var id: String { rawValue }
        var apiValue: String { rawValue }
        var label: String {
            switch self {
            case .cc: return "Claude Code"
            case .opus: return "Opus"
            case .sonnet: return "Sonnet"
            }
        }
    }

    /// Estado de execução de um stage (chave → fase atual).
    enum Phase: Equatable { case idle, queued, running, done, failed }

    /// Stages-padrão usados enquanto `GET /stages` não responde (ou falha).
    private static let fallbackStages: [StageInfo] = [
        .init(key: "transcribe", label: "Transcrição"),
        .init(key: "normalize", label: "Normalização"),
        .init(key: "asl", label: "ASL"),
        .init(key: "dimensional", label: "VDLP"),
        .init(key: "gem", label: "GEM"),
        .init(key: "birp", label: "BIRP"),
        .init(key: "soap_trajetorial", label: "SOAP trajetorial"),
        .init(key: "soap_longitudinal", label: "SOAP longitudinal"),
        .init(key: "pipeline", label: "Pipeline completo"),
    ]

    @State private var stages: [StageInfo] = []
    @State private var model: StageModel = .cc
    @State private var phases: [String: Phase] = [:]
    @State private var errors: [String: String] = [:]
    @State private var loadingStages = false

    private var date: String { consultation.date ?? consultation.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label("Pipeline", systemImage: "wand.and.stars")
                    .font(.hosHeadline).foregroundStyle(HOS.stProc)
                Spacer()
                Picker("Modelo", selection: $model) {
                    ForEach(StageModel.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 140)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(displayStages) { stage in
                        stageButton(stage)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .task { await loadStages() }
    }

    private var displayStages: [StageInfo] {
        stages.isEmpty ? Self.fallbackStages : stages
    }

    @ViewBuilder
    private func stageButton(_ stage: StageInfo) -> some View {
        let phase = phases[stage.key] ?? .idle
        let tint = HOS.tint(forStage: stage.key)
        VStack(spacing: 4) {
            Button {
                Task { await runStage(stage.key) }
            } label: {
                HStack(spacing: 5) {
                    if phase == .queued || phase == .running {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: phaseSymbol(phase, fallback: stageSymbol(stage.key)))
                            .font(.system(size: 11, weight: .semibold))
                    }
                    #if os(macOS)
                    Text(stage.label).font(.hosCaption)
                    #endif
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(phaseTint(phase, base: tint))
            .accessibilityLabel(stage.label)
            .disabled(phase == .queued || phase == .running)

            phasePill(stage.key, phase: phase)
        }
    }

    @ViewBuilder
    private func phasePill(_ key: String, phase: Phase) -> some View {
        switch phase {
        case .idle:
            EmptyView()
        case .queued:
            StatusPill(text: "na fila", color: HOS.queued, systemImage: "clock")
        case .running:
            StatusPill(text: "processando", color: HOS.running, systemImage: "gearshape")
        case .done:
            StatusPill(text: "completo", color: HOS.complete, systemImage: "checkmark.seal.fill")
        case .failed:
            StatusPill(text: "erro", color: HOS.error, systemImage: "xmark.octagon.fill")
                .help(errors[key] ?? "Falha no stage.")
        }
    }

    private func phaseSymbol(_ phase: Phase, fallback: String) -> String {
        switch phase {
        case .done: return "checkmark"
        case .failed: return "exclamationmark.triangle"
        default: return fallback
        }
    }

    private func phaseTint(_ phase: Phase, base: Color) -> Color {
        switch phase {
        case .done: return HOS.complete
        case .failed: return HOS.error
        case .queued, .running: return HOS.running
        case .idle: return base
        }
    }

    private func stageSymbol(_ key: String) -> String {
        let k = key.lowercased()
        if k == "pipeline" { return "play.fill" }
        if k.contains("transcri") { return "waveform" }
        if k.contains("normalize") { return "text.badge.checkmark" }
        if k.contains("asl") { return "brain.head.profile" }
        if k.contains("dimensional") || k.contains("vdlp") { return "chart.dots.scatter" }
        if k.contains("gem") { return "point.3.connected.trianglepath.dotted" }
        if k.contains("birp") { return "bolt.heart.fill" }
        if k.contains("soap_long") { return "chart.line.uptrend.xyaxis" }
        if k.contains("soap") { return "doc.text.fill" }
        return "circle"
    }

    private func loadStages() async {
        guard stages.isEmpty, !loadingStages else { return }
        loadingStages = true
        defer { loadingStages = false }
        // Falha silenciosa: cai no fallback estático se /stages não existir ainda.
        if let fetched = try? await settings.makeClient().fetchStages(), !fetched.isEmpty {
            stages = fetched
        }
    }

    private func runStage(_ stage: String) async {
        phases[stage] = .queued
        errors[stage] = nil
        do {
            let client = try settings.makeClient()
            let job = try await client.enqueueStage(stage, slug: slug, date: date,
                                                    model: model.apiValue, force: false)
            try await poll(client: client, jobId: job.jobId, stage: stage)
        } catch {
            phases[stage] = .failed
            errors[stage] = error.localizedDescription
        }
    }

    /// Faz polling do job (~2s) até ficar pronto; atualiza a fase e, em sucesso,
    /// notifica o pai para recarregar os documentos.
    private func poll(client: APIClient, jobId: String, stage: String) async throws {
        while true {
            let st = try await client.jobStatus(jobId)
            phases[stage] = st.ready ? phases[stage] : .running
            if st.ready {
                if st.successful == true {
                    phases[stage] = .done
                    onStageComplete()
                } else {
                    phases[stage] = .failed
                    errors[stage] = st.error ?? "Job falhou."
                }
                return
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
}

// MARK: - Editor de documento clínico (Markdown editável)

/// Abre um documento Markdown de uma consulta, permite alternar entre
/// pré-visualização renderizada e edição (TextEditor) e salvar via PUT.
struct DocumentEditorView: View {
    @EnvironmentObject private var settings: AppSettings
    let slug: String
    let consultationId: String
    let name: String

    @State private var content = ""
    @State private var original = ""
    @State private var loading = true
    @State private var saving = false
    @State private var editing = false
    @State private var errorText: String?
    @State private var saveMessage: String?

    private var isDirty: Bool { content != original }

    var body: some View {
        Group {
            if loading {
                ProgressView().padding(40)
            } else if let errorText, content.isEmpty {
                ContentUnavailableView("Erro", systemImage: "exclamationmark.triangle", description: Text(errorText))
            } else {
                editorBody
            }
        }
        .background(.background)
        .navigationTitle(name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation { editing.toggle() }
                } label: {
                    ActionLabel(editing ? "Pré-visualizar" : "Editar",
                                systemImage: editing ? "eye" : "square.and.pencil")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await save() }
                } label: {
                    if saving { ProgressView().controlSize(.small) }
                    else { ActionLabel("Salvar", systemImage: "tray.and.arrow.down.fill") }
                }
                .disabled(!isDirty || saving)
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var editorBody: some View {
        VStack(spacing: 0) {
            if let saveMessage {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text(saveMessage).font(.hosFootnote)
                    Spacer()
                }
                .foregroundStyle(HOS.complete)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
            } else if let errorText {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(errorText).font(.hosFootnote)
                    Spacer()
                }
                .foregroundStyle(HOS.error)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
            }

            if editing {
                TextEditor(text: $content)
                    .font(.hosMono)
                    .scrollContentBackground(.hidden)
                    .padding(16)
                    .recessedField(cornerRadius: HOS.rXl)
                    .padding(24)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    MarkdownText(text: content)
                        .padding(24)
                        .frame(maxWidth: 820, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func load() async {
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            let text = try await settings.makeClient()
                .fetchDocument(slug: slug, consultationId: consultationId, name: name)
            content = text
            original = text
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func save() async {
        saving = true
        errorText = nil
        saveMessage = nil
        defer { saving = false }
        do {
            let bytes = try await settings.makeClient()
                .saveDocument(slug: slug, consultationId: consultationId, name: name, content: content)
            original = content
            saveMessage = "Salvo · \(bytes) bytes"
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Editor de perfil

/// Folha de edição do perfil do paciente: nome de exibição, nome completo, CPF,
/// telefone e idade. Salva via PUT /patients/{slug}/profile.
struct ProfileEditorView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State var profile: PatientProfile
    let onSaved: (PatientProfile) -> Void

    @State private var ageText = ""
    @State private var saving = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader("Editar perfil", systemImage: "person.text.rectangle.fill") {
                Text(profile.slug).font(.hosMono).foregroundStyle(.secondary)
            }

            field("NOME DE EXIBIÇÃO", text: $profile.displayName)
            field("NOME COMPLETO", text: optionalBinding(\.fullName))
            field("CPF", text: optionalBinding(\.cpf), keyboard: .numberPad, mono: true)
            field("TELEFONE", text: optionalBinding(\.phone), keyboard: .phonePad)

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Idade")
                TextField("anos", text: $ageText)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
            }

            if let errorText {
                Text(errorText).font(.hosFootnote).foregroundStyle(HOS.error)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
            HStack {
                Button { dismiss() } label: {
                    ActionLabel("Cancelar", systemImage: "xmark")
                }
                Spacer()
                Button {
                    Task { await save() }
                } label: {
                    if saving { ProgressView().controlSize(.small) }
                    else { ActionLabel("Salvar", systemImage: "tray.and.arrow.down.fill") }
                }
                .buttonStyle(.borderedProminent)
                .tint(HOS.blue)
                .disabled(saving)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 420)
        #endif
        .onAppear { ageText = profile.age.map(String.init) ?? "" }
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, keyboard: KeyboardKind = .default, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(label)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(mono ? .hosMono : .hosBody)
                #if os(iOS)
                .keyboardType(keyboard.uiKit)
                .textInputAutocapitalization(label == "CPF" ? .never : .words)
                .autocorrectionDisabled(label == "CPF")
                #endif
        }
    }

    /// Binding para um campo opcional de String (trata nil como "").
    private func optionalBinding(_ keyPath: WritableKeyPath<PatientProfile, String?>) -> Binding<String> {
        Binding(
            get: { profile[keyPath: keyPath] ?? "" },
            set: { profile[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private func save() async {
        saving = true
        errorText = nil
        defer { saving = false }
        profile.age = Int(ageText.trimmingCharacters(in: .whitespaces))
        do {
            let updated = try await settings.makeClient().updateProfile(slug: profile.slug, profile: profile)
            onSaved(updated)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// Abstração de teclado multiplataforma (no macOS é ignorado).
enum KeyboardKind {
    case `default`, numberPad, phonePad, emailAddress
    #if os(iOS)
    var uiKit: UIKeyboardType {
        switch self {
        case .default: return .default
        case .numberPad: return .numberPad
        case .phonePad: return .phonePad
        case .emailAddress: return .emailAddress
        }
    }
    #endif
}
