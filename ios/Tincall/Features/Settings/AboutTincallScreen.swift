import SwiftUI

enum TincallVersion {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? String(localized: "未知") }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? String(localized: "未知") }
}

struct AboutTincallScreen: View {
    var body: some View {
        SettingsList {
            Section {
                LabeledContent("版本号", value: TincallVersion.version)
                LabeledContent("构建号", value: TincallVersion.build)
                Link(destination: URL(string: "https://github.com/chuli1122/Tincall")!) {
                    LabeledContent("项目仓库", value: "chuli1122/Tincall")
                }
                explanation(String(localized: "Tincall 是 AI 语音与文字通话工具。你可以在独立模式中选择模型 API，也可以连接已适配的后端或支持 MCP 的 AI 平台。模型、语音服务及外部平台的账号由你选择和配置。"))
            } header: { SettingsSectionHeading(title: "Tincall", caption: "ABOUT") }
            Section {
                explanation(String(localized: "本机：API Key 与访问令牌保存在系统钥匙串。联系人、设置、通话文字、图片、摘要及选择保留的录音保存在 App 本地。双方录音默认不保存；关闭录音不影响实时识别与朗读。"))
                explanation(String(localized: "通话服务：独立模式会把启用的上下文、当前输入及支持的图片发送到所选模型服务；第三方语音识别接收语音，语音合成服务接收待朗读文字。Apple 本机识别在设备上运行，首次使用可能需要下载系统语言模型。"))
                explanation(String(localized: "外部平台：后端和 MCP 模式会把通话输入交给你配置的服务。模型、语音服务和外部平台可能处理相应的通话内容，具体取决于你的配置及其隐私政策。"))
                explanation(String(localized: "自部署云端：通话文字、图片、摘要及你允许同步的录音，在 App 与你部署的云端之间传输，不经过 Tincall 作者运营的服务。数据保存在你选择的服务器或云服务中，其管理者及服务提供方可能按各自权限访问数据。录音同步需单独允许。"))
                explanation(String(localized: "后台来电：App Store 版使用由作者维护的推送发送端。设备推送标识和必要的来电路由信息会在你配置的云端与该发送端之间传输，用于向这台 iPhone 发起来电；来电推送不携带聊天正文或录音。自行签名或自部署的版本需要使用自己的匹配推送服务。"))
                explanation(String(localized: "导出与日志：导出的记录、录音和请求日志可能包含私人对话。日志也可能包含上下文、模型回复和思考内容；分享前请自行审阅，凭据打码不代表内容已匿名。删除本机数据不会自动删除已导出文件或云端副本。"))
            } header: { SettingsSectionHeading(title: String(localized: "数据与隐私"), caption: "PRIVACY") }
            Section {
                explanation(String(localized: "麦克风用于通话收音和识别测试。关联系统联系人时使用你授权的联系人资料；设置头像、背景或发送图片时，由你选择要使用的图片。这些可选操作无需在首次打开 App 时全部授权。"))
                explanation(String(localized: "模型、语音合成、第三方识别、服务器、存储和网络服务可能分别收费，费用和额度由各提供方决定。安装或购买 Tincall 不包含这些第三方服务的额度，也不保证它们持续可用。"))
            } header: { SettingsSectionHeading(title: String(localized: "权限与第三方服务"), caption: "SERVICES") }
            Section {
                explanation(String(localized: "对话内容由你配置的 AI 模型或外部服务生成，不代表 Tincall 或开发者的观点。AI 回复、转写和摘要可能不准确、不完整或产生误导。请核实重要信息，不将其作为医疗、法律、财务等专业意见，也不要依赖 Tincall 处理紧急求助。"))
                explanation(String(localized: "网络中断、账户额度或外部服务变化可能导致延迟、断线和数据保存失败。请关注 App 提示，并为重要记录保留独立备份。手机离线或无法连接 Apple 推送服务时，来电可能延迟或无法响铃。"))
                explanation(String(localized: "请只上传、录制或合成你有权使用的内容，遵守所在地有关录音、个人信息及声音使用的规定，并在需要时取得相关人员同意。第三方模型、音色和平台的使用还受各自条款约束。"))
            } header: { SettingsSectionHeading(title: String(localized: "使用与风险说明"), caption: "IMPORTANT") }
            Section {
                DisclosureGroup("Silero VAD · MIT") {
                    explanation(String(localized: "Silero VAD 用于在设备上检测人声，由 Silero Team 维护，按 MIT 许可使用。"))
                    licenseText(resource: "SileroVAD-LICENSE")
                    Link("Silero VAD", destination: URL(string: "https://github.com/snakers4/silero-vad")!)
                }
                DisclosureGroup("ONNX Runtime 1.24.2 · MIT") {
                    explanation(String(localized: "ONNX Runtime 用于在设备上运行 Silero VAD 模型，由 Microsoft 及项目贡献者维护，按 MIT 许可使用。"))
                    licenseText(resource: "ONNXRuntime-LICENSE")
                    DisclosureGroup("Third-party notices") {
                        licenseText(resource: "ONNXRuntime-ThirdPartyNotices")
                    }
                    Link("ONNX Runtime", destination: URL(string: "https://github.com/microsoft/onnxruntime")!)
                }
                DisclosureGroup("LAME 3.100 · LGPL 2.1") {
                    explanation(String(localized: "原声音频的 MP3 编码使用 LAME 3.100，由 The LAME Project 维护，按 GNU LGPL 2.1 使用。LGPL 允许在满足许可条件时用于商业软件；LAME 的相关权利不受 Tincall 源码许可中的商业使用或再分发限制影响。"))
                    licenseText(resource: "LAME-LICENSE")
                    Link("LAME", destination: URL(string: "https://lame.sourceforge.net/")!)
                    Link("GNU LGPL 2.1", destination: URL(string: "https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html")!)
                }
            } header: { SettingsSectionHeading(title: String(localized: "第三方许可"), caption: "LICENSE") }
            Section {
                explanation(String(localized: "感谢 すみか 分享 AI 语音通话优化教程，为 Tincall 的流式朗读与切段优化提供参考。"))
                explanation(String(localized: "感谢 Silero Team、Microsoft ONNX Runtime 团队、The LAME Project 及各项目贡献者，为本机人声检测、模型运行和音频编码提供支持。"))
            } header: { SettingsSectionHeading(title: String(localized: "致谢"), caption: "THANKS") }
        }
        .modifier(SettingsPageStyle(title: String(localized: "关于 Tincall"), subtitle: String(localized: "版本、数据隐私与使用说明"), symbol: "info.circle", index: "ABOUT"))
    }

    @ViewBuilder
    private func licenseText(resource: String) -> some View {
        if let url = Bundle.main.url(forResource: resource, withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            Text(text).font(.caption).textSelection(.enabled)
        } else {
            explanation(String(localized: "许可文本暂时无法读取，请查看下方组件项目中的许可说明。"))
        }
    }

    private func explanation(_ text: String) -> some View {
        Text(text).font(.subheadline).lineSpacing(4).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
