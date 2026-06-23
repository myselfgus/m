import SwiftUI

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
                Button { showProfileEditor = true } label: {
                    Label("Editar perfil", systemImage: "person.text.rectangle")
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
            ContentUnavailableView("Sem consultas", systemImage: "calendar.badge.exclamationmark",
                                   description: Text("Nenhuma consulta registrada para este paciente."))
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
            if !consultation.tags.isEmpty {
                FlowChips(items: consultation.tags, color: HOS.info, symbol: "tag.fill")
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .healthCard()
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
                    Label(editing ? "Pré-visualizar" : "Editar",
                          systemImage: editing ? "eye" : "square.and.pencil")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await save() }
                } label: {
                    if saving { ProgressView().controlSize(.small) }
                    else { Label("Salvar", systemImage: "tray.and.arrow.down.fill") }
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
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: HOS.rXl, style: .continuous))
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
                Button("Cancelar") { dismiss() }
                Spacer()
                Button {
                    Task { await save() }
                } label: {
                    if saving { ProgressView().controlSize(.small) }
                    else { Label("Salvar", systemImage: "tray.and.arrow.down.fill") }
                }
                .buttonStyle(.borderedProminent)
                .tint(HOS.blue)
                .disabled(saving)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(minWidth: 440, minHeight: 420)
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
