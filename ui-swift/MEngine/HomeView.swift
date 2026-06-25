import SwiftUI

/// Início do dashboard M-Engine (macOS/iOS).
///
/// Recriação do mock healthdrive `ui_kits/pacientes` (HomeTab): saudação por hora
/// do dia com o nome do profissional no tint da marca, stat cards (Pacientes ·
/// Consultas · Análises), ações (Nova consulta · Atualizar) e a lista de
/// "Pacientes recentes". Tudo sobre dados reais da API — sem mock nem placeholder.
///
/// O card "Inbox/Áudios" do mock é omitido de propósito: o backend M-Engine não
/// expõe o AudioWatcher/Inbox, e a regra é nunca inventar dado que o servidor não dá.
struct HomeView: View {
    @EnvironmentObject private var settings: AppSettings
    var onOpenPatient: (String) -> Void
    var onNova: () -> Void

    // Estado de dados (tudo real).
    @State private var patients: [Patient] = []
    @State private var professional = Professional()
    @State private var totalConsultas = 0
    @State private var totalAnalises = 0
    @State private var recents: [RecentPatient] = []

    @State private var loading = false
    @State private var loaded = false
    @State private var systemState: SystemHealth = .checking
    @State private var showNewPatient = false

    private enum SystemHealth { case checking, online, offline }

    /// Um paciente recente (com a consulta mais nova para a legenda).
    private struct RecentPatient: Identifiable, Hashable {
        let slug: String
        let displayName: String
        let consultationCount: Int
        let lastConsultationId: String?
        let lastDate: String?
        let kinds: [String]
        var id: String { slug }
    }

    // MARK: Saudação

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<12: return "Bom dia,"
        case 12..<18: return "Boa tarde,"
        default: return "Boa noite,"
        }
    }

    /// Nome do profissional (real, do `/professional`); cai no slug do e-mail só
    /// se vazio. Nunca inventa um nome fictício.
    private var clinicianName: String {
        professional.name.trimmingCharacters(in: .whitespaces).isEmpty
            ? "" : professional.name
    }

    private var metaLine: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "EEEE, d 'de' MMMM 'de' yyyy"
        let date = f.string(from: Date()).capitalizedFirst
        let reg = professional.registration.trimmingCharacters(in: .whitespaces)
        return reg.isEmpty ? date : "\(reg) · \(date)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                greetingHeader
                statCards
                actionsRow
                recentSection
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 980, alignment: .leading)
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

    // MARK: - Saudação (greet)

    private var greetingHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(greeting)
                    .font(.hosLargeTitle)
                    .foregroundStyle(.primary)
                if !clinicianName.isEmpty {
                    Text(clinicianName)
                        .font(.hosLargeTitle)
                        .foregroundStyle(HOS.blue)
                }
                Text(metaLine)
                    .font(.hosBody)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .redacted(reason: (loading && !loaded) ? .placeholder : [])
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

    // MARK: - Stat cards (Pacientes · Consultas · Análises)

    private var statCards: some View {
        HStack(spacing: 12) {
            StatCard(symbol: "person.2.fill", value: "\(patients.count)", label: "Pacientes", tint: HOS.tintBlue)
            StatCard(symbol: "calendar", value: "\(totalConsultas)", label: "Consultas", tint: HOS.tintIndigo)
            StatCard(symbol: "chart.bar.doc.horizontal", value: "\(totalAnalises)", label: "Análises", tint: HOS.tintPurple)
        }
        .redacted(reason: (loading && !loaded) ? .placeholder : [])
    }

    // MARK: - Ações

    private var actionsRow: some View {
        HStack(spacing: 10) {
            Button { onNova() } label: {
                ActionLabel("Nova consulta", systemImage: "waveform.badge.mic")
                    .font(.hosTitle3)
            }
            .buttonStyle(.borderedProminent)
            .tint(HOS.blue)

            Button { showNewPatient = true } label: {
                ActionLabel("Novo paciente", systemImage: "person.crop.circle.badge.plus")
                    .font(.hosTitle3)
            }
            .buttonStyle(.bordered)
            .tint(HOS.blue)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Pacientes recentes

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Pacientes recentes", systemImage: "clock") {
                if !recents.isEmpty {
                    Text(patients.count == 1 ? "1 paciente" : "\(patients.count) pacientes")
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

    private func recentRow(_ item: RecentPatient) -> some View {
        GlassRow(title: item.displayName) {
            PatientAvatar(name: item.displayName, size: 34)
        } subtitle: {
            recentSubtitle(item)
        } trailing: {
            HStack(spacing: 8) {
                if item.kinds.isEmpty {
                    StatusPill(text: "Sem análise", color: HOS.pending)
                } else {
                    ForEach(item.kinds.prefix(3), id: \.self) { kind in
                        StatusPill(text: kind, color: HOS.tint(forStage: kind))
                    }
                    if item.kinds.count > 3 {
                        Text("+\(item.kinds.count - 3)").font(.hosCaption).foregroundStyle(.secondary)
                    }
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func recentSubtitle(_ item: RecentPatient) -> some View {
        HStack(spacing: 6) {
            Text(item.consultationCount == 1 ? "1 consulta" : "\(item.consultationCount) consultas")
                .font(.hosCaption).foregroundStyle(.secondary)
            if let cid = item.lastConsultationId {
                Text("·").foregroundStyle(.tertiary)
                Text(cid).font(.hosMono).foregroundStyle(.secondary)
            }
            if let date = item.lastDate, !date.isEmpty {
                Text("·").foregroundStyle(.tertiary)
                Text(date).font(.hosCaption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Estados

    private var loadingState: some View {
        VStack(spacing: HOS.s2) {
            ForEach(0..<3, id: \.self) { _ in
                GlassRow(title: "Carregando paciente", subtitle: "0 consultas") {
                    Circle().fill(HOS.divider).frame(width: 34, height: 34)
                } trailing: {
                    EmptyView()
                }
            }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Carregando arquivo clínico…").font(.hosFootnote).foregroundStyle(.secondary)
            }
            .padding(.top, HOS.s1)
        }
        .redacted(reason: .placeholder)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            IconBadge(systemImage: "person.2", tint: HOS.blue, size: 56)
            Text("Nenhum paciente ainda").font(.hosTitle3).foregroundStyle(.primary)
            Text("Crie um paciente a partir de uma transcrição ou transcreva um áudio.")
                .font(.hosFootnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 340)
            HStack(spacing: 10) {
                Button { showNewPatient = true } label: {
                    ActionLabel("Novo paciente", systemImage: "person.crop.circle.badge.plus")
                }
                .buttonStyle(.borderedProminent).tint(HOS.blue)
                Button { onNova() } label: {
                    ActionLabel("Nova consulta", systemImage: "waveform.badge.mic")
                }
                .buttonStyle(.bordered).tint(HOS.blue)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40).padding(.horizontal, 16)
        .background {
            RoundedRectangle(cornerRadius: HOS.rXxl, style: .continuous)
                .fill(HOS.contentSurface)
                .overlay(RoundedRectangle(cornerRadius: HOS.rXxl, style: .continuous)
                    .strokeBorder(HOS.hairline, lineWidth: 0.75))
        }
    }

    // MARK: - Carregamento (dados reais)

    private func load(force: Bool = false) async {
        if loaded && !force { return }
        loading = true
        defer { loading = false }

        guard let client = try? settings.makeClient() else {
            systemState = .offline
            return
        }

        async let healthCheck: Void = checkHealth(client)
        async let prof = client.fetchProfessional()

        let pats = (try? await client.fetchPatients()) ?? []
        patients = pats
        professional = (try? await prof) ?? Professional()

        var consultas = 0
        var analises = 0
        var collected: [RecentPatient] = []

        await withTaskGroup(of: (Patient, [Consultation]).self) { group in
            for p in pats {
                group.addTask {
                    let cs = (try? await client.fetchConsultations(slug: p.slug)) ?? []
                    return (p, cs)
                }
            }
            for await (p, cs) in group {
                consultas += cs.count
                let allDocs = cs.flatMap { $0.documents }
                analises += allDocs.count
                let latest = cs.max { ($0.date ?? $0.id) < ($1.date ?? $1.id) }
                collected.append(RecentPatient(
                    slug: p.slug,
                    displayName: p.displayName,
                    consultationCount: cs.count,
                    lastConsultationId: latest?.id,
                    lastDate: latest?.date,
                    kinds: Self.docKinds(allDocs)
                ))
            }
        }

        totalConsultas = consultas
        totalAnalises = analises
        recents = collected
            .sorted { ($0.lastDate ?? "") > ($1.lastDate ?? "") }
            .prefix(8).map { $0 }

        await healthCheck
        loaded = true
    }

    private func checkHealth(_ client: APIClient) async {
        systemState = (try? await client.health()) != nil ? .online : .offline
    }

    /// Rótulos de análise derivados dos nomes de documentos (BIRP·SOAP·ASL·VDLP·GEM).
    static func docKinds(_ documents: [String]) -> [String] {
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
}

// MARK: - Util

private extension String {
    var capitalizedFirst: String {
        guard let first = first else { return self }
        return first.uppercased() + dropFirst()
    }
}
