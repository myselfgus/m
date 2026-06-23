import SwiftUI

/// Detalhe do paciente (estilo HealthOS Pacientes): cabeçalho com avatar + capsules,
/// abas Documentos · Pipeline · Dossiê. Empacota uma NavigationStack para empurrar o leitor.
struct PatientDetailView: View {
    @EnvironmentObject private var settings: AppSettings
    let patientId: String

    enum Tab: String, CaseIterable, Identifiable {
        case documentos = "Documentos"
        case pipeline = "Pipeline"
        case dossie = "Dossiê"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .documentos: return "doc.text.fill"
            case .pipeline: return "point.3.connected.trianglepath.dotted"
            case .dossie: return "person.text.rectangle.fill"
            }
        }
    }

    @State private var tab: Tab = .documentos
    @State private var documents: [String] = []
    @State private var info: PatientInfo?
    @State private var loading = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

                Divider()

                content
            }
            .background(.background)
            .navigationDestination(for: String.self) { name in
                DocumentDetailView(patientId: patientId, name: name)
            }
        }
        .navigationTitle(patientId)
        .task { await load() }
    }

    // MARK: - Cabeçalho

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(HOS.navy, HOS.blue.opacity(0.16))
            VStack(alignment: .leading, spacing: 6) {
                Text(info?.name ?? patientId).font(.hosTitle1).foregroundStyle(.primary)
                Text(patientId).font(.hosMono).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if let info, info.sessionCount > 0 {
                        StatusPill(text: "\(info.sessionCount) sessões", color: HOS.info, systemImage: "calendar")
                    }
                    if let info, !info.icdCodes.isEmpty {
                        StatusPill(text: "\(info.icdCodes.count) CID", color: HOS.stVdlp, systemImage: "cross.case.fill")
                    }
                    if let info, !info.medications.isEmpty {
                        StatusPill(text: "\(info.medications.count) medicamentos", color: HOS.stGem, systemImage: "pills.fill")
                    }
                }
            }
            Spacer()
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    // MARK: - Conteúdo por aba

    @ViewBuilder
    private var content: some View {
        if loading {
            Spacer(); ProgressView("Carregando…"); Spacer()
        } else if let errorText {
            Spacer()
            ContentUnavailableView("Erro", systemImage: "exclamationmark.triangle", description: Text(errorText))
            Spacer()
        } else {
            switch tab {
            case .documentos: documentsTab
            case .pipeline: pipelineTab
            case .dossie: dossieTab
            }
        }
    }

    private var documentsTab: some View {
        ScrollView {
            if documents.isEmpty {
                ContentUnavailableView("Sem documentos", systemImage: "doc").padding(.top, 60)
            } else {
                VStack(spacing: 8) {
                    ForEach(documents, id: \.self) { name in
                        NavigationLink(value: name) {
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
                        .buttonStyle(.plain)
                    }
                }
                .padding(24)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var pipelineTab: some View {
        let steps: [(String, String, Color, Bool)] = [
            ("Transcrição", "waveform", HOS.stStt, true),
            ("BIRP", "bolt.heart.fill", HOS.stProc, documents.contains { $0.contains("BIRP") }),
            ("Normalize · ASL · VDLP · GEM", "point.3.connected.trianglepath.dotted", HOS.stAsl, !documents.filter { $0.contains("SOAP") }.isEmpty),
            ("SOAP — Sumário", "doc.text.fill", HOS.navy, documents.contains { $0.contains("SOAP") && !$0.contains("LONG") }),
            ("SOAP — Seguimento", "chart.line.uptrend.xyaxis", HOS.tintTeal, documents.contains { $0.contains("SOAP_LONG") })
        ]
        return ScrollView {
            VStack(spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, s in
                    HStack(spacing: 12) {
                        Image(systemName: s.1).font(.system(size: 16)).foregroundStyle(s.2).frame(width: 24)
                        Text(s.0).font(.hosHeadline).foregroundStyle(.primary)
                        Spacer()
                        StatusPill(text: s.3 ? "concluído" : "pendente",
                                   color: s.3 ? HOS.complete : HOS.queued,
                                   systemImage: s.3 ? "checkmark.circle.fill" : "clock")
                    }
                    .healthCard(padding: 12)
                }
                Text("Artefatos profundos (ASL/VDLP/GEM em JSON) ficam no dossiê do servidor; aqui mostramos as notas clínicas e o progresso do pipeline.")
                    .font(.hosFootnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var dossieTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let s = info?.summary, !s.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("RESUMO CLÍNICO").font(.hosSubhead).foregroundStyle(.secondary)
                        Text(s).font(.hosBody).foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .healthCard()
                }
                chipGroup("DIAGNÓSTICOS (CID/DSM)", info?.icdCodes ?? [], HOS.stVdlp, "cross.case.fill")
                chipGroup("MEDICAMENTOS", info?.medications ?? [], HOS.stGem, "pills.fill")
                chipGroup("TÓPICOS RECORRENTES", info?.topics ?? [], HOS.info, "tag.fill")
                if (info?.summary ?? "").isEmpty && (info?.icdCodes.isEmpty ?? true) && (info?.medications.isEmpty ?? true) {
                    ContentUnavailableView("Dossiê vazio", systemImage: "person.text.rectangle",
                                           description: Text("Sem resumo clínico consolidado ainda."))
                        .padding(.top, 40)
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func chipGroup(_ title: String, _ items: [String], _ color: Color, _ symbol: String) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.hosSubhead).foregroundStyle(.secondary)
                FlowChips(items: items, color: color, symbol: symbol)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .healthCard()
        }
    }

    // MARK: - Helpers

    private func icon(for name: String) -> String {
        if name.contains("BIRP") { return "bolt.heart.fill" }
        if name.contains("SOAP_LONG") { return "chart.line.uptrend.xyaxis" }
        if name.contains("SOAP") { return "doc.text.fill" }
        if name.contains("TRANSCRI") { return "waveform" }
        return "doc"
    }

    private func title(for name: String) -> String {
        if name.contains("BIRP") { return "Nota BIRP" }
        if name.contains("SOAP_LONG") { return "SOAP — Seguimento" }
        if name.contains("SOAP") { return "SOAP — Sumário" }
        if name.contains("TRANSCRI") { return "Transcrição" }
        return name
    }

    private func kind(for name: String) -> String {
        if name.contains("BIRP") { return "BIRP" }
        if name.contains("SOAP_LONG") { return "Seguimento" }
        if name.contains("SOAP") { return "Sumário" }
        if name.contains("TRANSCRI") { return "STT" }
        return "doc"
    }

    private func load() async {
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            let client = try settings.makeClient()
            async let docs = client.documents(patientId: patientId)
            async let inf = try? client.patientInfo(patientId: patientId)
            documents = try await docs
            info = await inf
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// Chips em fluxo (wrap) para CID/medicamentos/tópicos.
struct FlowChips: View {
    let items: [String]
    var color: Color
    var symbol: String

    var body: some View {
        // grid adaptável aproxima o comportamento de wrap.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                StatusPill(text: it, color: color, systemImage: symbol)
            }
        }
    }
}

/// Leitor de documento clínico (Markdown renderizado).
struct DocumentDetailView: View {
    @EnvironmentObject private var settings: AppSettings
    let patientId: String
    let name: String
    @State private var content = ""
    @State private var loading = true
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            if loading {
                ProgressView().padding(40)
            } else if let errorText {
                Text(errorText).foregroundStyle(HOS.error).padding()
            } else {
                MarkdownText(text: content)
                    .padding(24)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.background)
        .navigationTitle(name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
    }

    private func load() async {
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            content = try await settings.makeClient().document(patientId: patientId, name: name)
        } catch {
            errorText = error.localizedDescription
        }
    }
}
