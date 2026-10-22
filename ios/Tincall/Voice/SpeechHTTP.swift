// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

@MainActor
enum SpeechHTTP {
    static func perform<Result>(service: RequestLogService, step: RequestLogStep,
                               context: RequestLogContext?, segment: Int? = nil,
                               connectionName: String? = nil, modelName: String? = nil,
                               operation: (RequestLogSpan) async throws -> Result) async throws -> Result {
        let log = RequestLogStore.shared.begin(service: service, step: step, context: context, segment: segment,
                                              connectionName: connectionName, modelName: modelName)
        defer { log.finish() }
        do {
            let result = try await operation(log)
            log.succeed()
            return result
        } catch { log.fail(error); throw error }
    }
}

/// Keep speech credentials and audio at the configured request destination.
final class SpeechHTTPNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
