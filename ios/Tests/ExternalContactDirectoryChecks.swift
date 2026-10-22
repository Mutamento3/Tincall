// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

@main
struct ExternalContactDirectoryChecks {
    static func main() throws {
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(ExternalContactDirectory.self, from: Data(#"{"bindings":[{"contact_id":"legacy-role","generation_configured":true}]}"#.utf8))
        precondition(legacy.contacts.first?.displayName == "legacy-role")
        precondition(legacy.selection(preserving: nil) == "legacy-role")

        let named = try decoder.decode(ExternalContactDirectory.self, from: Data(#"{"bindings":[{"contact_id":"role-a","display_name":"  示例角色甲  ","generation_configured":true},{"contact_id":"role-b","display_name":"示例角色乙","generation_configured":true},{"contact_id":"unfinished","generation_configured":false}]}"#.utf8))
        precondition(named.contacts.map(\.id) == ["role-a", "role-b"])
        precondition(named.contacts.first?.displayName == "示例角色甲")
        precondition(named.selection(preserving: nil) == nil, "Several roles require an explicit selection")
        precondition(named.selection(preserving: "role-b") == "role-b")
        precondition(legacy.selection(preserving: "temporarily-unavailable") == "temporarily-unavailable", "Never silently switch an existing contact to another role")

        let empty = try decoder.decode(ExternalContactDirectory.self, from: Data(#"{"bindings":[]}"#.utf8))
        precondition(empty.selection(preserving: nil) == nil)
        precondition(empty.selection(preserving: "saved") == "saved")
        let mixed = try decoder.decode(ExternalContactDirectory.self, from: Data(#"{"bindings":[{"contact_id":"mcp-role","mode":"tools","generation_configured":true},{"contact_id":"backend-role","mode":"http","generation_configured":true}]}"#.utf8))
        precondition(mixed.contacts.map(\.id) == ["mcp-role", "backend-role"], "MCP discovery must retain its existing entries")
        precondition(mixed.selection(preserving: nil) == "backend-role", "Backend selection must ignore MCP tool identities")
        precondition(mixed.selection(preserving: "mcp-role") == nil, "Backend mode must not retain an explicitly incompatible MCP identity or silently select another contact")
        precondition(mixed.selection(preserving: "temporarily-unavailable") == "temporarily-unavailable")
        var profile = ConnectionProfile(name: "Example connection", provider: .genericConnector)
        profile.externalRoleID = "configured-target"
        profile.externalRoleName = "Example target"
        let restored = try decoder.decode(ConnectionProfile.self, from: JSONEncoder().encode(profile))
        precondition(restored == profile, "The entire target configuration must survive persistence and backup encoding")
        var role = CallRole(name: "Example contact", externalConnectionID: profile.id)
        precondition(role.externalRoleID == nil)
        precondition(role.externalRoleID == nil, "New contacts never inherit a service-wide identity")
        role.externalRoleID = "legacy-target"
        precondition(role.externalRoleID == "legacy-target", "A contact-specific identity takes precedence over a shared default")
        let oldProfile = try decoder.decode(ConnectionProfile.self, from: Data(#"{"id":"00000000-0000-4000-8000-000000000001","name":"Legacy connection","provider":"genericConnector","model":"","applicationID":"","voiceID":""}"#.utf8))
        precondition(oldProfile.externalRoleID == nil)
        precondition(role.externalRoleID == "legacy-target", "Old contact mappings remain usable")
        precondition(legacy.mcp_role_management == nil, "Old services remain readable")
        let managed = try decoder.decode(ExternalContactDirectory.self, from: Data(#"{"bindings":[],"mcp_role_management":true}"#.utf8))
        precondition(managed.mcp_role_management == true)
        var first = CallRole(name: "First", externalConnectionID: profile.id)
        let second = CallRole(name: "Second", externalConnectionID: profile.id)
        let stable = first.mcpContactID
        precondition(stable != second.mcpContactID && stable != profile.externalRoleID)
        first.name = "Renamed"
        precondition(first.mcpContactID == stable)
        first.externalRoleID = "external-identity"
        first.externalRoleName = "Cloud name"
        let restoredRole = try decoder.decode(CallRole.self, from: JSONEncoder().encode(first))
        precondition(restoredRole.mcpContactID == "external-identity" && restoredRole.externalRoleName == "Cloud name")
        let base = URL(string: "https://wake-fixture.invalid/functions/v1/tincall")!
        let headers = ["Authorization": "Bearer tcwake_" + String(repeating: "a", count: 64)]
        let wake = WakeBridgeConfiguration.Endpoint(transport: "sse", url: base.appendingPathComponent("wake/events"), headers: headers, event: "wake")
        let input = WakeBridgeConfiguration.Endpoint(transport: "http", url: base.appendingPathComponent("wake/input"), headers: headers, event: nil)
        let bridge = WakeBridgeConfiguration(version: 2, contact_id: "linked", wake: wake, input: input,
            mcp: .init(transport: "streamable-http", url: base.appendingPathComponent("mcp/wake"), headers: headers, event: nil), instructions: "Synthetic instructions")
        var cloud = ConnectionProfile(name: "Synthetic service", provider: .genericConnector)
        cloud.endpoint = base
        for usesSSE in [false, true, false] {
            let exported = try decoder.decode(WakeBridgeConfiguration.self, from: Data(try bridge.exportText(mcpUsesSSE: usesSSE).utf8))
            try exported.validate(connection: cloud, contactID: "linked")
            precondition(exported.mcp.transport == (usesSSE ? "sse" : "streamable-http"))
            precondition(exported.mcp.url == base.appendingPathComponent(usesSSE ? "mcp/sse" : "mcp/wake"))
            precondition(exported.mcp.headers == headers && exported.wake.headers == headers && exported.input?.headers == headers,
                         "Changing MCP transport must keep bridge credentials for all three connections")
            precondition(exported.wake.transport == "sse" && exported.input?.transport == "http",
                         "Only the MCP transport changes; wake subscription and input retrieval remain intact")
            precondition(exported.instructions == bridge.instructions && exported.contact_id == bridge.contact_id)
        }
        let wrongEndpoint = WakeBridgeConfiguration(version: 2, contact_id: "linked", wake: wake, input: input,
            mcp: .init(transport: "sse", url: URL(string: "https://other.invalid/mcp/sse")!, headers: headers, event: nil), instructions: "Synthetic instructions")
        do {
            try wrongEndpoint.validate(connection: cloud, contactID: "linked")
            preconditionFailure("A transport switch must not accept credentials directed at another service")
        } catch is TincallError {}
        print("PASS: bridge HTTP/SSE export, credential preservation and endpoint validation")
        print("PASS: contact identity isolation and stability, legacy decoding, capability decoding, directory names and persistence")
    }
}
