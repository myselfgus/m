import SwiftUI

/// Início do dashboard HealthOS: header com pílula de saúde do sistema,
/// stat cards (Pacientes / Consultas / Análises / Inbox), atalhos e as
/// consultas mais recentes do arquivo. Liquid Glass, grade de 8 pt, PT-BR sóbrio.
struct HomeView: View {
    @EnvironmentObject private var settings: AppSettings
    var onOpenPatient: (String) -> Void
    var onNova: () -> Void

    // Estado de dados
    @State private var patients: [Patient] = []
    @State private var totalConsultas = 0
    @State private var totalAnalises = 0
    @State private var recents: [RecentConsultation] = []

    // Estado de carregamento / saúde do sistema
    @State private var loading = false
    @State private var loaded = false
    @State private var systemState: SystemHealth = .checking
    @State private var showNewPatient = false

    // MARK: Tipos auxiliares

    private enum SystemHealth {
        case checking, online, offline
    }

    /// Uma consulta achatada com referência ao paciente, para a lista "recentes".
    private struct RecentConsultation: Identifiable, Hashable {
        let slug: String
        let displayName: String
        let consultationId: String   // C1, C2…
        let date: String?
        let documents: [String]
        var id: String { "\(slug)/\(consultationId)" }

        /// Chave de ordenação: usa a data quando disponível, senão o índice da consulta.
        var sortKey: String { date ?? "" }
    }

    // MARK: Cabeçalho

    private var todayLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "EEEE, d 'de' MMMM"
        return f.string(from: Date()).capitalizedFirst
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                statsRow
                quickActions
                recentSection
            }
            .padding(24)
            .frame(maxWidth: 920, alignment: .leading)
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
        HStack(alignment: .top, spacing: 12) {
            HStack(spacing: 12) {
                BrandMark(size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("M-Engine").font(.hosLargeTitle).foregroundStyle(.primary)
                    Text(todayLabel).font(.hosBody).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            systemHealthPill
        }
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

    // MARK: - Stat cards

    private var statsRow: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            StatCard(symbol: "person.2.fill", value: "\(patients.count)",
                     label: "Pacientes", tint: HOS.tintBlue)
            StatCard(symbol: "calendar", value: "\(totalConsultas)",
                     label: "Consultas", tint: HOS.tintIndigo)
            StatCard(symbol: "doc.text.magnifyingglass", value: "\(totalAnalises)",
                     label: "Análises", tint: HOS.tintPurple)
            StatCard(symbol: "tray.full.fill", value: "—",
                     label: "Áudios no inbox", tint: HOS.tintTeal)
        }
    }

    // MARK: - Atalhos

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AÇÕES").font(.hosSubhead).foregroundStyle(.secondary)
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

                Button { onNova() } label: {
                    ActionLabel("Importar áudio", systemImage: "square.and.arrow.down")
                        .font(.hosTitle3)
                }
                .buttonStyle(.bordered)
                .tint(HOS.blue)

                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Consultas recentes

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CONSULTAS RECENTES").font(.hosSubhead).foregroundStyle(.secondary)

            if loading && !loaded {
                loadingState
            } else if recents.isEmpty {
                emptyState
            } else {
                VStack(spacing: 8) {
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
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(HOS.navy, HOS.blue.opacity(0.18))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName).font(.hosHeadline).foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.consultationId).font(.hosMono).foregroundStyle(.secondary)
                    if let date = item.date, !date.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Text(date).font(.hosCaption).foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 8)

            docChips(for: item.documents)

            Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.caption)
        }
        .healthCard(padding: 12)
    }

    /// Chips de estado a partir dos documentos da consulta (ex.: BIRP, GEM, SOAP, ASL).
    @ViewBuilder
    private func docChips(for documents: [String]) -> some View {
        let kinds = Self.docKinds(documents)
        if kinds.isEmpty {
            StatusPill(text: "Sem análises", color: HOS.pending)
        } else {
            HStack(spacing: 6) {
                ForEach(kinds, id: \.self) { kind in
                    StatusPill(text: kind, color: HOS.tint(forStage: kind))
                }
            }
        }
    }

    // MARK: - Estados (loading / vazio)

    private var loadingState: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Carregando arquivo clínico…").font(.hosFootnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 24)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(HOS.blue.opacity(0.7))
            Text("Nenhuma consulta ainda")
                .font(.hosTitle3).foregroundStyle(.primary)
            Text("Cadastre um paciente ou inicie uma nova sessão para processar o pipeline.")
                .font(.hosFootnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
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
        .padding(.vertical, 32)
        .padding(.horizontal, 16)
        .background(
            // Único floreio permitido: um wash radial azul de baixa opacidade.
            RadialGradient(
                colors: [HOS.blue.opacity(0.10), .clear],
                center: .center, startRadius: 4, endRadius: 280
            )
        )
        .healthCard()
    }

    // MARK: - Classificação de documentos

    /// Deriva rótulos curtos de análise a partir dos nomes de arquivos .md.
    /// Mantém ordem do pipeline e remove duplicatas.
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

        // Mais recentes primeiro: por data quando houver, senão por id de consulta desc.
        recents = Array(
            collected
                .sorted { lhs, rhs in
                    if lhs.sortKey != rhs.sortKey { return lhs.sortKey > rhs.sortKey }
                    return lhs.consultationId > rhs.consultationId
                }
                .prefix(8)
        )

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
