import SwiftUI

/// Configuração persistente do app (URL da API + chave opcional).
final class AppSettings: ObservableObject {
    // VM M-Engine na tailnet (uvicorn faz bind em 100.105.208.96:8000, não em loopback).
    // Chave "_v2": reseta valores antigos persistidos (ex.: localhost) para este default.
    @AppStorage("m_base_url_v2") var baseURL: String = "http://100.105.208.96:8000"
    @AppStorage("m_api_key") var apiKey: String = ""

    /// Constrói um cliente com a config atual (pode lançar se a URL for inválida).
    func makeClient() throws -> APIClient {
        try APIClient(baseURLString: baseURL, apiKey: apiKey)
    }
}
