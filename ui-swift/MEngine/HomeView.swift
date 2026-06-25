import SwiftUI

/// Início do dashboard M-Engine (macOS/iOS).
///
/// Redesenho content-first: em vez das quatro "praças" de contagem, o clínico
/// vê o que realmente usa — as consultas mais recentes de todo o arquivo,
/// uma seção curta "precisa de atenção" (consultas ainda sem análise/BIRP) e
/// ações silenciosas. Contagens viram uma tira de resumo discreta no cabeçalho,
/// nunca o centro da tela. Listas são linhas com hairlines, não vidro pesado.
/// Grade de 8 pt, PT-BR sóbrio, SF Symbols.
struct HomeView: View {
    @EnvironmentObject private var settings: AppSettings
    var onOpenPatient: (String) -> Void
    var onNova: () -> Void

    // Estado de dados
    @State private var patients: [Patient] = []
    @State private var totalConsultas = 0
    @State private var totalAnalises = 0
    @State private var recents: [RecentConsultation] = []
    @State private var needsAttention: [RecentConsultation] = []

    // Estado de carregamento / saúde do sistema
    @State private var loading = false
    @State private var loaded = false
    @State private var systemState: SystemHealth = .checking
    @State private var showNewPatient = false

    // MARK: Tipos auxiliares

    private enum SystemHealth {
        case checking, online, offline
    }

    /// Uma consulta achatada com referência ao paciente, para as listas do dashboard.
    private struct RecentConsultation: Identifiable, Hashable {
        let slug: String
        let displayName: String
        let consultationId: String   // C1, C2…
        let date: String?
        let documents: [String]
        var id: String { "\(slug)/\(consultationId)" }

        /// Chave de ordenação: usa a data quando disponível.
        var sortKey: String { date ?? "" }

        /// Rótulos de análise derivados dos documentos (BIRP, SOAP, ASL, VDLP, GEM).
        var kinds: [String] { HomeView.docKinds(documents) }

        /// "Precisa de atenção" = consulta sem nenhuma análise clínica ainda.
        /// (pode ter só transcrição/normalização, mas nenhum artefato derivado).
        var needsAttention: Bool { kinds.isEmpty }
    }

    // MARK: Cabeçalho — data

    private var todayLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "EEEE, d 'de' MMMM"
        return f.string(from: Date()).capitalizedFirst
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                quickActions
                if !needsAttention.isEmpty { attentionSection }
                recentSection
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background {
            Rectangle().fill(.background).ignoresSafeArea()
            BlueWash()
        }
        .navigationTitle("Início")
        .toolbar {
            ToolbarItem {
                Button { Task { await load(force: true) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Atualizar")
                .disabled(loading)
            }
        }
        .sheet(isPresented: $showNewPatient) {
            NewPatientView(onCreated: { slug in onOpenPatient(slug) })
        }
        .task { await load() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                BrandMark(size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("M-Engine")
                        .font(.hosLargeTitle)
                        .foregroundStyle(.primary)
                    Text(todayLabel)
                        .font(.hosBody)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                systemHealthPill
            }
            summaryStrip
        }
    }

    /// Tira de resumo discreta: as contagens, agora inline e calmas — não praças.
    private var summaryStrip: some View {
        HStack(spacing: 18) {
            InlineStat(value: "\(patients.count)", label: patients.count == 1 ? "paciente" : "pacientes",
                       systemImage: "person.2", tint: HOS.tintBlue)
            divider
            InlineStat(value: "\(totalConsultas)", label: totalConsultas == 1 ? "consulta" : "consultas",
                       systemImage: "calendar", tint: HOS.tintIndigo)
            divider
            InlineStat(value: "\(totalAnalises)", label: totalAnalises == 1 ? "análise" : "análises",
                       systemImage: "doc.text.magnifyingglass", tint: HOS.tintPurple)
            if !needsAttention.isEmpty {
                divider
                InlineStat(value: "\(needsAttention.count)", label: "a revisar",
                           systemImage: "exclamationmark.circle", tint: HOS.review)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 2)
        .redacted(reason: (loading && !loaded) ? .placeholder : [])
    }

    private var divider: some View {
        Rectangle()
            .fill(HOS.divider)
            .frame(width: 1, height: 16)
    }

    @ViewBuilder
    private var systemHealthPill: some View {
        switch systemState {
        case .checking:
            StatusPill(text: "Verificando", color: HOS.pending, systemImage: "ellipsis")
        case .online:
            StatusPill(text: "Online", color: HOS.complete, systemImage: "checkmark.circle.fill")
        case .offline:
            StatusPill(text: "Offline", color: HOS.error, systemImage: "exclamationmark.circle.fill")
        }
    }

    // MARK: - Atalhos (silenciosos)

    private var quickActions: some View {
        HStack(spacing: 10) {
            Button { showNewPatient = true } label: {
                ActionLabel("Novo paciente", systemImage: "person.crop.circle.badge.plus")
                    .font(.hosTitle3)
            }
            .buttonStyle(.borderedProminent)
            .tint(HOS.blue)

            Button { onNova() } label: {
                ActionLabel("Nova sessão", systemImage: "waveform.badge.mic")
                    .font(.hosTitle3)
            }
            .buttonStyle(.bordered)
            .tint(HOS.blue)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Precisa de atenção

    private var attentionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Precisa de atenção", systemImage: "exclamationmark.triangle") {
                Text(needsAttention.count == 1 ? "1 consulta" : "\(needsAttention.count) consultas")
                    .font(.hosCaption)
                    .foregroundStyle(.secondary)
            }
            Text("Consultas sem nenhuma análise clínica derivada — rode o pipeline (ASL · VDLP · GEM · BIRP) na ficha do paciente.")
                .font(.hosFootnote)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            VStack(spacing: HOS.s2) {
                ForEach(needsAttention.prefix(5)) { item in
                    Button { onOpenPatient(item.slug) } label: {
                        attentionRow(item)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func attentionRow(_ item: RecentConsultation) -> some View {
        GlassRow(title: item.displayName) {
            IconBadge(systemImage: "exclamationmark.circle.fill", tint: HOS.review)
        } subtitle: {
            consultationSubtitle(item)
        } trailing: {
            HStack(spacing: 8) {
                StatusPill(text: "Sem análise", color: HOS.review)
                chevron
            }
        }
    }

    // MARK: - Consultas recentes

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Consultas recentes", systemImage: "clock") {
                if !recents.isEmpty {
                    Text("todo o arquivo")
                        .font(.hosCaption)
                        .foregroundStyle(.secondary)
                }
            }

            if loading && !loaded {
                loadingState
            } else if recents.isEmpty {
                emptyState
            } else {
                VStack(spacing: HOS.s2) {
                    ForEach(recents) { item in
                        Button { onOpenPatient(item.slug) } label: {
                            recentRow(item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func recentRow(_ item: RecentConsultation) -> some View {
        GlassRow(title: item.displayName) {
            IconBadge(systemImage: "person.fill", tint: HOS.blue)
        } subtitle: {
            consultationSubtitle(item)
        } trailing: {
            HStack(spacing: 8) {
                docChips(for: item)
                chevron
            }
        }
    }

    /// Subtítulo de linha: Cn · data.
    private func consultationSubtitle(_ item: RecentConsultation) -> some View {
        HStack(spacing: 6) {
            Text(item.consultationId)
                .font(.hosMono)
                .foregroundStyle(.secondary)
            if let date = item.date, !date.isEmpty {
                Text("·").foregroundStyle(.tertiary)
                Text(date)
                    .font(.hosCaption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Chips de estado do pipeline a partir dos documentos da consulta.
    @ViewBuilder
    private func docChips(for item: RecentConsultation) -> some View {
        let kinds = item.kinds
        if kinds.isEmpty {
            StatusPill(text: "Sem análise", color: HOS.pending)
        } else {
            HStack(spacing: 6) {
                ForEach(kinds.prefix(3), id: \.self) { kind in
                    StatusPill(text: kind, color: HOS.tint(forStage: kind))
                }
                if kinds.count > 3 {
                    Text("+\(kinds.count - 3)")
                        .font(.hosCaption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Peças compartilhadas

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }

    // MARK: - Estados (loading / vazio)

    private var loadingState: some View {
        VStack(spacing: HOS.s2) {
            ForEach(0..<3, id: \.self) { _ in
                GlassRow(title: "Carregando paciente", subtitle: "C0 · ————") {
                    Circle().fill(HOS.divider).frame(width: 34, height: 34)
                } trailing: {
                    EmptyView()
                }
            }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Carregando arquivo clínico…")
                    .font(.hosFootnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, HOS.s1)
        }
        .redacted(reason: .placeholder)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            IconBadge(systemImage: "tray", tint: HOS.blue, size: 56)
            Text("Nenhuma consulta ainda")
                .font(.hosTitle3)
                .foregroundStyle(.primary)
            Text("Cadastre um paciente ou inicie uma nova sessão para processar o pipeline clínico.")
                .font(.hosFootnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            HStack(spacing: 10) {
                Button { showNewPatient = true } label: {
                    ActionLabel("Novo paciente", systemImage: "person.crop.circle.badge.plus")
                }
                .buttonStyle(.borderedProminent).tint(HOS.blue)
                Button { onNova() } label: {
                    ActionLabel("Nova sessão", systemImage: "waveform.badge.mic")
                }
                .buttonStyle(.bordered).tint(HOS.blue)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 16)
        .background {
            RoundedRectangle(cornerRadius: HOS.rXxl, style: .continuous)
                .fill(HOS.contentSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: HOS.rXxl, style: .continuous)
                        .strokeBorder(HOS.hairline, lineWidth: 0.75)
                )
        }
    }

    // MARK: - Classificação de documentos

    /// Deriva rótulos curtos de análise a partir dos nomes de arquivos .md.
    /// Mantém ordem do pipeline e remove duplicatas. Transcrição/normalização
    /// não contam como "análise" (são insumo, não artefato derivado).
    private static func docKinds(_ documents: [String]) -> [String] {
        var found: [String] = []
        func add(_ label: String, if predicate: Bool) {
            if predicate && !found.contains(label) { found.append(label) }
        }
        let blob = documents.joined(separator: " ").lowercased()
        add("BIRP", if: blob.contains("birp"))
        add("SOAP", if: blob.contains("soap"))
        add("ASL", if: blob.contains("asl"))
        add("VDLP", if: blob.contains("vdlp") || blob.contains("dimensional"))
        add("GEM", if: blob.contains("gem"))
        return found
    }

    // MARK: - Carregamento

    private func load(force: Bool = false) async {
        if loaded && !force { return }
        loading = true
        defer { loading = false }

        guard let client = try? settings.makeClient() else {
            systemState = .offline
            return
        }

        // Saúde do sistema (não bloqueia os dados).
        async let healthCheck: Void = checkHealth(client)

        let pats = (try? await client.fetchPatients()) ?? []
        patients = pats

        var consultas = 0
        var analises = 0
        var collected: [RecentConsultation] = []

        await withTaskGroup(of: (Patient, [Consultation]).self) { group in
            for p in pats {
                group.addTask {
                    let cs = (try? await client.fetchConsultations(slug: p.slug)) ?? []
                    return (p, cs)
                }
            }
            for await (p, cs) in group {
                consultas += cs.count
                for c in cs {
                    analises += c.documents.count
                    collected.append(RecentConsultation(
                        slug: p.slug,
                        displayName: p.displayName,
                        consultationId: c.id,
                        date: c.date,
                        documents: c.documents
                    ))
                }
            }
        }

        totalConsultas = consultas
        totalAnalises = analises

        // Mais recentes primeiro: por data quando houver, senão por id desc.
        let ordered = collected.sorted { lhs, rhs in
            if lhs.sortKey != rhs.sortKey { return lhs.sortKey > rhs.sortKey }
            return lhs.consultationId > rhs.consultationId
        }

        recents = Array(ordered.prefix(8))
        needsAttention = ordered.filter { $0.needsAttention }

        await healthCheck
        loaded = true
    }

    private func checkHealth(_ client: APIClient) async {
        if (try? await client.health()) != nil {
            systemState = .online
        } else {
            systemState = .offline
        }
    }
}

// MARK: - Util

private extension String {
    /// Capitaliza apenas a primeira letra (datas PT-BR vêm em minúsculas).
    var capitalizedFirst: String {
        guard let first = first else { return self }
        return first.uppercased() + dropFirst()
    }
}
