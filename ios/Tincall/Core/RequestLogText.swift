// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

/// Redact credentials, including those echoed in free-form errors, without cutting off request content.
enum RequestLogText {
    private static let exportSeparator = "\n\n----------------------------------------\n\n"

    /// Write one complete redacted request at a time to keep large exports bounded.
    static func writeExportEntry(_ entry: RequestLogEntry, to file: FileHandle, isFirst: Bool) throws {
        if !isFirst { try file.write(contentsOf: Data(exportSeparator.utf8)) }
        // export always appends one final newline; the caller writes that once at EOF.
        try file.write(contentsOf: Data(export([entry]).dropLast().utf8))
    }

    /// Only the selected entries and their saved text; never reads credentials or request headers.
    static func export(_ entries: [RequestLogEntry]) -> String {
        entries.map { entry in
            let result: String
            switch entry.outcome {
            case .pending: result = String(localized: "请求中")
            case .succeeded: result = String(localized: "成功")
            case .failed: result = String(localized: "失败")
            case .cancelled: result = entry.errorCode == "call_hang_up" ? String(localized: "挂断时中止") : String(localized: "已取消")
            }
            let notRecorded = String(localized: "未记录")
            var lines = [
                String(localized: "时间：\(entry.time.formatted(.dateTime.year().month().day().hour().minute().second()))"),
                String(localized: "类型：\(entry.step.displayName)"),
                String(localized: "服务商：\(entry.service.displayName)"),
                String(localized: "模型：\(entry.displayModelName ?? notRecorded)"),
                String(localized: "连接：\(entry.displayConnectionName ?? notRecorded)"),
                String(localized: "耗时：\(entry.duration.map { String(format: String(localized: "%.2f 秒"), $0) } ?? notRecorded)"),
                String(localized: "结果：\(result)")
            ]
            if let segment = entry.segment { lines.append(String(localized: "分段：\(segment)")) }
            if let status = entry.httpStatus { lines.append(String(localized: "HTTP：\(status)")) }
            if let code = entry.errorCode { lines.append(String(localized: "错误码：\(code)")) }
            let inputTitle = entry.step == .synthesis ? String(localized: "合成文字") : String(localized: "输入")
            let inputIndex = lines.count
            lines.append(String(localized: "\n\(inputTitle)：\n\(entry.requestText ?? notRecorded)"))
            if let reasoning = entry.reasoningText, !reasoning.isEmpty {
                lines.append(String(localized: "\n思考：\n\(reasoning)"))
            }
            let outputTitle = entry.step == .transcription ? String(localized: "识别结果") : entry.step == .synthesis ? String(localized: "合成结果") : String(localized: "输出")
            lines.append(String(localized: "\n\(outputTitle)：\n\(entry.responseText ?? notRecorded)"))
            if let error = entry.serverErrorText, !error.isEmpty {
                lines.append(String(localized: "\n服务端错误：\n\(error)"))
            }
            // Keep original JSON values (including images); generic text redaction
            // treats long strings and URLs as secrets and would destroy that body.
            return lines.enumerated().map { index, line in
                if index == inputIndex, let body = entry.requestBodyJSON,
                   let json = requestJSON(Data(body.utf8)) {
                    return String(localized: "\n\(inputTitle)：\n\(json)")
                }
                return clean(line) ?? ""
            }.joined(separator: "\n")
        }.joined(separator: exportSeparator) + "\n"
    }

    static func requestJSON(_ data: Data, secrets: [String] = []) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object) else { return nil }
        let marker = String(localized: "[已打码]")
        let credentialKeys: Set<String> = ["authorization", "cookie", "api_key", "apikey", "api_secret", "apisecret",
                                           "access_token", "refresh_token", "token", "secret", "password",
                                           "x_api_key", "xi_api_key", "x_goog_api_key"]
        var changed = false
        func redact(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] {
                var result: [String: Any] = [:]
                let isAudio = (dictionary["mime_type"] as? String ?? dictionary["mimeType"] as? String)?.hasPrefix("audio/") == true
                    || ["wav", "mp3"].contains(dictionary["format"] as? String ?? "")
                for (key, nested) in dictionary {
                    if isAudio && key == "data" {
                        result[key] = String(localized: "[原声音频已省略]")
                        changed = true
                    } else if credentialKeys.contains(key.lowercased().replacingOccurrences(of: "-", with: "_")) {
                        result[key] = marker
                        changed = true
                    } else { result[key] = redact(nested) }
                }
                return result
            }
            if let array = value as? [Any] { return array.map { redact($0) } }
            if let text = value as? String {
                var result = text
                for secret in secrets where !secret.isEmpty { result = result.replacingOccurrences(of: secret, with: marker) }
                if result != text { changed = true }
                return result
            }
            return value
        }
        let redacted = redact(object)
        if !changed { return String(data: data, encoding: .utf8) }
        guard let cleaned = try? JSONSerialization.data(withJSONObject: redacted, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return nil }
        return String(data: cleaned, encoding: .utf8)
    }

    static func clean(_ value: String?, secrets: [String] = []) -> String? {
        guard var text = value else { return nil }
        for secret in secrets.sorted(by: { $0.count > $1.count }) where !secret.isEmpty {
            text = text.replacingOccurrences(of: secret, with: String(localized: "[已打码]"))
        }
        let patterns = [
            #"(?i)\b(?:authorization|cookie|set-cookie)\b[\"'\s]*[:=][^\r\n]*"#,
            #"(?i)[\"']?(?:[a-z_]*token|api[_-]?key|secret|password|signature)[\"']?\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|[^\s,;}]+)"#,
            #"(?i)\bBearer\s+[^\s\"',;}]+"#,
            #"\b(?:sk|sk-proj|sk-ant|rk|AKIA)[-_]?[A-Za-z0-9_-]{12,}\b"#,
            #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)?\b"#,
            #"\b[A-Za-z0-9_+/=-]{24,}\b"#,
            #"(?i)(?:https?|wss?)://[^\s\"'<>]+"#
        ]
        for pattern in patterns {
            text = text.replacingOccurrences(of: pattern, with: String(localized: "[已打码]"), options: .regularExpression)
        }
        return text
    }
}
