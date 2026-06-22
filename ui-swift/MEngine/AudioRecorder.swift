import AVFoundation
import Foundation

/// Gravador de áudio multiplataforma (AVAudioRecorder → .m4a/AAC).
/// iOS configura AVAudioSession; macOS dispensa. Permissão de microfone solicitada
/// sob demanda (Info.plist precisa de NSMicrophoneUsageDescription; macOS sandbox
/// precisa do entitlement com.apple.security.device.audio-input).
@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var lastRecordingURL: URL?
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?

    func requestPermission() async -> Bool {
        #if os(iOS)
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { cont in
                AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
            }
        }
        #else
        return await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }

    func start() async {
        errorMessage = nil
        guard await requestPermission() else {
            errorMessage = "Permissão de microfone negada."
            return
        }

        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)
        } catch {
            errorMessage = "Falha ao ativar sessão de áudio: \(error.localizedDescription)"
            return
        }
        #endif

        let filename = "sessao_\(Int(Date().timeIntervalSince1970)).m4a"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.delegate = self
            guard rec.record() else {
                errorMessage = "Não foi possível iniciar a gravação."
                return
            }
            recorder = rec
            lastRecordingURL = url
            isRecording = true
        } catch {
            errorMessage = "Erro ao gravar: \(error.localizedDescription)"
        }
    }

    /// Para a gravação e devolve o arquivo gravado.
    @discardableResult
    func stop() -> URL? {
        recorder?.stop()
        recorder = nil
        isRecording = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif
        return lastRecordingURL
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            Task { @MainActor in self.errorMessage = "A gravação terminou com erro." }
        }
    }
}
