import SwiftUI

/// Configuração persistente do app (URL da API + chave opcional).
final class AppSettings: ObservableObject {
    @AppStorage("m_base_url") var baseURL: String = "http://localhost:8000"
    @AppStorage("m_api_key") var apiKey: String = ""

    /// Constrói um cliente com a config atual (pode lançar se a URL for inválida).
    func makeClient() throws -> APIClient {
        try APIClient(baseURLString: baseURL, apiKey: apiKey)
    }
}
