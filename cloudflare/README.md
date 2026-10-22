# Tincall 推送发送端

[English setup and push instructions](../docs/setup.en.md#configure-background-calls-for-your-signing-team)

推送发送端只处理设备绑定、来电路由和可选实时活动启动，不接收聊天正文、图片、录音或摘要。链路是：使用者的连接端 → 发送端 → Apple APNs → iPhone PushKit／CallKit。Apple 接受请求不等于手机已响铃或接听。

可以选择仓库的 Node 24 发送端，或 Cloudflare Worker。两者对连接端提供相同方向的设备／来电接口；不用同时部署。普通前台通话不要求推送，后台来电需与 App 签名相匹配的 Apple 权限和凭据。

## 商店版自动接入

商店版构建 11 起，在 App 内部署或更新自己的 Supabase 项目时，会为尚未配置发送端的项目自动接入官方推送服务。每个项目使用独立的推送凭据，官方服务验证项目控制权后开通，不接收 Supabase 部署令牌、手机访问令牌或聊天内容。已有发送端配置保留；开通失败可重试部署继续完成。

开通服务不会自动开启后台来电，仍需在设置中开启并完成设备绑定。自签版继续按下方步骤使用与自己的签名团队匹配的发送端，不自动开通官方服务。

## 自签后台来电配置步骤

下载官方 IPA 后个人重签，和从源码自行构建，使用相同的推送链路。安装成功不代表推送权限可用。免费 Personal Team 不提供这里需要的 APNs 能力；这种安装方式可以使用普通拨出通话及已配置服务的前台来电，不应开启后台来电。

### 1. 准备自己的 Apple 签名和推送权限

在 [Apple Developer](https://developer.apple.com/account/) 使用具备推送能力的开发者团队：

1. 为自己的主 App 注册显式 App ID，例如 `com.yourname.tincall`，开启 Push Notifications；为实时活动扩展注册对应的扩展标识，并按 [自签指南](../docs/SELF_SIGN.md) 配置共享 App Group。
2. 为主 App 和扩展生成匹配的描述文件。主 App 的描述文件及最终签名须包含 `aps-environment`，重签工具不能将其移除或改成描述文件未授权的值。
3. 在该团队创建允许此 App 对应 topic 和环境的 APNs authentication key，保存 `.p8`，记下 Team ID 和 Key ID。需要远端启动实时活动时，密钥也须允许其 topic。

只有可安装 IPA 的签名证书，不等于拥有相同团队的 APNs 发送权限。使用他人的签名服务时，需另行确认其是否提供匹配的推送方案。不能把作者的 Team、APNs 私钥或官方推送服务当作自行签名后的默认配置。

### 2. 对齐重签后的标识

以下均以**最终重签后的主 App**为准，不照抄原包的 `com.tincall.app`：

| 项目 | 示例或要求 |
| --- | --- |
| 主 App Bundle ID | `com.yourname.tincall` |
| 扩展 Bundle ID | 以主 App 标识加点开头，例如 `com.yourname.tincall.CallWidget` |
| App Group | 两个 target 的描述文件、签名权限和主 App 的 `TincallAppGroupIdentifier` 指向同一已授权组 |
| Worker `APNS_TOPIC`／Node `TINCALL_APNS_TOPIC` | `com.yourname.tincall.voip`，必须包含 `.voip` 后缀 |
| 实时活动 topic | 发送端自动从 VoIP topic 派生为 `com.yourname.tincall.push-type.liveactivity` |
| 主 App `aps-environment` | `development` 对应 APNs sandbox；`production` 对应 APNs production |
| Team ID、Key ID、`.p8` | 密钥来自签名对应团队，并允许上述 topic 和所用环境 |

App 从嵌入的描述文件读取自签环境。不要按 IPA 文件名、Debug／Release 名称猜环境，也不要用生产环境重试开发环境的设备 token。换签名团队、App 标识或环境后，重新在 App 完成设备绑定。

### 3. 选择并配置一个发送端

下面的 Node 或 Cloudflare 路径供自签版和源码版使用。使用自己的签名与 App 标识时，应部署与之匹配的发送端；这两类安装即使在 App 中部署 Supabase，也不会自动创建 APNs 密钥或发送端。商店版构建 11 起使用 App 部署时自动接入的官方服务。

## Node 发送端

在支持 Node 24 和出站 HTTP/2 的主机运行 `connector/apns-server.mjs`，前面配置 HTTPS 反向代理。环境变量、设备注册和计划流程见 [连接端 APNs 说明](../connector/README.md#apns-sender-devices-and-schedules)。私密 `.p8` 和持久化设备数据库不进入仓库。手工复制文件时包含 `apns-sender.mjs` 与 `live-activity-push.mjs`。

在仓库外创建仅自己可读写的环境文件，例如 `/absolute/private/apns.env`，内容如下；替换全部占位符，私钥路径指向实际 `.p8`：

```dotenv
PORT=8788
TINCALL_APNS_TEAM_ID=YOUR_TEAM_ID
TINCALL_APNS_KEY_ID=YOUR_KEY_ID
TINCALL_APNS_KEY_FILE=/absolute/private/AuthKey_YOUR_KEY_ID.p8
TINCALL_APNS_TOPIC=com.yourname.tincall.voip
TINCALL_APNS_DATABASE=/absolute/private/tincall-apns.sqlite
TINCALL_PUSH_TOKEN=REPLACE_WITH_RANDOM_SERVICE_TOKEN_AT_LEAST_24_CHARACTERS
```

在源码根目录启动：

```sh
node --env-file=/absolute/private/apns.env connector/apns-server.mjs
```

程序仅监听本机回环地址。将自己的 HTTPS 反向代理指向该端口，保存其 HTTPS 根地址，下一步供连接端使用；持续运行进程并持久保存设备数据库。Node 路径使用 `TINCALL_APNS_*` 变量，不读取下面 Worker 的 `APNS_*` secrets；使用的密钥须允许实际设备环境。

Codex 适配器和 Node APNs 示例都默认使用 8788；同机运行时应为其中一个设置其他端口，不能让两个服务争用同一监听地址。

## Cloudflare Worker

代码为 `cloudflare/push-worker.mjs` 与 `apns.mjs`，共用 `connector/live-activity-push.mjs`。`wrangler.jsonc` 给出 Worker、SQLite Durable Object 和默认 topic 配置；部署者按自己的账号及 App 标识调整名称与 `APNS_TOPIC`，私密值使用 Wrangler secrets：

- `APNS_TEAM_ID`：签名团队。
- `APNS_SANDBOX_KEY_ID`、`APNS_SANDBOX_KEY_P8`：开发环境密钥。
- `APNS_PRODUCTION_KEY_ID`、`APNS_PRODUCTION_KEY_P8`：发行环境密钥；未配置则不提供该环境。
- `PUSH_CLIENTS`：数组，每项 `{ "id": "service-id", "token": "REPLACE_WITH_LONG_RANDOM_SERVICE_TOKEN" }`；token 至少 24 字符，每个数据服务单独配置。

先在 `cloudflare/wrangler.jsonc` 将 Worker 名称改为自己的名称，`vars.APNS_TOPIC` 改成自己主 App 的完整 VoIP topic。在源码根目录，用自己的 Cloudflare 授权运行：

```sh
npx wrangler deploy --config cloudflare/wrangler.jsonc
```

部署后写入 secrets。Team ID、Key ID 和 `PUSH_CLIENTS` 交互输入，`.p8` 从自己的私密文件读入；替换下面的文件路径，命令本身不包含密钥正文：

```sh
npx wrangler secret put APNS_TEAM_ID --config cloudflare/wrangler.jsonc
npx wrangler secret put APNS_SANDBOX_KEY_ID --config cloudflare/wrangler.jsonc
npx wrangler secret put APNS_SANDBOX_KEY_P8 --config cloudflare/wrangler.jsonc < /absolute/private/AuthKey_SANDBOX.p8
npx wrangler secret put PUSH_CLIENTS --config cloudflare/wrangler.jsonc
```

`.p8` 文件须为完整 PEM 私钥，保留首尾标记及换行；secret 值是文件内容，不是文件路径。`PUSH_CLIENTS` 输入 JSON，例如下面的结构，但 token 必须换成自己生成的至少 24 字符随机值：

```json
[{"id":"my-tincall-service","token":"REPLACE_WITH_RANDOM_SERVICE_TOKEN_AT_LEAST_24_CHARACTERS"}]
```

上面的 sandbox 配置用于开发签名。若实际签名为 production，还需配置对应环境的密钥；只使用 production 时可不配置 sandbox：

```sh
npx wrangler secret put APNS_PRODUCTION_KEY_ID --config cloudflare/wrangler.jsonc
npx wrangler secret put APNS_PRODUCTION_KEY_P8 --config cloudflare/wrangler.jsonc < /absolute/private/AuthKey_PRODUCTION.p8
```

Worker 分环境读取上述凭据，未配置的环境会拒绝设备绑定。填入的每份密钥必须具备该环境与对应 topic 的权限。保存部署返回的 `https://自己的-worker.自己的-subdomain.workers.dev` 根地址，供下一步使用。

核对账号实际支持 Durable Objects 及所选计划费用。不要提交 Apple 私钥、Cloudflare 管理 token 或真实 `PUSH_CLIENTS`。仓库不会自动授予发行者现有发送端的使用权限，也不内置共享服务 token。

## 连接数据服务与手机

将发送端 HTTPS 根地址和该数据服务的独立 token，分别配置为连接端的 `TINCALL_PUSH_URL`、`TINCALL_PUSH_TOKEN`。手机用自己的访问令牌调用连接端 `/devices`，由连接端转交发送端并取得绑定；MCP 联系人令牌不能注册设备。

### 4. 给自己的连接端填写发送地址与服务令牌

```dotenv
TINCALL_PUSH_URL=https://YOUR_PUSH_SENDER_HOST
TINCALL_PUSH_TOKEN=THE_SAME_RANDOM_SERVICE_TOKEN
```

- Node 连接端：修改它实际使用的私密环境文件，保留其他配置，然后重启连接端进程；不要将变量只填到 APNs 发送端而遗漏连接端。
- Supabase：在项目 Edge Functions 的 Secrets 添加或更新这两个值；也可用已授权的 Supabase CLI 执行 `supabase secrets set --project-ref YOUR_PROJECT_REF --env-file /absolute/private/push.env`。该文件只需包含上面两个变量，不能包含 Apple 私钥。自签版和源码版的 App 一键部署不会代填这两个自有发送端配置；商店版构建 11 起会在没有发送端时接入官方服务。
- 选择 Node 发送端时，令牌与它的 `TINCALL_PUSH_TOKEN` 一致；选择 Worker 时，与该服务在 `PUSH_CLIENTS` 中的 token 一致。该服务令牌仅用于连接端到发送端，不是手机访问令牌或联系人的 MCP 令牌。

### 5. 在手机完成绑定并测试

1. 在重签安装的 App 中添加自己的 Tincall 连接端地址及**手机访问令牌**，先确认连接可用。
2. 打开「设置 → Tincall 云端 → 后台与定时来电」，开启「允许后台来电」，确认服务显示「已绑定」。App 自动获取并登记 PushKit token，无需手工复制设备 token 或把 `.p8` 填到手机里。
3. 从已配置的 MCP／后端发起真实来电，或为独立模式联系人设置一项定时来电。定时路径还需连接端 worker 正常运行；Supabase 需相应 Cron／Vault 配置，见 [云端部署](../docs/cloud_setup.md)。
4. 分别检查 App 前台、退到后台及锁屏时是否响铃，接听后能否收音、回复、播放和挂断；需要实时活动时另查卡片。

`push_configured: true` 表示连接端已填发送地址和令牌；「已绑定」表示设备已登记。若手机仍不响铃，按下表检查发送端结果、签名与设备设置。

VoIP topic 为自己的 App Bundle ID 加 `.voip`，sandbox／production 由实际设备签名决定。来电 payload 仅含通话、对象、来源和路由标识。解绑删除路由；APNs 410 停用过期绑定。发送端按已接受的通话去重，同一通的重试不会重复响铃；不同通话之间不设重拨冷却时间。

实时活动可登记 `live_activity_start_token`。接听确认及音频交接成功后，手机只在 App 仍处于后台且没有本次通话活动时，经连接端 `/calls/{id}/activity` 请求发送端 `/activities/start`；前台或已有活动时不推。topic 为 App Bundle ID 加 `.push-type.liveactivity`。启动提示使用联系人显示名和本地化「通话中」，不附 sound；显示名仅供当次发送、不写入发送端投递数据库，头像图像留在手机。系统可能展开灵动岛或显示横幅；远程启动失败不会挂断，打开 App 仍可创建本地组件。手机负责后续状态更新和结束；发送端和数据服务均须更新，后者需转发有长度限制的可选 `display_name`。

独立模式定时来电只由服务拨号，接听后的模型仍由手机调用；MCP／后端的 AI 启动由相应接法负责。

## 常见配置问题

| 现象 | 先核对什么 |
| --- | --- |
| App 提示当前安装包无推送权限 | 重签后的描述文件和主 App 签名是否含 `aps-environment`；仅部署云端不能补足签名能力 |
| `apns_configuration_missing` 或 `apns_configuration_invalid` | 是否配置了实际环境的 Team／Key／完整 PEM，topic 是否以 `.voip` 结尾 |
| 连接端到发送端返回 401 | 两边服务令牌是否一致；不要误用手机令牌或 MCP 令牌 |
| `apns_rejected` | 最终主 App Bundle ID、topic、团队、密钥权限和设备环境是否一致；不要跨环境重试 |
| 更换签名或重装后不响铃 | 用新安装包重新绑定，确认仍连接到自己配置的服务 |
| 有来电记录但后台不响铃 | 先查推送任务是否成功，再查实际设备、签名、专注模式与网络；接通和音频继续单独验证 |
