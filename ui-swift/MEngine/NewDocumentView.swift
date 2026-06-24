import SwiftUI
import UniformTypeIdentifiers

/// Folha para adicionar um documento a uma consulta: escrever uma nota Markdown
/// (criada via `POST …/documents`) ou importar um arquivo do disco
/// (`POST …/files`). Em qualquer dos casos, chama `onCreated` em caso de sucesso.
struct NewDocumentView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    let slug: String
    let consultationId: String
    var onCreated: (() -> Void)? = nil

    @State private var name = "NOTA.md"
    @State private var content = ""

    @State private var showImporter = false
    @State private var saving = false
    @State private var statusText: String?
    @State private var errorText: String?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canCreate: Bool { !trimmedName.isEmpty && !saving }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            VStack(alignment: .leading, spacing: 6) {
                Text("NOME DO ARQUIVO").font(.hosSubhead).foregroundStyle(.secondary)
                TextField("NOTA.md", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.hosMono)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("CONTEÚDO").font(.hosSubhead).foregroundStyle(.secondary)
                TextEditor(text: $content)
                    .font(.hosMono)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .recessedField(cornerRadius: HOS.rXl)
                    .frame(minHeight: 220)
            }

            statusBar

            actions
        }
        .padding(22)
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
        #endif
        .background(.background)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importTypes) { result in
            if case let .success(url) = result {
                Task { await importFile(url) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 22)).foregroundStyle(HOS.blue)
            Text("Novo documento").font(.hosTitle1)
            Spacer()
            StatusPill(text: consultationId, color: HOS.navy, systemImage: "calendar")
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        if let statusText {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                Text(statusText).font(.hosFootnote)
                Spacer()
            }
            .foregroundStyle(HOS.complete)
        } else if let errorText {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(errorText).font(.hosFootnote)
                Spacer()
            }
            .foregroundStyle(HOS.error)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: { ActionLabel("Cancelar", systemImage: "xmark") }
            Button { showImporter = true } label: {
                ActionLabel("Importar arquivo", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .disabled(saving)
            Spacer()
            Button {
                Task { await create() }
            } label: {
                if saving { ProgressView().controlSize(.small) }
                else { ActionLabel("Criar", systemImage: "checkmark") }
            }
            .buttonStyle(.borderedProminent)
            .tint(HOS.blue)
            .disabled(!canCreate)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func create() async {
        saving = true
        errorText = nil
        statusText = nil
        defer { saving = false }
        do {
            let final = try await settings.makeClient()
                .createDocument(slug: slug, consultationId: consultationId,
                                name: trimmedName, content: content)
            statusText = "Documento criado · \(final)"
            onCreated?()
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func importFile(_ url: URL) async {
        saving = true
        errorText = nil
        statusText = nil
        defer { saving = false }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let final = try await settings.makeClient()
                .uploadFile(slug: slug, consultationId: consultationId, fileURL: url)
            statusText = "Arquivo importado · \(final)"
            onCreated?()
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private var importTypes: [UTType] {
        [.plainText, .text, .pdf, .rtf, .audio, .movie, .image, .data]
    }
}
