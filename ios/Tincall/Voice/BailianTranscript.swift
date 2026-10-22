import Foundation

struct BailianTranscript {
    enum Event {
        case started, finished(String)
        case transcript(String, isFinal: Bool, beginTime: Int, endTime: Int?)
        case responseTimeout(TincallError)
    }
    private var sentences: [Int: String] = [:]
    private var finalSentences: Set<Int> = []
    var text: String { sentences.keys.sorted().compactMap { sentences[$0] }.joined() }
    var hasUnfinishedSentence: Bool { sentences.keys.contains { !finalSentences.contains($0) } }

    mutating func consume(_ data: Data, taskID: String) throws -> Event? {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.header.task_id == taskID else { return nil }
        switch response.header.event {
        case "task-started": return .started
        case "task-finished":
            guard !hasUnfinishedSentence else {
                throw TincallError(message: String(localized: "百炼识别结束前未返回完整的最终转写"))
            }
            return .finished(text)
        case "task-failed":
            let code = (response.header.error_code ?? "request_failed").prefix(80)
                .filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
            let error = TincallError(message: String(localized: "百炼识别失败（\(code)）"), requestCode: response.header.error_code)
            if response.header.error_message?.lowercased().hasPrefix("response timeout") == true ||
                ["response_timeout", "responsetimeout"].contains(response.header.error_code?.lowercased() ?? "") {
                return .responseTimeout(error)
            }
            throw error
        case "result-generated":
            guard let sentence = response.payload?.output?.sentence, sentence.heartbeat != true else { return nil }
            guard let begin = sentence.begin_time, begin >= 0, let value = sentence.text else {
                throw TincallError(message: String(localized: "百炼识别返回了无效的句子"))
            }
            if finalSentences.contains(begin) { return nil }
            sentences[begin] = value
            if sentence.sentence_end == true { finalSentences.insert(begin) }
            return .transcript(value, isFinal: sentence.sentence_end == true,
                               beginTime: begin, endTime: sentence.end_time)
        default: return nil
        }
    }

    private struct Response: Decodable { let header: Header; let payload: Payload? }
    private struct Header: Decodable { let task_id: String; let event: String; let error_code: String?; let error_message: String? }
    private struct Payload: Decodable { let output: Output? }
    private struct Output: Decodable { let sentence: Sentence? }
    private struct Sentence: Decodable {
        let begin_time: Int?
        let end_time: Int?
        let text: String?
        let heartbeat: Bool?
        let sentence_end: Bool?
    }
}
