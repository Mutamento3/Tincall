# Tincall

[简体中文](#简体中文) · [English](#english)

### 功能概览 / Feature overview

| 系统来电与通话 / Calls | 自有云端 / Your cloud | 连接 AI / Connect your AI |
| --- | --- | --- |
| ![系统来电与通话](docs/images/01-tincall-incoming.png) | ![部署自己的云端](docs/images/02-your-own-cloud.png) | ![三种 AI 接入方式](docs/images/03-connect-your-ai.png) |
| 通话中分享 / Share during a call | 通话记录 / Call records | |
| ![通话中发送截图和文字](docs/images/04-share-during-a-call.png) | ![通话记录与重听](docs/images/05-call-records.png) | |

## 简体中文

Tincall 是最低支持 iOS 26 的原生 AI 语音通话 App。支持手机直连模型、自有后端，以及 MCP（模型上下文协议，让外部 AI 调用 Tincall 的通话工具）；收音、语音识别、语音合成、播放及本地记录由手机处理。

本仓库公开源码供个人使用、修改与按许可分享。使用范围见 [许可](LICENSE)，第三方组件保留其独立许可，见 [第三方声明](docs/third_party.md)。源码公开不代表采用无限制的开源许可。

### 选择通话方式

“连接端”是部署在自己的云端、电脑或服务器上的服务，负责连接手机和外部 AI、转发消息并管理通话状态。点击下表中的方式名称可查看对应配置步骤。

| 方式 | AI 与上下文在哪里 | 需要准备什么 | 回复方式 |
| --- | --- | --- | --- |
| [独立模式](#开始使用) | 手机直连所选模型 API | 模型、STT、TTS 的配置；日常通话不需要云端 | 模型增量流式回复，手机分段合成播放 |
| [普通 MCP](docs/agent_prompt.md) | 外部 AI 平台 | Tincall 连接端、对应联系人的 MCP 配置、正在运行并能调用工具的 AI | AI 用 `tincall_reply({text})` 提交完整回复，默认等待下一句话 |
| [MCP＋唤醒桥](connector/README.md#唤醒桥接入) | 外部 AI 平台 | 连接端、唤醒订阅程序、平台任务启动命令及专用 MCP | 收到事件启动一轮，提交完整回复后结束；新输入再唤醒 |
| [后端模式](docs/agent_prompt.md) | 接入方自己的后端 | 完整实现手机通话协议，或复用连接端只接生成和取消 | 支持流式增量和完整回复，由后端选择 |

联系人里仍是独立、MCP、后端三种模式；唤醒桥是 MCP 的一种接法。后端的模型、人物、记忆、工具及业务流程由接入方决定，不强制每通电话新建模型会话。

独立模式支持 OpenAI 兼容、Anthropic、Gemini 协议；STT 包括 Apple、讯飞、百炼和 Whisper 兼容接口，TTS 包括 ElevenLabs、MiniMax、Fish Audio。具体模型、音色、地域、额度和费用以所选服务为准。

### 源码版与商店版

默认 `Tincall` scheme 是个人自行构建版，完整核心通话能力不要求领取试用或购买。`Tincall-AppStore` scheme 使用 `StoreDebug`／`StoreRelease` 配置，通过 `TINCALL_APP_STORE` 启用官方商店版的试用与买断流程。

模型、识别、合成及自行部署服务的费用取决于各自供应商；购买 Tincall 不包含这些第三方服务。自行构建也不会自动获得发行者推送服务的授权，后台来电需按自签与推送文档配置。

### 开始使用

1. **安装手机 App**：从 [最新发布页](https://github.com/chuli1122/Tincall/releases/latest) 下载 `*-selfsign-unsigned.ipa`，按 [自签指南](docs/SELF_SIGN.md) 使用自己的签名凭据重签安装，无需重新编译。需要 iOS 26 或以上的 iPhone，签名工具须正确配置 App／扩展标识及 App Group。也可使用 Mac 和 Xcode 从源码构建。
2. **配置识别和声音**：在 App 配置 STT／TTS，选择供应商、型号和音色。TTS 的“语音表达提示词”有按型号区分的默认值，也可自行编辑。首次使用每条外部服务连接前，阅读其接收方与数据说明，并明确允许数据发送；更换地址或供应商后需重新确认。
3. **配置联系人**：独立模式选模型并填写人物设定；MCP 按 [接入指引](docs/agent_prompt.md) 登记联系人并复制平台配置；后端按 [接口说明](docs/backend_api.md) 准备服务。
4. **验证一通电话**：先确认服务和模型可达，再检查实际收音、回复、播放、打断和挂断。

手机手动挂断立即停止生成和播放；普通打断保留通话。AI 通过 MCP 挂断时，手机等待已收到回复播放排空，失败也会退出收尾。已收到内容保留并标注中断原因。

### 连接端与现成适配器

仓库提供可运行的通用连接端。它处理手机协议、MCP、通话状态、消息转发、可选备份及来电路由；模型生成需要连接到真实的外部 AI。

| 组件 | 用途 | 使用条件与边界 |
| --- | --- | --- |
| [Node／Supabase 连接端](connector/README.md) | 复用通话与存储协议 | Node 默认 SQLite；Supabase 使用 Edge Functions／数据库。两者共用生产逻辑，支持后端流式及完整回复 |
| [MCP 唤醒适配器](connector/wake-adapter.mjs) | 订阅事件、读取输入、启动外部 AI 命令 | 配置自己的平台启动命令、会话续接和专用 MCP；AI 经 MCP 回复，命令 stdout 不作为回复 |
| [Codex HTTP 适配器](connector/codex-backend.mjs) | 将生成／取消请求转给本机 Codex CLI | 需已安装并认证的 Codex 和私密配置；当前完整回复、文字输入，不支持图片或 AI 自主拨挂工具 |
| [推送发送端](cloudflare/README.md) | 设备注册、VoIP 来电和可选实时活动推送 | Node 24 或 Cloudflare Worker；需要与 App 签名匹配的 APNs 权限和凭据 |

连接端安装器不会自动启动两个适配器或推送发送端。普通 MCP 配置也不会自行唤醒闲置平台。只有 Codex 适配器当前没有增量转发，Tincall 后端协议本身支持流式。

后端模式可以完全自建服务，也可以只向连接端提供 `generation_url` 与 `cancel_url`。TTS 提示词通过 `expression_prompt` 交付；主动拨挂、开场、结束通知处理及摘要写回由接入方按需要实现。详细责任边界和格式见 [后端接口](docs/backend_api.md)。

### 部署连接端

#### 自己的电脑／服务器

安装 Node.js LTS（建议 Node 24，最低 Node 22.5 且内置 SQLite 可用），在源码根目录运行：

```sh
# macOS / Linux
sh connector/install-local.sh
```

```powershell
# Windows，无需 WSL
powershell -NoProfile -ExecutionPolicy Bypass -File connector\install-local.ps1
```

也支持 Docker。默认只监听本机回环地址；手机需要可达的 HTTPS 地址，可用反向代理或按 [连接端安装说明](connector/README.md#部署到自己的电脑或服务器) 配置隧道。将 HTTPS 基础地址与手机令牌填入 App“连接已有服务”。电脑须持续运行；临时隧道重启后可能换地址。

#### Supabase

App 中打开“设置 → Tincall 云端 → 部署或更新服务”，用自己的项目和限定项目的管理令牌部署。成功后保存日常连接；新增 MCP 联系人无需重新部署。电脑 CLI 部署也可用，见 [部署指南](docs/cloud_setup.md)。

应用更新不会自动更新已有云端。按原方式升级服务，保留原令牌和数据；不要用另一条首装流程覆盖旧配置。Supabase 图片所需迁移已纳入新版 App 的“部署或更新服务”和 CLI 部署，无需手动执行 SQL，见 [图片消息说明](docs/message_images.md)。录音与图片所需的私有存储桶和权限随基础迁移创建；录音保存及备份仍由用户分别启用。

### 可选功能与数据

- 通话文字和摘要可在本机保存；录音需用户分别启用。云同步、录音备份和后台来电分别配置，互不自动开启。
- 「本机数据与备份」可分别清理录音、消息图片或全部通话记录，每项均需确认。清理只作用于本机，联系人、连接配置、云端副本和已导出文件保留；清理图片后与云端不同的内容需在同步时手动选择。
- 已保存的服务、识别和语音合成连接可在「编辑连接」底部单独删除。一次确认后删除本机配置、访问凭据及关联选择，保留联系人、通话记录和云端数据；后台尝试解除该服务的设备绑定。远端不可达不阻断本机删除，仅提示可在服务端另行清理绑定，其他服务保持启用。通话或同步进行中需稍后操作。
- 独立模式将请求发到用户配置的模型／语音服务；MCP／后端模式将通话内容发给对应平台。外部服务收到的数据按其实际接法处理。
- 凭据保存在 Keychain 或部署者的私密配置，不随普通配置备份分享。手机令牌、MCP 联系人令牌、唤醒凭据、模型凭据和推送服务凭据用途不同。
- 前台来电通过已配置服务的订阅接收。后台及锁屏来电还需匹配的推送签名、设备绑定和可用的 APNs 发送端；配置步骤见[推送指南](cloudflare/README.md)。
- 快捷指令可向当前通话发文字／截图，见 [快捷指令](shortcuts/README.md)。

### 代码与文档导航

[英文安装部署指南](docs/setup.en.md)覆盖自签、首次通话、连接端、推送与升级；维护者的版本和 IPA 打包流程见[发行说明](docs/release.md)。协议细节另见下列文档。

| 路径 | 内容 |
| --- | --- |
| `ios/Tincall/App/` | App 入口、运行时和系统意图 |
| `ios/Tincall/Core/` | 模型协议、通话协调、外部接口、上下文／摘要、凭据、部署 |
| `ios/Tincall/Voice/` | 收音、VAD、STT、TTS、切段、播放、音频路由 |
| `ios/Tincall/Features/`、`Storage/` | 界面、配置／记录、备份和云同步 |
| `ios/TincallCallWidget/`、`ios/LocalPackages/` | 实时活动扩展及随库第三方组件 |
| `connector/` | Node 入口、SQLite、适配器、安装脚本和可选 Node 推送 |
| `supabase/functions/`、`supabase/migrations/` | 共享连接逻辑、Edge 入口和数据库迁移 |
| `cloudflare/` | 可选推送 Worker |
| `ios/Tests/`、`connector/tests/`、`cloudflare/tests/` | 模块与接口检查 |

- [自签与安装](docs/SELF_SIGN.md)
- [云端部署](docs/cloud_setup.md)
- [MCP／后端接入步骤](docs/agent_prompt.md)
- [MCP 工具参数与行为](docs/mcp.md)
- [后端 HTTP 协议](docs/backend_api.md)
- [图片消息](docs/message_images.md)
- [开发与测试：环境、命令及验证范围](connector/README.md#checks-and-current-limits)
- [第三方组件与素材](docs/third_party.md)

### 反馈

使用中遇到 Bug 或有建议，欢迎通过 App 内「设置 → 帮助与指引 → 提交反馈」联系我。反馈时请附上问题现象、复现步骤及 App／iOS 版本，注意隐去截图中的密钥和私人内容。

### 许可与致谢

允许个人自用、修改及按原许可分享源码。分享源码时须保留 Chuli（GitHub: chuli1122）的署名、原项目链接、版权和许可声明；修改版须标明修改事实及非官方身份。商业使用、分发安装包、为他人部署或提供原版／修改版服务，无论收费与否，均须按 [许可](LICENSE) 取得授权。第三方组件按其独立许可处理。

作者在官方发布页提供的个人自签 IPA，可按许可下载、重签和更新，供本人使用；此项不授权使用者向他人再分发安装包或代签代装。

感谢 [すみか（@wxynora）](https://github.com/wxynora) 分享 [AI 语音通话优化教程](https://xhslink.cn/o/7FanSmgKZKv)，为 Tincall 的流式朗读与切段优化提供参考。

感谢 [Silero Team](https://github.com/snakers4/silero-vad)、[Microsoft ONNX Runtime 团队](https://github.com/microsoft/onnxruntime)、[The LAME Project](https://lame.sourceforge.net/) 及各项目贡献者，为本机人声检测、模型运行和音频编码提供支持。组件用途、来源及许可证原文见 [第三方声明](docs/third_party.md)，App 内“关于 Tincall”也提供相关许可和致谢。

## English

Tincall is a native AI voice calling app for iOS 26 and later. It supports direct model connections, your own backend, and MCP (Model Context Protocol), which lets external AI platforms call Tincall's tools. The iPhone handles audio capture, speech service integration, playback, and local call records.

The source is available for personal use, modification, and source sharing under the [license](LICENSE). Source availability does not grant unrestricted open-source rights. Third-party components retain their own licenses; see [third-party notices](docs/third_party.md).

### Choose a call mode

A connector is a service you deploy in your own cloud, on a computer, or on a server to connect the phone to an external AI, relay messages, and manage call state. Click a mode name below for setup steps.

| Mode | Where the AI and context run | What you need | How replies arrive |
| --- | --- | --- | --- |
| [Standalone](docs/setup.en.md#make-a-first-standalone-call) | The iPhone connects directly to your chosen model API | Model, STT, and TTS settings; no connector is needed for everyday calls | Streaming model output, synthesized and played in segments on the phone |
| [Standard MCP](docs/setup.en.md#connect-an-external-ai) | An external AI platform | A Tincall connector, the contact's MCP configuration, and a running AI that can call tools | The AI submits a complete reply with `tincall_reply({text})`, then waits for the next input by default |
| [MCP with a wake bridge](docs/setup.en.md#connect-an-external-ai) | An external AI platform | A connector, an event subscriber, a platform task command, and the dedicated MCP configuration | Each event starts a task; the AI submits a complete reply and ends the task, then wakes again for new input |
| [Backend](docs/setup.en.md#connect-an-external-ai) | Your own backend | Implement the phone protocol, or reuse the connector and supply generation and cancellation endpoints | Streaming deltas or complete replies, as implemented by your backend |

Contacts have three modes: standalone, MCP, and backend. A wake bridge is one way to connect MCP. Your backend determines the model, persona, memory, tools, and application logic; Tincall does not require a new model session for every call.

Standalone mode supports OpenAI-compatible, Anthropic, and Gemini protocols. STT options include Apple, iFlytek, Alibaba Cloud Bailian, and Whisper-compatible services. TTS options include ElevenLabs, MiniMax, and Fish Audio. Available models, voices, regions, quotas, and fees depend on your chosen provider.

### Source builds and the App Store edition

The default `Tincall` scheme is for personal source builds. Its full core calling functionality does not require a trial or purchase. The `Tincall-AppStore` scheme uses `StoreDebug` / `StoreRelease` configurations and `TINCALL_APP_STORE` to enable the official store edition's trial and one-time unlock flow.

Model, speech, and self-hosting costs depend on their respective providers; purchasing Tincall does not include those third-party services. A source build does not automatically receive access to the publisher's push service. Configure background calls according to the signing and push documentation.

### Get started

1. **Install the iPhone app.** Download `*-selfsign-unsigned.ipa` from the [latest release](https://github.com/chuli1122/Tincall/releases/latest) and follow the [signing guide](docs/setup.en.md#install-a-self-signing-ipa) to re-sign and install it with your own signing credentials, without recompiling. You need an iPhone running iOS 26 or later, and a signing tool that correctly configures the app and extension identifiers and App Group. You can also [build from source](docs/setup.en.md#build-from-source) using a Mac and Xcode.
2. **Configure recognition and speech.** Follow the [first-call setup](docs/setup.en.md#make-a-first-standalone-call) to add STT and TTS settings in the app, including the provider, model, and voice. TTS expression prompts have model-specific defaults and can be edited. Before using each external service connection, review its recipient and data disclosure and explicitly allow data sharing. A changed address or provider requires confirmation again.
3. **Configure a contact.** In standalone mode, select a model and enter a persona. For MCP or backend mode, follow [Connect an external AI](docs/setup.en.md#connect-an-external-ai).
4. **Test a complete call.** Check service and model availability, then verify audio capture, replies, playback, interruption, and hang-up.

Hanging up on the phone immediately stops generation and playback. Interrupting a reply keeps the call connected. When the AI hangs up through MCP, the phone waits for already received replies to finish playing; playback failure also ends the call. Received content is preserved, with interruption reasons recorded where applicable.

### Connector and included adapters

The repository includes a runnable general-purpose connector. It handles the phone protocol, MCP, call state, message delivery, optional backups, and incoming-call routing. Model generation still requires a real external AI service.

| Component | Purpose | Requirements and limits |
| --- | --- | --- |
| [Node / Supabase connector](connector/README.md) | Reuse the call and storage protocols | Node uses SQLite by default; Supabase uses Edge Functions and a database. Both share production logic and support streaming or complete backend replies |
| [MCP wake adapter](connector/wake-adapter.mjs) | Subscribe to events, read input, and start an external AI command | Configure your platform command, session continuation, and dedicated MCP connection. The AI replies through MCP; command stdout is not used as a reply |
| [Codex HTTP adapter](connector/codex-backend.mjs) | Forward generation and cancellation requests to a local Codex CLI | Requires an installed, authenticated Codex CLI and private adapter configuration. Currently returns complete text replies; images and AI-initiated dialing or hang-up tools are not supported |
| [Push sender](cloudflare/README.md) | Device registration, VoIP incoming calls, and optional Live Activity pushes | Node 24 or a Cloudflare Worker; requires APNs capabilities and credentials that match the app's signing |

The connector installer does not automatically start the adapters or push sender. Standard MCP configuration alone cannot wake an idle AI platform. The current Codex adapter returns complete replies; the Tincall backend protocol itself supports streaming.

Backend mode can use an entirely custom service, or provide only `generation_url` and `cancel_url` to the connector. TTS expression instructions are passed as `expression_prompt`. Implement proactive dialing and hang-up, opening messages, end notifications, and summary write-back as needed. See the [backend documentation](docs/backend_api.md) for responsibilities and formats.

### Deploy a connector

#### Your computer or server

Install Node.js LTS. Node 24 is recommended; Node 22.5 is the minimum and must have built-in SQLite available. Run from the source root:

```sh
# macOS / Linux
sh connector/install-local.sh
```

```powershell
# Windows; WSL is not required
powershell -NoProfile -ExecutionPolicy Bypass -File connector\install-local.ps1
```

Docker is also supported. The connector listens on loopback by default. The phone needs a reachable HTTPS address; follow the [computer/server setup guide](docs/setup.en.md#node-on-your-computer-or-server) to configure access through a reverse proxy or tunnel. Enter the HTTPS base address and phone token under “Connect to an existing service” in the app. Keep the computer running. Temporary tunnel addresses may change after restarting.

#### Supabase

In the app, open Settings → Tincall Cloud → Deploy or update service, then deploy using your own project and a management token restricted to that project. Save the regular connection after deployment. Adding an MCP contact does not require redeployment. CLI deployment is also available; see the [deployment guide](docs/setup.en.md#supabase-from-a-computer).

Updating the app does not update an existing cloud service. Upgrade through the original deployment method and preserve its tokens and data. Do not replace an existing configuration with a separate first-time setup. Image migrations are included in the app's deployment flow and CLI deployment; no manual SQL step is needed. See [image messages](docs/message_images.md). The base migration creates the private storage bucket and permissions used by recordings and images. Recording retention and backup must still be enabled separately.

### Optional features and data

- Call text and summaries can be saved locally. Recording retention is opt-in for each side of the call. Cloud sync, recording backups, and background incoming calls are configured separately.
- Local Data & Backups lets you separately clear recordings, message images, or all call records, with confirmation. This affects only local data; contacts, connection settings, cloud copies, and exported files remain. Image changes that conflict with cloud data require a manual sync choice.
- Saved service, STT, and TTS connections can be deleted from the bottom of their edit screen. One confirmation removes local settings, credentials, and associated selections while preserving contacts, call records, and cloud data. Remote device unbinding runs in the background. An unreachable service does not block local deletion; the app explains that its remote binding may still need cleanup. Other services remain enabled. Wait until an active call or sync finishes before deleting a connection.
- Standalone mode sends requests to your configured model and speech services. MCP and backend modes send call content to the connected platform, which processes it according to its own implementation.
- Credentials are kept in Keychain or the deployer's private configuration and are excluded from ordinary configuration backups. Phone tokens, contact MCP tokens, wake credentials, model credentials, and push credentials serve different purposes.
- Foreground calls use the configured service subscription. Background and locked-screen calls also need matching push entitlements, a device binding and an APNs sender; see the [push setup guide](docs/setup.en.md#configure-background-calls-for-your-signing-team).
- Shortcuts can send text or screenshots to the current call; see [Shortcuts](shortcuts/README.md).

### Code and documentation

The [English setup guide](docs/setup.en.md) covers signing, a first call, connector deployment, MCP/backend setup, push and upgrades. See [release packaging](docs/release.md) for versioning and IPA builds. Detailed protocol references below are primarily in Chinese.

| Path | Contents |
| --- | --- |
| `ios/Tincall/App/` | App entry point, runtime, and system intents |
| `ios/Tincall/Core/` | Model protocols, call coordination, external interfaces, context and summaries, credentials, deployment |
| `ios/Tincall/Voice/` | Audio capture, VAD, STT, TTS, segmentation, playback, and audio routing |
| `ios/Tincall/Features/`, `Storage/` | UI, configuration and records, backups, and cloud sync |
| `ios/TincallCallWidget/`, `ios/LocalPackages/` | Live Activity extension and bundled third-party components |
| `connector/` | Node entry point, SQLite, adapters, installers, and optional Node push sender |
| `supabase/functions/`, `supabase/migrations/` | Shared connector logic, Edge entry point, and database migrations |
| `cloudflare/` | Optional push Worker |
| `ios/Tests/`, `connector/tests/`, `cloudflare/tests/` | Module and protocol checks |

- [Signing and installation](docs/setup.en.md#install-a-self-signing-ipa)
- [Cloud deployment](docs/setup.en.md#deploy-a-connector-only-if-needed)
- [MCP and backend setup](docs/setup.en.md#connect-an-external-ai)
- [MCP tool parameters and behavior](docs/mcp.md)
- [Backend HTTP protocol](docs/backend_api.md)
- [Image messages](docs/message_images.md)
- [Development and testing: environment, commands, and scope](connector/README.md#checks-and-current-limits)
- [Third-party components and assets](docs/third_party.md)

### Feedback

If you encounter a bug or have a suggestion, please contact me through Settings → Help & Guides → Send Feedback in the app. Include what happened, steps to reproduce it, and your app and iOS versions. Hide API keys and private information in screenshots.

### License and acknowledgments

Personal use, modification, and source sharing are permitted under the license. Source redistribution must retain attribution to Chuli (GitHub: chuli1122), the original project link, copyright notices, and the license. Modified versions must identify their changes and unofficial status. Commercial use, distributing installable builds, deploying for others, or providing the original or modified service to others requires authorization under the [license](LICENSE), whether paid or free. Third-party components retain their own licenses.

An IPA provided by the author on the official release page for personal signing may be downloaded, re-signed, and updated for your own use under the license. This does not authorize redistributing the IPA or signing and installing it for others.

Thanks to [すみか (@wxynora)](https://github.com/wxynora) for the [AI voice calling optimization tutorial](https://xhslink.cn/o/7FanSmgKZKv), which informed Tincall's streaming speech and segmentation work.

Thanks to the [Silero Team](https://github.com/snakers4/silero-vad), the [Microsoft ONNX Runtime team](https://github.com/microsoft/onnxruntime), [The LAME Project](https://lame.sourceforge.net/), and their contributors for local voice activity detection, model inference, and audio encoding. See [third-party notices](docs/third_party.md) for component purposes, sources, and license texts. The app's About Tincall screen also includes licenses and acknowledgments.
