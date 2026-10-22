import Foundation
import Security

enum CredentialField: String, Sendable { case apiKey, apiSecret }

/// Stores connection credentials in Tincall's dedicated Keychain service.
struct CredentialStore: Sendable {
    private let service = "com.tincall.app.connections"

    func read(connectionID: UUID, field: CredentialField = .apiKey) throws -> String? {
        guard let data = try readData(query(connectionID: connectionID, field: field)) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else { throw failure(errSecDecode) }
        return value
    }

    func readMCPConfiguration(connectionID: UUID, roleID: UUID) throws -> MCPRoleConfiguration? {
        guard let data = try readData(mcpQuery(connectionID: connectionID, roleID: roleID)) else { return nil }
        do { return try JSONDecoder().decode(MCPRoleConfiguration.self, from: data) }
        catch { throw TincallError(message: String(localized: "已保存的联系人 MCP 配置无法读取，请重新保存联系人以恢复。")) }
    }

    func writeMCPConfiguration(_ value: MCPRoleConfiguration, connectionID: UUID, roleID: UUID) throws {
        try writeData(JSONEncoder().encode(value), query: mcpQuery(connectionID: connectionID, roleID: roleID))
    }

    func deleteMCPConfiguration(connectionID: UUID, roleID: UUID) throws {
        let status = SecItemDelete(mcpQuery(connectionID: connectionID, roleID: roleID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }

    private func readData(_ baseQuery: [String: Any]) throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        return data
    }

    /// Read only metadata so settings can show saved state without loading the secret.
    func savedAt(connectionID: UUID, field: CredentialField = .apiKey) throws -> Date? {
        var query = query(connectionID: connectionID, field: field)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw failure(status) }
        guard let attributes = result as? [String: Any],
              let date = attributes[kSecAttrModificationDate as String] as? Date else {
            throw TincallError(message: String(localized: "无法读取凭据保存时间"))
        }
        return date
    }

    func write(_ value: String, connectionID: UUID, field: CredentialField = .apiKey) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { try delete(connectionID: connectionID, field: field); return }
        try writeData(Data(value.utf8), query: query(connectionID: connectionID, field: field))
    }

    private func writeData(_ data: Data, query: [String: Any]) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess { throw failure(status) }
    }

    func delete(connectionID: UUID, field: CredentialField = .apiKey) throws {
        let status = SecItemDelete(query(connectionID: connectionID, field: field) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }

    // Installation recovery contains only generated phone/worker tokens and progress.
    // Management PATs and project service keys must never be passed here.
    func readCloudDeployment(projectRef: String) throws -> Data? {
        try readData(query(account: "cloud-deployment.\(projectRef)"))
    }

    func writeCloudDeployment(_ data: Data, projectRef: String) throws {
        try writeData(data, query: query(account: "cloud-deployment.\(projectRef)"))
    }

    private func query(connectionID: UUID, field: CredentialField) -> [String: Any] {
        query(account: "\(connectionID.uuidString).\(field.rawValue)")
    }

    private func mcpQuery(connectionID: UUID, roleID: UUID) -> [String: Any] {
        query(account: "\(connectionID.uuidString).role.\(roleID.uuidString).mcp")
    }

    private func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func failure(_ status: OSStatus) -> TincallError {
        TincallError(message: String(localized: "安全凭据存储失败（\(status)）"))
    }
}
