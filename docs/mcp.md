# Tincall MCP 工具契约

本文对应当前生产 `supabase/functions/_shared/tincall/mcp.mjs`，适用于升级服务并刷新 `tools/list` 后的客户端。手机 HTTP 后端接口见 [后端接口](backend_api.md)，平台操作说明见 [接入指引](agent_prompt.md)。

## 普通 MCP

联系人专用凭据或 OAuth 授权决定操作范围。连接端处理通话、轮次与请求标识；模型只填写公开工具参数，不传旧版 `reply_to`、`status`、`request_id` 或等待游标。

| 工具 | 公开参数 | 行为 |
| --- | --- | --- |
| `tincall_call` | 联系人凭据下无参数；其他身份按定义传 `contact_id` | 发起来电并等待接听，接通后提示可回复；单次等待最多 120 秒，未接听可继续 wait。重复拨号复用同联系人的未结束 MCP 通话 |
| `tincall_get_call` | 可选 `call_id`、`limit`、`before_sequence` | 读取当前／指定通话的状态、文字和图片；结束通话可含已有摘要，历史默认 50 条、最多 100 条，按结果指引翻页 |
| `tincall_wait` | 无参数 | 等待新消息、接听或挂断；超时返回提示继续等待，整通电话不受单次两分钟限制 |
| `tincall_reply` | 必填 `text`；可选 `wait_for_input`，默认 true | 一次提交完整非空回复，默认继续等待下一句话；false 时返回“已发送。”，不代表已播完 |
| `tincall_end` | 无参数 | 结束服务端通话，要求手机播放完已收到回复后挂断；手机手动挂断仍立即停止 |
| `tincall_list_calls` | 可选 `limit`、`before` | 列出当前身份的历史通话，默认 10 条、最多 50 条；用返回的翻页信息继续，再用 get_call 读正文 |

参数以实际 `tools/list` 为准。接通、发言与结束结果面向模型直接呈现；图片返回标准 MCP image content，应读取实际内容。服务端的内部路由标识不要求模型抄写。

正常通话：`call → reply({text}) → reply({text}) → …`。手机已拨出时，可用 `get_call` 确认状态或 `wait` 等待输入。告别：`reply({text, wait_for_input:false}) → end()`。

## 等待、播放与失败

- 朗读要求在通话开始时交付一次，平台应保留同一会话上下文。get_call 的历史读取不消费未读发言；首次读取已接通电话会给出开场提示。
- reply 默认等下一句；wait 超时、空闲、播放停止都不是挂断。平台的工具请求时限应长于 120 秒，例如设为 180 秒。
- HTTP 超时或响应丢失不能证明回复未发送。先恢复等待或查看记录，不盲目重发全文；当前公开接口没有客户端控制的回复去重标识，不能承诺模型重调 reply 一定去重。
- 手机普通打断停止当前生成／播放并保持电话。普通 MCP 不能强制取消任意宿主模型，后续完整消息仍可提交；等待不因内部轮次变化而提前误报“播放已打断”。
- MCP end 先结束远端通话，再让手机等待已收到内容的真实播放排空；合成／播放失败也退出收尾。手机手动挂断、或在 MCP 挂断收尾期间打断剩余播放，立即结束。
- 手机持续读取通话事件表示在线，连续三分钟未读取的活动通话可由 worker 或下次拨号回收；MCP 工具调用不替手机续期。另一个联系人占线时只提示存在未结束通话，不泄露其身份或内容。

## MCP＋唤醒桥

平台接入程序在模型任务之外订阅 `/wake/events`，读取 `/wake/input`，把用户名、正文、实际图片与首次朗读要求带入平台会话，再启动一次 AI 任务。可以使用 [wake-adapter.mjs](../connector/wake-adapter.mjs)，运行与配置见 [连接端说明](../connector/README.md#唤醒桥接入)。

专用 MCP 不列出 `tincall_wait`；`tincall_reply({text})` 发送完整回复后立即返回，AI 随后结束任务。接入程序串行处理同联系人任务，新输入排队；主动拨号等待接听的任务继续负责开场，不再重复启动开场任务。普通 MCP 配置本身不会创建这条订阅／启动链路。

唤醒 SSE、普通 MCP 的 Streamable HTTP／旧 SSE 传输，都不意味着模型正在逐字发送回复。MCP 目前提交完整消息；HTTP 后端支持增量流式和完整回复。

## 更新与实现入口

Supabase 部署按顺序应用仓库迁移并更新函数，当前完整消息与播放收尾涉及 `202610210001_tincall_mcp_voice_ack.sql` 和 `202610210002_tincall_mcp_conversation.sql`；SQLite 在启动时增量升级。App 的部署器已包含这些迁移，发布 App 后仍需单独更新用户服务。服务更新后刷新外部平台的工具列表或重连，移除旧版参数。

- `supabase/functions/_shared/tincall/mcp.mjs`：工具定义、等待、发送、结果呈现与传输。
- `connector/sqlite-store.mjs`／`supabase/migrations/`：持久化消息、读取进度和通话状态。
- `ios/Tincall/Core/CallCoordinator+External.swift`：完整回复接收、播放排空和挂断。
- `connector/tests/connector.test.mjs`、`mcp-busy.test.mjs`、`wake-bridge.test.mjs` 与 `ios/Tests/MCPOpeningChecks.swift`：MCP、唤醒桥及开场行为的模块检查。
