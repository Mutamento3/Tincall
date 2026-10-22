// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

/// Feed the actual sender output to the same Codable types used by ActivityKit.
@main struct CallActivityPayloadChecks {
    struct Payload: Decodable {
        struct APS: Decodable {
            let attributes: TincallCallAttributes
            let state: TincallCallAttributes.ContentState
            let timestamp: TimeInterval
            enum CodingKeys: String, CodingKey { case attributes, timestamp; case state = "content-state" }
        }
        let aps: APS
    }

    static func main() throws {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let payload = try JSONDecoder().decode(Payload.self, from: bytes)
        precondition(!payload.aps.attributes.isPreview)
        precondition(payload.aps.attributes.name == "Synthetic caller")
        precondition(payload.aps.attributes.avatarContactID == UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        precondition(payload.aps.state.displayName == nil)
        precondition(payload.aps.state.startedAt.timeIntervalSince1970 == payload.aps.timestamp)
        precondition(payload.aps.state.microphoneAvailable == true)
        var state = payload.aps.state
        state.displayName = "Synthetic local contact"
        state.avatarContactID = UUID()
        let restored = try JSONDecoder().decode(TincallCallAttributes.ContentState.self, from: JSONEncoder().encode(state))
        precondition(restored == state)
        print("PASS: real sender payload decodes using ActivityKit attributes, dates and optional local identity")
    }
}
