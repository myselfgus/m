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

    // MARK: - Pacientes (modelo slug + nome)

    /// Lista de pacientes: slug, nome de exibição e contagem de consultas.
    func fetchPatients() async throws -> [Patient] {
        try await send(makeRequest("patients"), as: PatientsResponse.self).patients
    }

    /// Perfil editável do paciente (`/patients/{slug}/profile`).
    func fetchProfile(slug: String) async throws -> PatientProfile {
        let s = Self.escape(slug)
        return try await send(makeRequest("patients/\(s)/profile"), as: PatientProfile.self)
    }

    /// Atualiza o perfil (PUT com os campos editáveis) e devolve o perfil atualizado.
    @discardableResult
    func updateProfile(slug: String, profile: PatientProfile) async throws -> PatientProfile {
        let s = Self.escape(slug)
        var req = makeRequest("patients/\(s)/profile", method: "PUT")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: profile.editablePayload())
        return try await send(req, as: PatientProfile.self)
    }

    /// Perfil do profissional (global, `GET /professional`). Vazio se não definido.
    func fetchProfessional() async throws -> Professional {
        (try? await send(makeRequest("professional"), as: Professional.self)) ?? Professional()
    }

    /// Salva (PUT) o perfil do profissional e devolve o atualizado.
    @discardableResult
    func saveProfessional(_ prof: Professional) async throws -> Professional {
        var req = makeRequest("professional", method: "PUT")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(prof)
        return try await send(req, as: Professional.self)
    }

    /// Consultas do paciente, agrupadas em C1/C2/C3… (`/patients/{slug}/consultations`).
    func fetchConsultations(slug: String) async throws -> [Consultation] {
        let s = Self.escape(slug)
        let path = "patients/\(s)/consultations"
        return try await send(makeRequest(path), as: ConsultationsResponse.self).consultations
    }

    /// Conteúdo Markdown de um documento de uma consulta (text/plain).
    func fetchDocument(slug: String, consultationId: String, name: String) async throws -> String {
        let s = Self.escape(slug)
        let cid = Self.escape(consultationId)
        let n = Self.escape(name)
        let req = makeRequest("patients/\(s)/consultations/\(cid)/documents/\(n)")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Salva (PUT) o conteúdo Markdown de um documento de consulta.
    @discardableResult
    func saveDocument(slug: String, consultationId: String, name: String, content: String) async throws -> Int {
        let s = Self.escape(slug)
        let cid = Self.escape(consultationId)
        let n = Self.escape(name)
        var req = makeRequest("patients/\(s)/consultations/\(cid)/documents/\(n)", method: "PUT")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["content": content])
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (obj?["bytes"] as? Int) ?? content.utf8.count
    }

    // MARK: - Criação (paciente / consulta / documento / arquivo)

    /// Cria um paciente (`POST /patients`) e devolve o perfil resultante.
    func createPatient(_ req: CreatePatientRequest) async throws -> PatientProfile {
        var r = makeRequest("patients", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: req.jsonPayload())
        return try await send(r, as: PatientProfile.self)
    }

    /// Cria uma consulta para o paciente (`POST /patients/{slug}/consultations`).
    /// Envia `{date}` quando informado.
    func createConsultation(slug: String, date: String?) async throws -> ConsultationCreated {
        let s = Self.escape(slug)
        var r = makeRequest("patients/\(s)/consultations", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = [:]
        if let date { payload["date"] = date }
        r.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return try await send(r, as: ConsultationCreated.self)
    }

    /// Cria um documento Markdown numa consulta
    /// (`POST /patients/{slug}/consultations/{cid}/documents`). Devolve o nome final.
    @discardableResult
    func createDocument(slug: String, consultationId: String, name: String, content: String) async throws -> String {
        let s = Self.escape(slug)
        let cid = Self.escape(consultationId)
        var r = makeRequest("patients/\(s)/consultations/\(cid)/documents", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "content": content])
        let (data, resp) = try await URLSession.shared.data(for: r)
        try Self.check(resp, data)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (obj?["name"] as? String) ?? name
    }

    /// Sobe um arquivo arbitrário para uma consulta
    /// (`POST /patients/{slug}/consultations/{cid}/files`, multipart campo "file").
    /// Devolve o nome do arquivo gravado.
    func uploadFile(slug: String, consultationId: String, fileURL: URL) async throws -> String {
        let s = Self.escape(slug)
        let cid = Self.escape(consultationId)
        var req = makeRequest("patients/\(s)/consultations/\(cid)/files", method: "POST")
        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let filename = fileURL.lastPathComponent
        let mime = Self.mimeType(for: fileURL.pathExtension)
        let fileData = try Data(contentsOf: fileURL)

        var body = Data()
        func append(_ str: String) { body.append(str.data(using: .utf8)!) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mime)\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n")

        let (data, resp) = try await URLSession.shared.upload(for: req, from: body)
        try Self.check(resp, data)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (obj?["filename"] as? String) ?? filename
    }

    // MARK: - Stages / jobs

    /// Lista os stages disponíveis (`GET /stages` → {stages:[...]}).
    func fetchStages() async throws -> [StageInfo] {
        struct StagesResponse: Decodable { let stages: [StageInfo] }
        return try await send(makeRequest("stages"), as: StagesResponse.self).stages
    }

    /// Enfileira um stage individual (`POST /jobs/{stage}`).
    /// Corpo: {patient_id: slug, date, model?, force}.
    func enqueueStage(_ stage: String, slug: String, date: String, model: String?, force: Bool) async throws -> JobResponse {
        let st = Self.escape(stage)
        var r = makeRequest("jobs/\(st)", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["patient_id": slug, "date": date, "force": force]
        if let model { payload["model"] = model }
        r.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return try await send(r, as: JobResponse.self)
    }

    // MARK: - Exclusão (paciente / consulta / documento)

    /// Apaga (soft-delete → lixeira) um paciente (`DELETE /patients/{slug}`).
    func deletePatient(slug: String) async throws {
        let s = Self.escape(slug)
        let req = makeRequest("patients/\(s)", method: "DELETE")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
    }

    /// Apaga uma consulta do paciente
    /// (`DELETE /patients/{slug}/consultations/{cid}`).
    func deleteConsultation(slug: String, consultationId: String) async throws {
        let s = Self.escape(slug)
        let cid = Self.escape(consultationId)
        let req = makeRequest("patients/\(s)/consultations/\(cid)", method: "DELETE")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
    }

    /// Apaga um documento de uma consulta
    /// (`DELETE /patients/{slug}/consultations/{cid}/documents/{name}`).
    func deleteDocument(slug: String, consultationId: String, name: String) async throws {
        let s = Self.escape(slug)
        let cid = Self.escape(consultationId)
        let n = Self.escape(name)
        let req = makeRequest("patients/\(s)/consultations/\(cid)/documents/\(n)", method: "DELETE")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
    }

    private static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
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
