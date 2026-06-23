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

struct PatientsResponse: Codable {
    let patients: [String]
}

struct DocumentsResponse: Codable {
    let patientId: String
    let documents: [String]

    enum CodingKeys: String, CodingKey {
        case patientId = "patient_id"
        case documents
    }
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
