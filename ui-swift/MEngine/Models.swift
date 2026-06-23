import Foundation

// Respostas da API M-Engine (espelham os modelos Pydantic em m_engine/api.py).

struct UploadResponse: Codable {
    let filename: String
    let path: String
}

struct JobResponse: Codable {
    let jobId: String
    let stage: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case stage
        case status
    }
}

struct JobStatus: Codable {
    let jobId: String
    let status: String
    let ready: Bool
    let successful: Bool?
    let result: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case status, ready, successful, result, error
    }
}

// MARK: - Modelo de paciente (slug legível + nome editável)

/// Paciente como aparece na listagem. Identificado por `slug` (estável),
/// exibido pelo `displayName`. `consultationCount` = número de consultas (C1/C2/…).
struct Patient: Codable, Identifiable, Hashable {
    let slug: String
    let displayName: String
    let consultationCount: Int

    var id: String { slug }

    enum CodingKeys: String, CodingKey {
        case slug
        case displayName = "display_name"
        case consultationCount = "consultation_count"
    }

    init(slug: String, displayName: String, consultationCount: Int) {
        self.slug = slug
        self.displayName = displayName
        self.consultationCount = consultationCount
    }

    /// Decodificação defensiva: tolera ausência de display_name/consultation_count.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let slug = try c.decode(String.self, forKey: .slug)
        self.slug = slug
        self.displayName = (try? c.decode(String.self, forKey: .displayName)) ?? slug
        self.consultationCount = (try? c.decode(Int.self, forKey: .consultationCount)) ?? 0
    }
}

struct PatientsResponse: Codable {
    let patients: [Patient]
}

/// Perfil editável do paciente. Campos opcionais decodificam de forma defensiva.
/// Os campos editáveis (`fullName`, `cpf`, `phone`, `birthdate`, `email`, `notes`)
/// são enviados no PUT; os demais são somente-leitura vindos do servidor.
struct PatientProfile: Codable, Hashable {
    let slug: String
    var displayName: String
    var fullName: String?
    var cpf: String?
    var phone: String?
    var birthdate: String?
    var age: Int?
    var email: String?
    var notes: String?
    var professional: String?
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case slug
        case displayName = "display_name"
        case fullName = "full_name"
        case cpf
        case phone
        case birthdate
        case age
        case email
        case notes
        case professional
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = (try? c.decode(String.self, forKey: .slug)) ?? ""
        displayName = (try? c.decode(String.self, forKey: .displayName)) ?? slug
        fullName = try? c.decodeIfPresent(String.self, forKey: .fullName)
        cpf = try? c.decodeIfPresent(String.self, forKey: .cpf)
        phone = try? c.decodeIfPresent(String.self, forKey: .phone)
        birthdate = try? c.decodeIfPresent(String.self, forKey: .birthdate)
        // `age` pode chegar como número ou string.
        if let n = try? c.decodeIfPresent(Int.self, forKey: .age) {
            age = n
        } else if let s = try? c.decodeIfPresent(String.self, forKey: .age) {
            age = Int(s)
        } else {
            age = nil
        }
        email = try? c.decodeIfPresent(String.self, forKey: .email)
        notes = try? c.decodeIfPresent(String.self, forKey: .notes)
        professional = try? c.decodeIfPresent(String.self, forKey: .professional)
        createdAt = try? c.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try? c.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    /// Corpo do PUT: apenas os campos editáveis pelo profissional.
    func editablePayload() -> [String: Any] {
        var p: [String: Any] = ["display_name": displayName]
        if let fullName { p["full_name"] = fullName }
        if let cpf { p["cpf"] = cpf }
        if let phone { p["phone"] = phone }
        if let birthdate { p["birthdate"] = birthdate }
        if let age { p["age"] = age }
        if let email { p["email"] = email }
        if let notes { p["notes"] = notes }
        return p
    }
}

/// Uma consulta (C1/C2/C3…) com data e lista de documentos Markdown.
struct Consultation: Codable, Identifiable, Hashable {
    let id: String          // "C1", "C2", …
    let date: String?
    let source: String?
    let tags: [String]
    let processedAt: String?
    let documents: [String] // nomes de arquivos .md

    enum CodingKeys: String, CodingKey {
        case id
        case date
        case source
        case tags
        case processedAt = "processed_at"
        case documents
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? "C?"
        date = try? c.decodeIfPresent(String.self, forKey: .date)
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        tags = (try? c.decodeIfPresent([String].self, forKey: .tags)) ?? []
        processedAt = try? c.decodeIfPresent(String.self, forKey: .processedAt)
        documents = (try? c.decodeIfPresent([String].self, forKey: .documents)) ?? []
    }
}

struct ConsultationsResponse: Codable {
    let slug: String
    let consultations: [Consultation]
}

/// Resumo do dossiê (info.json) — decodificado de forma defensiva no APIClient,
/// pois o schema pode variar entre versões do pipeline.
struct PatientInfo {
    var name: String?
    var patientId: String?
    var sessionCount: Int = 0
    var icdCodes: [String] = []
    var medications: [String] = []
    var topics: [String] = []
    var summary: String?
    var lastSession: String?
}

/// Alias de modelo enviado ao pipeline. `nil` => cada stage usa seu default
/// (birp/normalize/soap → Sonnet; asl/dimensional/gem → Opus 4.8).
enum ModelChoice: String, CaseIterable, Identifiable {
    case padrao = "Padrão (por stage)"
    case opus = "Opus 4.8"
    case sonnet = "Sonnet 4.6"
    case claudeCode = "Claude Code (cc)"

    var id: String { rawValue }

    /// Valor enviado à API (`model`). `nil` quando padrão.
    var apiValue: String? {
        switch self {
        case .padrao: return nil
        case .opus: return "opus"
        case .sonnet: return "sonnet"
        case .claudeCode: return "cc"
        }
    }
}
