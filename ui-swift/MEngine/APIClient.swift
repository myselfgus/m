import Foundation

/// Erros de rede/decodificação da API.
enum APIError: LocalizedError {
    case badURL
    case http(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "URL base inválida."
        case let .http(code, body): return "HTTP \(code): \(body)"
        case let .decoding(msg): return "Falha ao decodificar: \(msg)"
        }
    }
}

/// Cliente assíncrono da API M-Engine (FastAPI). Stateless; recebe baseURL + apiKey.
struct APIClient {
    let baseURL: URL
    let apiKey: String?

    init(baseURLString: String, apiKey: String?) throws {
        guard let url = URL(string: baseURLString) else { throw APIError.badURL }
        self.baseURL = url
        self.apiKey = (apiKey?.isEmpty == false) ? apiKey : nil
    }

    // MARK: - Infra

    private func makeRequest(_ path: String, method: String = "GET") -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        if let apiKey { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return req
    }

    private func send<T: Decodable>(_ req: URLRequest, as _: T.Type) async throws -> T {
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    // MARK: - Endpoints

    func health() async throws -> [String: String] {
        try await send(makeRequest("healthz"), as: [String: String].self)
    }

    /// Sobe o áudio para $M_BASE/audio (multipart/form-data, campo "file").
    func uploadAudio(fileURL: URL) async throws -> UploadResponse {
        var req = makeRequest("audio", method: "POST")
        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let filename = fileURL.lastPathComponent
        let mime = Self.mimeType(for: fileURL.pathExtension)
        let fileData = try Data(contentsOf: fileURL)

        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mime)\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n")

        let (data, resp) = try await URLSession.shared.upload(for: req, from: body)
        try Self.check(resp, data)
        do { return try JSONDecoder().decode(UploadResponse.self, from: data) }
        catch { throw APIError.decoding(error.localizedDescription) }
    }

    /// Dispara o pipeline completo (transcribe → birp + normalize→asl→dim→gem→soap).
    func startPipeline(audioPath: String, deep: Bool, model: String?) async throws -> JobResponse {
        var req = makeRequest("jobs/pipeline", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["audio_path": audioPath, "deep": deep]
        if let model { payload["model"] = model }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return try await send(req, as: JobResponse.self)
    }

    func jobStatus(_ jobId: String) async throws -> JobStatus {
        try await send(makeRequest("jobs/\(jobId)"), as: JobStatus.self)
    }

    func patients() async throws -> [String] {
        try await send(makeRequest("patients"), as: PatientsResponse.self).patients
    }

    func documents(patientId: String) async throws -> [String] {
        let path = "patients/\(patientId)/documents"
        return try await send(makeRequest(path), as: DocumentsResponse.self).documents
    }

    /// Conteúdo Markdown de um documento clínico (text/plain).
    func document(patientId: String, name: String) async throws -> String {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let req = makeRequest("patients/\(patientId)/documents/\(encoded)")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Resumo do dossiê (`/patients/{id}/info`). Parse defensivo: tolera variações de schema.
    func patientInfo(patientId: String) async throws -> PatientInfo {
        let req = makeRequest("patients/\(patientId)/info")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        var info = PatientInfo()
        info.patientId = patientId
        info.name = (obj["patient_name"] ?? obj["name"]) as? String

        if let sessions = obj["sessions"] as? [Any] {
            info.sessionCount = sessions.count
            if let last = sessions.last as? [String: Any] {
                info.lastSession = (last["date"] ?? last["timestamp"] ?? last["session_id"]) as? String
            }
        } else if let n = obj["session_count"] as? Int {
            info.sessionCount = n
        }

        // clinical_summary pode estar aninhado ou no topo.
        let cs = (obj["clinical_summary"] as? [String: Any]) ?? obj
        func strings(_ keys: [String]) -> [String] {
            for k in keys {
                if let arr = cs[k] as? [String] { return arr }
                if let arr = cs[k] as? [Any] { return arr.compactMap { $0 as? String } }
            }
            return []
        }
        info.icdCodes = strings(["all_icd_codes", "icd_codes", "cid", "diagnoses"])
        info.medications = strings(["all_medications", "medications", "medicamentos"])
        info.topics = strings(["common_topics", "topics", "topicos"])
        info.summary = (cs["summary"] ?? cs["narrative"] ?? cs["resumo"]) as? String

        return info
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "m4a", "mp4": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "ogg": return "audio/ogg"
        case "webm": return "audio/webm"
        case "mov": return "video/quicktime"
        default: return "application/octet-stream"
        }
    }
}
