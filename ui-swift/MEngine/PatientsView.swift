import SwiftUI

/// Tela "Pacientes": lista os dossiês, seus documentos e abre a nota (.md) renderizada.
struct PatientsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var patients: [String] = []
    @State private var loading = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Carregando…")
                } else if let errorText {
                    ContentUnavailableView("Erro", systemImage: "exclamationmark.triangle", description: Text(errorText))
                } else if patients.isEmpty {
                    ContentUnavailableView("Nenhum paciente", systemImage: "person.crop.circle.badge.questionmark")
                } else {
                    List(patients, id: \.self) { pid in
                        NavigationLink(pid) { DocumentsListView(patientId: pid) }
                    }
                }
            }
            .navigationTitle("Pacientes")
            .toolbar {
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            patients = try await settings.makeClient().patients()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct DocumentsListView: View {
    @EnvironmentObject private var settings: AppSettings
    let patientId: String
    @State private var documents: [String] = []
    @State private var loading = false
    @State private var errorText: String?

    var body: some View {
        Group {
            if loading {
                ProgressView()
            } else if let errorText {
                ContentUnavailableView("Erro", systemImage: "exclamationmark.triangle", description: Text(errorText))
            } else if documents.isEmpty {
                ContentUnavailableView("Sem documentos", systemImage: "doc")
            } else {
                List(documents, id: \.self) { name in
                    NavigationLink {
                        DocumentDetailView(patientId: patientId, name: name)
                    } label: {
                        Label(name, systemImage: icon(for: name))
                    }
                }
            }
        }
        .navigationTitle(patientId)
        .task { await load() }
    }

    private func icon(for name: String) -> String {
        if name.contains("BIRP") { return "bolt.heart" }
        if name.contains("SOAP_LONG") { return "chart.line.uptrend.xyaxis" }
        if name.contains("SOAP") { return "doc.text" }
        return "doc"
    }

    private func load() async {
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            documents = try await settings.makeClient().documents(patientId: patientId)
        } catch {
            errorText = error.localizedDescription
        }
    }
}

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
                ProgressView().padding()
            } else if let errorText {
                Text(errorText).foregroundStyle(.red).padding()
            } else {
                MarkdownText(text: content).padding(20)
            }
        }
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
