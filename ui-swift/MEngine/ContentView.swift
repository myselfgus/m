import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var showSettings = false

    var body: some View {
        TabView {
            IngestView()
                .tabItem { Label("Sessão", systemImage: "waveform") }

            PatientsView()
                .tabItem { Label("Pacientes", systemImage: "person.2") }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { showSettings = true } label: { Label("Ajustes", systemImage: "gearshape") }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var healthMessage: String?
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ajustes").font(.title2.bold())

            VStack(alignment: .leading, spacing: 4) {
                Text("URL da API").font(.caption).foregroundStyle(.secondary)
                TextField("http://localhost:8000", text: $settings.baseURL)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("API key (opcional)").font(.caption).foregroundStyle(.secondary)
                SecureField("Bearer token (se houver proxy)", text: $settings.apiKey)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Testar conexão") { Task { await checkHealth() } }
                    .disabled(checking)
                if checking { ProgressView().controlSize(.small) }
                if let healthMessage {
                    Text(healthMessage).font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()
            HStack {
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 380, minHeight: 280)
    }

    private func checkHealth() async {
        checking = true
        defer { checking = false }
        do {
            let client = try settings.makeClient()
            let h = try await client.health()
            healthMessage = "OK — m_base: \(h["m_base"] ?? "?")"
        } catch {
            healthMessage = "Falhou: \(error.localizedDescription)"
        }
    }
}
