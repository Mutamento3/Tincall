// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

#if DEBUG
import Foundation
import Observation

/// Launch-argument demo requests, isolated from real logs and call records.
@MainActor @Observable
final class RequestLogExamples {
    static let shared = RequestLogExamples()
    private(set) var store: RequestLogStore?
    @ObservationIgnored private let directory: URL?

    init(directory: URL? = nil) {
        self.directory = directory
        guard ProcessInfo.processInfo.arguments.contains("-TincallSampleRequestLogs") else { return }
        do {
            var root = try sampleDirectory()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try root.setResourceValues(values)
            // Seed the existing log archive format so examples have useful times and durations.
            try JSONEncoder().encode(Self.archive()).write(to: root.appendingPathComponent("requests.json"), options: .atomic)
            store = RequestLogStore(directory: root)
            if let issue = store?.storageIssue {
                NSLog("Request log sample injection: %@", issue)
            }
        } catch {
            NSLog("Request log sample injection failed (%ld).", (error as NSError).code)
        }
    }

    private func sampleDirectory() throws -> URL {
        try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true)
            .appendingPathComponent("Tincall/RequestLogExamples", isDirectory: true)
    }

    private struct Archive: Encodable {
        var calls: [RequestLogCall] = []
        var entries: [RequestLogEntry] = []
    }

    private static func archive() -> Archive {
        let start = Date().addingTimeInterval(-600)
        let callID = UUID()
        let rounds = [RequestLogRound(id: UUID()), RequestLogRound(id: UUID())]
        let first = RequestLogContext(callID: callID, roundID: rounds[0].id)
        let second = RequestLogContext(callID: callID, roundID: rounds[1].id)
        let input = """
        [system]
        用自然的中文聊天。先回应对方正在关心的事，再给出容易做到的建议；没有确定的事情不要擅自替对方决定。

        [user]
        最近下班以后总是直接回家刷手机，越刷越觉得累。今天想出去走走，但又不想把散步变成一项必须完成的任务。你能帮我想一个轻松一点的安排吗？

        [assistant]
        可以从很短的一段路开始。你更想去安静的地方，还是有一点烟火气的街道？

        [user]
        想沿河走走，回来的时候顺便吃晚饭。不要安排得太满，走累了就回家。
        """
        let output = """
        那就把今晚留给河边吧，不用规定走多远。

        出门前带上钥匙和水，换一双舒服的鞋。到了河边，挑你喜欢的方向慢慢走，想停下来看看水面就停一会儿。要是走到第一个路口就觉得累，也完全可以在那里折返。

        回来的时候看看哪家店顺眼，吃一碗热面或者一份简单的饭。今晚不用完成步数，也不用把状态调整到多好；有一小段时间属于自己，就已经足够了。
        """
        var archive = Archive(calls: [RequestLogCall(id: callID, startedAt: start, rounds: rounds, mode: .standalone)])
        // Newest model requests appear first; speech and sync remain separate, compact cards.
        archive.entries = [
            RequestLogEntry(id: UUID(), time: start.addingTimeInterval(500), service: .openAI, step: .model,
                context: first, segment: nil, duration: 4.38, outcome: .succeeded, httpStatus: 200,
                connectionName: "日常聊天", modelName: "deepseek-chat", requestText: input,
                responseText: output, reasoningText: """
                对方想从下班后的疲惫和刷手机习惯里暂时抽身，但明确不希望散步变成新的任务。回复应该先承接这个偏好，不设置里程、时长或打卡目标。

                已知的选择是沿河散步、顺便吃晚饭以及走累就回家。因此可以给出出门、途中、回程三个自然的节点，保留随时折返的余地。不假设附近具体有哪些店，也不把普通疲惫解释为疾病。
                """),
            RequestLogEntry(id: UUID(), time: start.addingTimeInterval(480), service: .anthropic, step: .model,
                context: second, segment: nil, duration: 1.8, outcome: .succeeded, httpStatus: 200,
                connectionName: "轻松聊天", modelName: "claude-sonnet-4-5",
                requestText: "[system]\n用简短自然的中文聊天。\n\n[user]\n回来之后想煮点热的，有什么简单的建议？",
                responseText: "煮一碗番茄鸡蛋面怎么样？先炒番茄，加水烧开后下面，最后打个鸡蛋。家里有青菜的话再放一把，一口锅就够了。"),
            RequestLogEntry(id: UUID(), time: start.addingTimeInterval(450), service: .gemini, step: .summary,
                context: RequestLogContext(callID: callID), segment: nil, duration: 1.85, outcome: .succeeded, httpStatus: 200,
                connectionName: "通话摘要", modelName: "gemini-2.5-flash",
                requestText: "[system]\n总结事实、决定和未完成事项，不补造细节。\n\n[user]\n" + input + "\n\n[assistant]\n" + output,
                responseText: "对方最近下班后容易长时间刷手机，希望换一种轻松的休息方式。今晚打算沿河散步，走累就折返，回程顺便吃晚饭；不设步数、时长或路线目标。具体去哪家店尚未决定。",
                reasoningText: "保留明确说出的安排与偏好；区分已决定的河边散步和未决定的晚饭地点。"),
            RequestLogEntry(id: UUID(), time: start.addingTimeInterval(420), service: .xunfei, step: .transcription,
                context: first, segment: nil, duration: 1.2, outcome: .succeeded, httpStatus: 101,
                connectionName: "讯飞听写", requestText: "PCM · 16 kHz · 单声道 · 3.20 秒",
                responseText: "今天想沿河走走，回来的时候顺便吃晚饭。"),
            RequestLogEntry(id: UUID(), time: start.addingTimeInterval(400), service: .xunfei, step: .transcription,
                context: second, segment: nil, duration: 0.42, outcome: .failed, httpStatus: 401,
                errorCode: "InvalidApiKey", connectionName: "讯飞听写",
                requestText: "PCM · 16 kHz · 单声道 · 1.80 秒",
                serverErrorText: "{\"error\":{\"code\":\"InvalidApiKey\",\"message\":\"Authentication failed. Check the configured credential.\"}}"),
            RequestLogEntry(id: UUID(), time: start.addingTimeInterval(380), service: .miniMax, step: .synthesis,
                context: second, segment: 0, duration: 0.9, outcome: .failed, httpStatus: 503,
                errorCode: "InternalServerError", connectionName: "温柔女声", modelName: "speech-2.8-hd",
                requestText: "那就把今晚留给河边吧，不用规定走多远。",
                serverErrorText: "{\"base_resp\":{\"status_code\":503,\"status_msg\":\"Service temporarily unavailable\"}}"),
            RequestLogEntry(id: UUID(), time: start.addingTimeInterval(360), service: .miniMax, step: .synthesis,
                context: first, segment: 0, duration: 0.76, outcome: .succeeded, httpStatus: 200,
                connectionName: "温柔女声", modelName: "speech-2.8-hd", requestText: "走累了就回家，不用给自己设目标。",
                responseText: "音频 2.40 秒 · 115200 字节"),
            RequestLogEntry(id: UUID(), time: start.addingTimeInterval(340), service: .cloud, step: .sync,
                context: nil, segment: nil, duration: 1.12, outcome: .succeeded, httpStatus: 200,
                connectionName: "通话备份", requestText: "上传通话备份 3 条", responseText: "已保存 3 条通话备份"),
            RequestLogEntry(id: UUID(), time: start.addingTimeInterval(320), service: .openAI, step: .model,
                context: second, segment: nil, duration: 1.32, outcome: .cancelled,
                errorCode: "call_hang_up", connectionName: "日常聊天", modelName: "deepseek-chat",
                requestText: "[user]\n如果突然下雨怎么办？", responseText: "那就先找个能避雨的地方，",
                reasoningText: "先建议避雨，再给出回家的选择。")
        ]
        return archive
    }
}
#endif
