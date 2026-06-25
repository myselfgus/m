import SwiftUI
import UniformTypeIdentifiers

/// "Nova sessão": grava ou seleciona um áudio, envia, dispara o pipeline e acompanha
/// o job por polling. Estilo HealthOS (glass cards, capsules, stage tints).
struct NewSessionView: View {
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

    private var activeAudio: URL? { selectedFile ?? recorder.lastRecordingURL }
    private var busy: Bool { phase == .uploading || phase == .processing }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HOS.s5) {
                SheetHeader("Nova sessão",
                            subtitle: "Áudio → transcrição → BIRP ∥ ASL · VDLP · GEM · SOAP",
                            systemImage: "waveform.badge.mic", tint: HOS.stSpeech)

                pipelineTrack
                recordingCard
                fileCard
                optionsCard
                actionSection
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
        .navigationTitle("Nova sessão")
        .fileImporter(isPresented: $showImporter, allowedContentTypes: audioTypes) { result in
            if case let .success(url) = result { selectedFile = url }
        }
    }

    // MARK: - Stage track (legenda visual do pipeline)

    private var pipelineTrack: some View {
        let stages: [(String, Color)] = [
            ("STT", HOS.stStt), ("PROC", HOS.stProc), ("BIRP", HOS.stProc),
            ("ASL", HOS.stAsl), ("VDLP", HOS.stVdlp), ("GEM", HOS.stGem), ("SOAP", HOS.navy)
        ]
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(stages.enumerated()), id: \.offset) { i, s in
                    StatusPill(text: s.0, color: s.1)
                    if i < stages.count - 1 {
                        Image(systemName: "chevron.compact.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: - Cards

    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Gravar", systemImage: "mic.fill").font(.hosTitle3).foregroundStyle(HOS.stSpeech)
            HStack(spacing: HOS.s4) {
                Button {
                    Task { recorder.isRecording ? stopRecording() : await recorder.start() }
                } label: {
                    Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 54, height: 54)
                        .contentShape(Circle())
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Circle())
                .tint(recorder.isRecording ? HOS.error : HOS.blue)
                .accessibilityLabel(recorder.isRecording ? "Parar" : "Gravar")

                if recorder.isRecording {
                    StatusPill(text: "Gravando", color: HOS.error, systemImage: "waveform")
                }
                if let msg = recorder.errorMessage {
                    Text(msg).font(.hosFootnote).foregroundStyle(HOS.error)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .healthCard()
    }

    private var fileCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Arquivo", systemImage: "folder.fill").font(.hosTitle3).foregroundStyle(HOS.stStt)
            HStack {
                Button { showImporter = true } label: { ActionLabel("Selecionar áudio…", systemImage: "doc.badge.plus") }
                    .buttonStyle(.bordered)
                Spacer()
                if let activeAudio {
                    Text(activeAudio.lastPathComponent)
                        .font(.hosMono).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .healthCard()
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Opções", systemImage: "slider.horizontal.3").font(.hosTitle3).foregroundStyle(HOS.stProc)
            Picker("Modelo", selection: $model) {
                ForEach(ModelChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle(isOn: $deep) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Análise profunda").font(.hosHeadline)
                    Text("ASL → VDLP → GEM → SOAP").font(.hosCaption).foregroundStyle(.secondary)
                }
            }
            .tint(HOS.blue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .healthCard()
    }

    @ViewBuilder
    private var actionSection: some View {
        Button {
            Task { await process() }
        } label: {
            ActionLabel("Enviar e processar", systemImage: "paperplane.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(HOS.blue)
        .controlSize(.large)
        .disabled(activeAudio == nil || busy)

        switch phase {
        case .uploading, .processing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(statusText).font(.hosBody)
                Spacer()
                StatusPill(text: phase == .uploading ? "Enviando" : "Processando", color: HOS.running)
            }
            .healthCard(padding: 12)
        case .done:
            VStack(alignment: .leading, spacing: 6) {
                StatusPill(text: "Concluído", color: HOS.complete, systemImage: "checkmark.seal.fill")
                if let resultPath { Text(resultPath).font(.hosMono).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .healthCard(padding: 12)
        case .failed:
            HStack(spacing: 10) {
                StatusPill(text: "Erro", color: HOS.error, systemImage: "xmark.octagon.fill")
                Text(errorText ?? "Falha").font(.hosFootnote).foregroundStyle(HOS.error)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .healthCard(padding: 12)
        case .idle:
            EmptyView()
        }
    }

    // MARK: - Lógica

    private func stopRecording() {
        recorder.stop()
        selectedFile = nil
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
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private var audioTypes: [UTType] { [.audio, .movie] }
}
