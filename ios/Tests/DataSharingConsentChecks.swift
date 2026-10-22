import Foundation

private final class ConsentRequestProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.requests += 1 }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((request.url!.path == "/devices/remove" ? "{\"ok\":true}" : "{\"bindings\":[]}").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@main struct DataSharingConsentChecks {
    @MainActor static func main() async throws {
        let suite = "tincall-consent-check-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = ConnectionProfile(name: "Synthetic", provider: .openAICompatible, endpoint: URL(string: "https://fixture.invalid/v1"))
        precondition(!DataSharingConsent.isAllowed(original, defaults: defaults))
        precondition(DataSharingConsent.needsReview(original, defaults: defaults))
        DataSharingConsent.setAllowed(true, for: original, defaults: defaults)
        precondition(DataSharingConsent.isAllowed(original, defaults: UserDefaults(suiteName: suite)!))
        precondition(!DataSharingConsent.needsReview(original, defaults: defaults))
        var changed = original
        changed.endpoint = URL(string: "https://different-fixture.invalid/v1")
        precondition(!DataSharingConsent.isAllowed(changed, defaults: defaults))
        changed = original; changed.provider = .anthropic
        precondition(!DataSharingConsent.isAllowed(changed, defaults: defaults))
        changed = original; changed.region = "international"
        precondition(!DataSharingConsent.isAllowed(changed, defaults: defaults))
        changed = original; changed.id = UUID()
        precondition(!DataSharingConsent.isAllowed(changed, defaults: defaults))
        precondition(DataSharingConsent.recipient(original) == original.endpoint!.absoluteString)
        changed = original; changed.endpoint = URL(string: "https://fixture.invalid/v1?key=synthetic-secret")
        DataSharingConsent.setAllowed(true, for: changed, defaults: defaults)
        precondition(!DataSharingConsent.isAllowed(changed, defaults: defaults))
        precondition(!String(describing: defaults.dictionaryRepresentation()).contains("synthetic-secret"))
        DataSharingConsent.setAllowed(false, for: original, defaults: defaults)
        precondition(!DataSharingConsent.isAllowed(original, defaults: defaults))
        precondition(!DataSharingConsent.needsReview(original, defaults: defaults), "Do not repeatedly prompt for an explicit refusal")
        let onDevice = ConnectionProfile(name: "Apple", provider: .appleSpeech)
        precondition(DataSharingConsent.isAllowed(onDevice, defaults: defaults))
        precondition(!DataSharingConsent.needsReview(onDevice, defaults: defaults))
        let voice = ConnectionProfile(name: "Synthetic voice", provider: .elevenLabs)
        let connector = ConnectionProfile(name: "Synthetic incoming", provider: .genericConnector, endpoint: URL(string: "https://incoming.fixture.invalid"))
        var role = CallRole(name: "Synthetic incoming")
        role.modelConnectionID = original.id; role.sttConnectionID = onDevice.id; role.ttsConnectionID = voice.id
        let profiles = [original, onDevice, voice, connector]
        precondition(!DataSharingConsent.permitsIncomingCall(role: role, connector: connector, connections: profiles, defaultSTT: nil, defaults: defaults))
        for profile in [original, voice, connector] { DataSharingConsent.setAllowed(true, for: profile, defaults: defaults) }
        precondition(DataSharingConsent.permitsIncomingCall(role: role, connector: connector, connections: profiles, defaultSTT: nil, defaults: defaults))
        DataSharingConsent.setAllowed(false, for: voice, defaults: defaults)
        precondition(!DataSharingConsent.permitsIncomingCall(role: role, connector: connector, connections: profiles, defaultSTT: nil, defaults: defaults))
        DataSharingConsent.setAllowed(true, for: voice, defaults: defaults)
        let otherSTT = ConnectionProfile(name: "Synthetic STT", provider: .whisperCompatible, endpoint: URL(string: "https://speech.fixture.invalid"))
        precondition(!DataSharingConsent.permitsIncomingCall(role: role, connector: connector, connections: profiles + [otherSTT], defaultSTT: otherSTT.id, defaults: defaults))
        role.callMode = .mcp
        DataSharingConsent.setAllowed(false, for: original, defaults: defaults)
        precondition(DataSharingConsent.permitsIncomingCall(role: role, connector: connector, connections: profiles, defaultSTT: nil, defaults: defaults))
        let legacy = ConnectionProfile(name: "Synthetic legacy binding", provider: .genericConnector, endpoint: URL(string: "https://legacy.fixture.invalid"))
        DataSharingConsent.rememberDeviceBinding(legacy, defaults: defaults)
        precondition(DataSharingConsent.isCleanupAllowed(legacy, defaults: defaults))
        precondition(!DataSharingConsent.isAllowed(legacy, defaults: defaults), "A saved device binding must never grant ordinary data sharing")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConsentRequestProtocol.self]
        let client = ExternalCallClient(configuration: configuration, logs: RequestLogStore(directory: directory))
        var backend = ConnectionProfile(name: "Synthetic connector", provider: .genericConnector, endpoint: URL(string: "https://fixture.invalid"))
        defer { DataSharingConsent.setAllowed(false, for: backend) }
        func denied(_ profile: ConnectionProfile) async throws {
            do {
                _ = try await client.contactDirectory(connection: profile, tokenOverride: "synthetic-token")
                preconditionFailure("Missing permission must block before sending")
            } catch is TincallError { }
        }
        try await denied(backend)
        precondition(ConsentRequestProtocol.lock.withLock { ConsentRequestProtocol.requests } == 0)
        DataSharingConsent.setAllowed(true, for: backend)
        _ = try await client.contactDirectory(connection: backend, tokenOverride: "synthetic-token")
        precondition(ConsentRequestProtocol.lock.withLock { ConsentRequestProtocol.requests } == 1)
        DataSharingConsent.setAllowed(false, for: backend)
        try await denied(backend)
        precondition(ConsentRequestProtocol.lock.withLock { ConsentRequestProtocol.requests } == 1)
        try await client.removeDevice(connection: backend, deviceID: UUID(), requestID: UUID(), tokenOverride: "synthetic-token")
        precondition(ConsentRequestProtocol.lock.withLock { ConsentRequestProtocol.requests } == 2)
        DataSharingConsent.rememberDeviceBinding(legacy)
        defer {
            UserDefaults.standard.removeObject(forKey: "tincall.dataSharing.v1.\(legacy.id.uuidString).deviceBinding")
        }
        try await denied(legacy)
        try await client.removeDevice(connection: legacy, deviceID: UUID(), requestID: UUID(), tokenOverride: "synthetic-token")
        precondition(ConsentRequestProtocol.lock.withLock { ConsentRequestProtocol.requests } == 3)
        backend.endpoint = URL(string: "https://different-fixture.invalid")
        try await denied(backend)
        do {
            try await client.removeDevice(connection: backend, deviceID: UUID(), requestID: UUID(), tokenOverride: "synthetic-token")
            preconditionFailure("Cleanup must not send credentials to an unapproved destination")
        } catch is TincallError { }
        precondition(ConsentRequestProtocol.lock.withLock { ConsentRequestProtocol.requests } == 3)
        print("Data-sharing permission persistence, destination changes, revocation and on-device speech checks passed")
    }
}
