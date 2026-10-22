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
        client?.urlProtocol(self, didLoad: Data("{\"bindings\":[]}".utf8))
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
        DataSharingConsent.setAllowed(true, for: original, defaults: defaults)
        precondition(DataSharingConsent.isAllowed(original, defaults: UserDefaults(suiteName: suite)!))
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
        let onDevice = ConnectionProfile(name: "Apple", provider: .appleSpeech)
        precondition(DataSharingConsent.isAllowed(onDevice, defaults: defaults))
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
        backend.endpoint = URL(string: "https://different-fixture.invalid")
        try await denied(backend)
        precondition(ConsentRequestProtocol.lock.withLock { ConsentRequestProtocol.requests } == 1)
        print("Data-sharing permission persistence, destination changes, revocation and on-device speech checks passed")
    }
}
