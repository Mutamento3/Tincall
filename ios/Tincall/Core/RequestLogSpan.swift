import Foundation

@MainActor
final class RequestLogSpan {
    private let store: RequestLogStore
    private var entry: RequestLogEntry
    private let start = ProcessInfo.processInfo.systemUptime
    private var finished = false
    private var secrets: [String] = []
    private let deferred: Bool

    init(store: RequestLogStore, entry: RequestLogEntry, deferred: Bool) {
        self.store = store; self.entry = entry; self.deferred = deferred
    }

    func response(_ response: URLResponse?) {
        entry.httpStatus = (response as? HTTPURLResponse)?.statusCode
    }

    // Values stay in this short-lived span, never in the persisted entry.
    func protect(_ values: [String]) {
        secrets += values.filter { !$0.isEmpty }
        entry.requestText = RequestLogText.clean(entry.requestText, secrets: secrets)
        entry.connectionName = RequestLogText.clean(entry.connectionName, secrets: secrets)
        entry.modelName = RequestLogText.clean(entry.modelName, secrets: secrets)
    }

    func protect(_ request: URLRequest) {
        let headers = request.allHTTPHeaderFields ?? [:]
        protect(headers.filter { key, _ in
            let key = key.lowercased()
            return key.contains("key") || key.contains("token") || key == "authorization" || key == "cookie"
        }.flatMap { key, value in
            key.lowercased() == "authorization" ? [value, String(value.split(separator: " ").last ?? "")] : [value]
        })
    }

    func request(_ text: String, persistImmediately: Bool = true) {
        entry.requestText = RequestLogText.clean(text, secrets: secrets)
        store.recordRequest(id: entry.id, text: entry.requestText, persistImmediately: persistImmediately)
    }

    func requestBody(_ data: Data?) {
        guard let data, let body = RequestLogText.requestJSON(data, secrets: secrets) else { return }
        entry.requestBodyJSON = body
        store.recordRequest(id: entry.id, text: nil, persistImmediately: false, bodyJSON: body)
    }

    /// Save in-memory upload progress at a sentence boundary without ending the request.
    func flush() { store.persist() }
    func request(_ messages: [ModelMessage], omittedTurnCount: Int) {
        guard omittedTurnCount > 0 else { request(ModelMessage.logText(messages)); return }
        let systemCount = messages.prefix { $0.role == "system" }.count
        let system = RequestLogText.clean(ModelMessage.logText(Array(messages.prefix(systemCount))), secrets: secrets) ?? ""
        let conversation = RequestLogText.clean(ModelMessage.logText(Array(messages.dropFirst(systemCount))), secrets: secrets) ?? ""
        let prefix = system.isEmpty ? "" : system + "\n\n"
        entry.requestText = prefix + conversation
        entry.omittedTurnCount = omittedTurnCount
        entry.requestConversationOffset = prefix.count
        store.recordRequest(id: entry.id, text: entry.requestText, omittedTurnCount: entry.omittedTurnCount,
                            conversationOffset: entry.requestConversationOffset)
    }
    func text(_ text: String) { entry.responseText = RequestLogText.clean(text, secrets: secrets) }
    func reasoning(_ text: String) { entry.reasoningText = RequestLogText.clean(text, secrets: secrets) }
    func serverError(_ text: String) {
        entry.serverErrorText = RequestLogText.clean(text, secrets: secrets)
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        let error = object["error"] as? [String: Any]
        let base = object["base_resp"] as? [String: Any]
        let header = object["header"] as? [String: Any]
        let code = error?["code"] ?? base?["status_code"] ?? header?["code"] ?? object["code"]
        let value = (code as? String) ?? (code as? Int).map(String.init)
        if let value { entry.errorCode = Self.safeCode(RequestLogText.clean(value, secrets: secrets) ?? "") }
    }
    func body(_ data: Data) { serverError(String(decoding: data, as: UTF8.self)) }

    func errorBody(_ bytes: URLSession.AsyncBytes) async throws {
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            data.append(byte)
            if data.count >= 131_072 { break }
        }
        body(data)
    }

    func succeed(_ text: String? = nil) {
        entry.outcome = .succeeded
        if let text { self.text(text) }
    }

    func fail(_ error: Error) {
        if (error as? URLError)?.code == .timedOut {
            entry.outcome = .failed
            entry.errorCode = "network_-1001"
        } else if (error as? any RequestLogCodedError)?.requestCode == "timeout" {
            entry.outcome = .failed
            entry.errorCode = "timeout"
        } else if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
            entry.outcome = .cancelled
            entry.errorCode = "cancelled"
        } else {
            entry.outcome = .failed
            if let error = error as? URLError { entry.errorCode = "network_\(error.code.rawValue)" }
            else if error is DecodingError { entry.errorCode = "invalid_response" }
            else if let code = (error as? any RequestLogCodedError)?.requestCode {
                entry.errorCode = Self.safeCode(RequestLogText.clean(code, secrets: secrets) ?? "")
            }
            else if entry.errorCode == nil {
                entry.errorCode = error is TincallError ? "request_failed" : "error_\((error as NSError).code)"
            }
        }
    }

    /// Arbitrary provider strings can contain credentials or text, even when they look like codes.
    private static func safeCode(_ code: String) -> String {
        if let number = Int(code) { return String(number) }
        let allowed: Set<String> = ["InvalidApiKey", "InvalidParameter", "InvalidParameterValue", "Throttling",
            "BadRequest", "Unauthorized", "Forbidden", "InternalError", "InternalServerError",
            "request_failed", "revision_conflict", "operation_retired", "forbidden", "record_deleted",
            "media_cleanup_failed", "media_cleanup_pending", "body_too_large", "media_download_failed",
            "stale_epoch", "call_not_found", "call_ended", "conflict", "invalid_request", "unauthorized",
            "rate_limit_exceeded", "quota_exceeded", "insufficient_quota", "invalid_api_key", "voice_not_found", "input_text_empty", "timeout"]
        return allowed.contains(code) ? code : "provider_error_redacted"
    }

    func finish(discardIfSucceeded: Bool = false) {
        guard !finished else { return }
        finished = true
        if entry.outcome == .pending { entry.outcome = .cancelled; entry.errorCode = "cancelled" }
        entry.duration = max(0, ProcessInfo.processInfo.systemUptime - start)
        if deferred {
            if !discardIfSucceeded || entry.outcome != .succeeded { store.append(entry) }
        } else {
            store.finish(entry)
        }
    }
}
