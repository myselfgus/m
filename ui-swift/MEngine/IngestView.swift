import SwiftUI
import UniformTypeIdentifiers

/// Tela "Sessão": grava ou seleciona um áudio, envia e dispara o pipeline,
/// acompanhando o job por polling até concluir.
struct IngestView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var recorder = AudioRecorder()

    @State private var selectedFile: URL?
    @State private var showImporter = false
    @State private var model: ModelChoice = .padrao
    @State private var deep = true

    @State private var phase: Phase = .idle
    @State private var statusText = ""
    @State private var resultPath: String?
    @State private var errorText: String?

    enum Phase: Equatable { case idle, uploading, processing, done, failed }

    /// Áudio "ativo": gravado ou selecionado.
    private var activeAudio: URL? { selectedFile ?? recorder.lastRecordingURL }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Nova sessão").font(.largeTitle.bold())

                recordingCard
                fileCard
                optionsCard
                actionSection
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: audioTypes) { result in
            if case let .success(url) = result { selectedFile = url }
        }
    }

    // MARK: - Seções

    private var recordingCard: some View {
        GroupBox("Gravar") {
            HStack(spacing: 16) {
                Button {
                    Task { recorder.isRecording ? stopRecording() : await recorder.start() }
                } label: {
                    Label(
                        recorder.isRecording ? "Parar" : "Gravar",
                        systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle"
                    )
                    .font(.title3)
                }
                .tint(recorder.isRecording ? .red : .accentColor)

                if recorder.isRecording {
                    Label("Gravando…", systemImage: "waveform").foregroundStyle(.red)
                }
                if let msg = recorder.errorMessage {
                    Text(msg).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(6)
        }
    }

    private var fileCard: some View {
        GroupBox("Arquivo") {
            HStack {
                Button { showImporter = true } label: { Label("Selecionar áudio…", systemImage: "folder") }
                Spacer()
                if let activeAudio {
                    Text(activeAudio.lastPathComponent).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(6)
        }
    }

    private var optionsCard: some View {
        GroupBox("Opções") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Modelo", selection: $model) {
                    ForEach(ModelChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Análise profunda (ASL → VDLP → GEM → SOAP)", isOn: $deep)
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        Button {
            Task { await process() }
        } label: {
            Label("Enviar e processar", systemImage: "paperplane.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(activeAudio == nil || phase == .uploading || phase == .processing)

        switch phase {
        case .uploading, .processing:
            HStack { ProgressView().controlSize(.small); Text(statusText) }
        case .done:
            VStack(alignment: .leading, spacing: 4) {
                Label("Concluído", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                if let resultPath { Text(resultPath).font(.caption).foregroundStyle(.secondary) }
            }
        case .failed:
            Label(errorText ?? "Erro", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        case .idle:
            EmptyView()
        }
    }

    // MARK: - Lógica

    private func stopRecording() {
        recorder.stop()
        selectedFile = nil // grava nova; o recorder vira o áudio ativo
    }

    private func process() async {
        guard let audio = activeAudio else { return }
        errorText = nil
        resultPath = nil
        let accessing = audio.startAccessingSecurityScopedResource()
        defer { if accessing { audio.stopAccessingSecurityScopedResource() } }

        do {
            let client = try settings.makeClient()

            phase = .uploading
            statusText = "Enviando áudio…"
            let uploaded = try await client.uploadAudio(fileURL: audio)

            phase = .processing
            statusText = "Disparando pipeline…"
            let job = try await client.startPipeline(audioPath: uploaded.path, deep: deep, model: model.apiValue)

            try await pollUntilDone(client: client, jobId: job.jobId)
        } catch {
            phase = .failed
            errorText = error.localizedDescription
        }
    }

    private func pollUntilDone(client: APIClient, jobId: String) async throws {
        while true {
            let st = try await client.jobStatus(jobId)
            statusText = "Processando (\(st.status))…"
            if st.ready {
                if st.successful == true {
                    phase = .done
                    resultPath = st.result
                } else {
                    phase = .failed
                    errorText = st.error ?? "Job falhou."
                }
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000_000) // 5s
        }
    }

    // .audio cobre m4a/mp3/wav/aac/flac/ogg; .movie cobre mp4/mov. A API valida a extensão.
    private var audioTypes: [UTType] { [.audio, .movie] }
}
