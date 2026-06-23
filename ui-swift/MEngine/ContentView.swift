import SwiftUI

/// Destino de navegação da sidebar.
enum Nav: Hashable {
    case home
    case nova
    case patient(String)
}

/// Shell do dashboard HealthOS: NavigationSplitView (sidebar + detalhe).
struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var nav: Nav? = .home
    @State private var patients: [String] = []
    @State private var search = ""
    @State private var loading = false
    @State private var showSettings = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var filtered: [String] {
        guard !search.isEmpty else { return patients }
        return patients.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 264, max: 320)
        } detail: {
            detail
        }
        .task { await loadPatients() }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $nav) {
            Section {
                Label("Início", systemImage: "house.fill").tag(Nav.home)
                Label("Nova sessão", systemImage: "waveform.badge.mic").tag(Nav.nova)
            }

            Section {
                if loading && patients.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text("Carregando…").font(.hosFootnote).foregroundStyle(.secondary) }
                } else if filtered.isEmpty {
                    Text(search.isEmpty ? "Nenhum paciente" : "Sem resultados")
                        .font(.hosFootnote).foregroundStyle(.secondary)
                } else {
                    ForEach(filtered, id: \.self) { pid in
                        PatientRow(patientId: pid).tag(Nav.patient(pid))
                    }
                }
            } header: {
                Text("Pacientes").font(.hosSubhead).textCase(.uppercase).foregroundStyle(.secondary)
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Buscar paciente")
        .safeAreaInset(edge: .top) { brandHeader }
        .toolbar {
            ToolbarItem {
                Button { Task { await loadPatients() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Atualizar")
            }
            ToolbarItem {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .help("Ajustes")
            }
        }
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            BrandMark(size: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text("M-Engine").font(.hosTitle3).foregroundStyle(.primary)
                Text("inteligência clínica").font(.hosCaption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: - Detalhe

    @ViewBuilder
    private var detail: some View {
        switch nav {
        case .home, .none:
            HomeView(onOpenPatient: { nav = .patient($0) }, onNova: { nav = .nova })
        case .nova:
            NewSessionView()
        case let .patient(pid):
            PatientDetailView(patientId: pid)
                .id(pid)
        }
    }

    private func loadPatients() async {
        loading = true
        defer { loading = false }
        patients = (try? await settings.makeClient().patients()) ?? []
    }
}

/// Linha de paciente na sidebar (avatar + slug).
struct PatientRow: View {
    let patientId: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(HOS.navy, HOS.blue.opacity(0.18))
            VStack(alignment: .leading, spacing: 1) {
                Text(patientId).font(.hosHeadline).foregroundStyle(.primary).lineLimit(1)
                Text("dossiê").font(.hosCaption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Ajustes

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var healthMessage: String?
    @State private var healthOK = false
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                BrandMark(size: 24)
                Text("Ajustes").font(.hosTitle1)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("URL DA API").font(.hosSubhead).foregroundStyle(.secondary)
                TextField("http://localhost:8000", text: $settings.baseURL)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("API KEY (OPCIONAL)").font(.hosSubhead).foregroundStyle(.secondary)
                SecureField("Bearer token (se houver proxy)", text: $settings.apiKey)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 10) {
                Button { Task { await checkHealth() } } label: {
                    Label("Testar conexão", systemImage: "antenna.radiowaves.left.and.right")
                }
                .buttonStyle(.borderedProminent)
                .tint(HOS.blue)
                .disabled(checking)
                if checking { ProgressView().controlSize(.small) }
                if let healthMessage {
                    StatusPill(text: healthMessage,
                               color: healthOK ? HOS.complete : HOS.error,
                               systemImage: healthOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                }
            }

            Spacer()
            HStack {
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(minWidth: 420, minHeight: 300)
    }

    private func checkHealth() async {
        checking = true
        defer { checking = false }
        do {
            let h = try await settings.makeClient().health()
            healthOK = true
            healthMessage = "OK · \(h["m_base"] ?? "online")"
        } catch {
            healthOK = false
            healthMessage = "Falhou"
        }
    }
}
