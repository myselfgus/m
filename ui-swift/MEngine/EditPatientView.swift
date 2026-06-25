import SwiftUI

/// Folha de edição de paciente apresentada a partir da sidebar (que só conhece o
/// `slug`). Busca o perfil editável via `GET /patients/{slug}/profile` e, então,
/// reaproveita o `ProfileEditorView` existente para a edição. Em sucesso, chama
/// `onSaved` para que a sidebar atualize a listagem.
struct EditPatientView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    let slug: String
    /// Chamado quando o perfil é salvo com sucesso (para atualizar a sidebar).
    var onSaved: () -> Void = {}

    @State private var profile: PatientProfile?
    @State private var loading = true
    @State private var errorText: String?

    var body: some View {
        Group {
            if let profile {
                ProfileEditorView(profile: profile) { _ in
                    onSaved()
                }
            } else if loading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Carregando perfil…").font(.hosFootnote).foregroundStyle(.secondary)
                }
                .padding(40)
            } else {
                VStack(spacing: 14) {
                    ContentUnavailableView(
                        "Erro",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorText ?? "Não foi possível carregar o perfil.")
                    )
                    Button { dismiss() } label: {
                        ActionLabel("Fechar", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(22)
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 420)
        #endif
        .background(.background)
        .task { await load() }
    }

    private func load() async {
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            profile = try await settings.makeClient().fetchProfile(slug: slug)
        } catch {
            errorText = error.localizedDescription
        }
    }
}
