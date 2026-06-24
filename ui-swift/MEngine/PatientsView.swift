import SwiftUI
import UniformTypeIdentifiers

/// Detalhe do paciente (HealthOS — Pacientes): cabeçalho com nome de exibição +
/// capsules, consultas agrupadas em C1/C2/C3 (cada uma com sua data) listando os
/// documentos. Tocar num documento abre o editor de Markdown. O perfil
/// (nome completo, CPF, telefone, idade) é editável via folha.
struct PatientDetailView: View {
    @EnvironmentObject private var settings: AppSettings
    let slug: String

    @State private var profile: PatientProfile?
    @State private var consultations: [Consultation] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var showProfileEditor = false

    // Criação de consulta / documento.
    @State private var showNewConsultation = false
    /// Consulta-alvo da folha "Novo documento" (nil = folha fechada).
    @State private var docTarget: Consultation?
    /// Consulta-alvo do importador de arquivo (nil = importador fechado).
    @State private var importTarget: Consultation?

    /// Rota de documento dentro de uma consulta.
    private struct DocRoute: Hashable {
        let consultationId: String
        let name: String
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                content
            }
            .background(.background)
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
    }

    /// Binding booleano derivado de `importTarget` para o `.fileImporter`.
    private var importerBinding: Binding<Bool> {
        Binding(get: { importTarget != nil }, set: { if !$0 { importTarget = nil } })
    }

    private var importTypes: [UTType] {
        [.plainText, .text, .pdf, .rtf, .audio, .movie, .image, .data]
    }

    // MARK: - Cabeçalho

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(HOS.navy, HOS.blue.opacity(0.16))
            VStack(alignment: .leading, spacing: 6) {
                Text(profile?.displayName ?? slug).font(.hosTitle1).foregroundStyle(.primary)
                Text(slug).font(.hosMono).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    StatusPill(text: consultations.count == 1 ? "1 consulta" : "\(consultations.count) consultas",
                               color: HOS.info, systemImage: "calendar")
                    if let age = profile?.age {
                        StatusPill(text: "\(age) anos", color: HOS.stAsl, systemImage: "number")
                    }
                    if let phone = profile?.phone, !phone.isEmpty {
                        StatusPill(text: phone, color: HOS.stGem, systemImage: "phone.fill")
                    }
                }
            }
            Spacer()
            VStack(spacing: 8) {
                Button { showNewConsultation = true } label: {
                    ActionLabel("Nova consulta", systemImage: "calendar.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(HOS.blue)
                Button { showProfileEditor = true } label: {
                    ActionLabel("Editar perfil", systemImage: "person.text.rectangle")
                }
                .buttonStyle(.bordered)
                .tint(HOS.blue)
                .disabled(profile == nil)
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Atualizar")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    // MARK: - Conteúdo

    @ViewBuilder
    private var content: some View {
        if loading {
            Spacer(); ProgressView("Carregando…"); Spacer()
        } else if let errorText {
            Spacer()
            ContentUnavailableView("Erro", systemImage: "exclamationmark.triangle", description: Text(errorText))
            Spacer()
        } else if consultations.isEmpty {
            Spacer()
            ContentUnavailableView {
                Label("Sem consultas", systemImage: "calendar.badge.exclamationmark")
            } description: {
                Text("Nenhuma consulta registrada para este paciente.")
            } actions: {
                Button { showNewConsultation = true } label: {
                    ActionLabel("Nova consulta", systemImage: "calendar.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(HOS.blue)
            }
            Spacer()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(consultations) { consultation in
                        consultationSection(consultation)
                    }
                }
                .padding(24)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func consultationSection(_ consultation: Consultation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusPill(text: consultation.id, color: HOS.navy, systemImage: "calendar")
                if let date = consultation.date, !date.isEmpty {
                    Text(date).font(.hosSubhead).foregroundStyle(.secondary)
                }
                Spacer()
                if let source = consultation.source, !source.isEmpty {
                    StatusPill(text: source, color: HOS.stStt, systemImage: "waveform")
                }
            }
            if consultation.documents.isEmpty {
                Text("Sem documentos nesta consulta.").font(.hosFootnote).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(consultation.documents, id: \.self) { name in
                        NavigationLink(value: DocRoute(consultationId: consultation.id, name: name)) {
                            documentRow(name)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider().padding(.vertical, 2)
            consultationActions(consultation)
            PipelineControl(slug: slug, consultation: consultation) {
                Task { await load() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .healthCard()
    }

    /// Ações por consulta: novo documento e importar arquivo.
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
        }
    }

    private func documentRow(_ name: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: name))
                .font(.system(size: 18))
                .foregroundStyle(HOS.tint(forStage: name))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(for: name)).font(.hosHeadline).foregroundStyle(.primary)
                Text(name).font(.hosCaption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            StatusPill(text: kind(for: name), color: HOS.tint(forStage: name))
            Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.caption)
        }
        .healthCard(padding: 12)
    }

    // MARK: - Helpers

    private func icon(for name: String) -> String {
        let k = name.lowercased()
        if k.contains("birp") { return "bolt.heart.fill" }
        if k.contains("soap_long") { return "chart.line.uptrend.xyaxis" }
        if k.contains("soap") { return "doc.text.fill" }
        if k.contains("transcri") { return "waveform" }
        return "doc"
    }

    private func title(for name: String) -> String {
        let k = name.lowercased()
        if k.contains("birp") { return "Nota BIRP" }
        if k.contains("soap_long") { return "SOAP — Seguimento" }
        if k.contains("soap") { return "SOAP — Sumário" }
        if k.contains("transcri") { return "Transcrição" }
        return name
    }

    private func kind(for name: String) -> String {
        let k = name.lowercased()
        if k.contains("birp") { return "BIRP" }
        if k.contains("soap_long") { return "Seguimento" }
        if k.contains("soap") { return "Sumário" }
        if k.contains("transcri") { return "STT" }
        return "doc"
    }

    private func load() async {
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            let client = try settings.makeClient()
            async let cons = client.fetchConsultations(slug: slug)
            async let prof = try? client.fetchProfile(slug: slug)
            consultations = try await cons
            profile = await prof
        } catch {
            errorText = error.localizedDescription
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
            HStack(spacing: 10) {
                Image(systemName: "person.text.rectangle.fill")
                    .font(.system(size: 22)).foregroundStyle(HOS.blue)
                Text("Editar perfil").font(.hosTitle1)
                Spacer()
                Text(profile.slug).font(.hosMono).foregroundStyle(.secondary)
            }

            field("NOME DE EXIBIÇÃO", text: $profile.displayName)
            field("NOME COMPLETO", text: optionalBinding(\.fullName))
            field("CPF", text: optionalBinding(\.cpf), keyboard: .numberPad, mono: true)
            field("TELEFONE", text: optionalBinding(\.phone), keyboard: .phonePad)

            VStack(alignment: .leading, spacing: 6) {
                Text("IDADE").font(.hosSubhead).foregroundStyle(.secondary)
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
            Text(label).font(.hosSubhead).foregroundStyle(.secondary)
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
