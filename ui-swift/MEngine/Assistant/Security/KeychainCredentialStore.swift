import Foundation
import Security

// MARK: - KeychainCredentialStore — guarda a chave da Anthropic no Keychain.
//
// Transporte B (Messages API direto) precisa da chave no app. NUNCA embarcar no
// binário: o usuário cola a chave em Ajustes e ela vive no Keychain (peça técnica §11).
// Em produção, o caminho recomendado é um relay `.proxied` (chave server-side) — fora do P0.

struct KeychainCredentialStore: Sendable {
    /// Conta/serviço usados no item do Keychain.
    private let service = "com.voither.mengine.anthropic"
    private let account = "anthropic-api-key"

    init() {}

    /// Lê a chave da Anthropic; lança `AgentError.missingAPIKey` se ausente.
    func apiKey() throws -> String {
        guard let key = readAPIKey(), !key.isEmpty else { throw AgentError.missingAPIKey }
        return key
    }

    /// Há uma chave salva?
    var hasAPIKey: Bool { (readAPIKey()?.isEmpty == false) }

    func readAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    /// Salva (ou substitui) a chave. Passar vazio/nil remove.
    @discardableResult
    func setAPIKey(_ key: String?) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let key, !key.isEmpty, let data = key.data(using: .utf8) else { return true }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
