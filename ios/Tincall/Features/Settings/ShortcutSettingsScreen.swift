import SwiftUI

struct ShortcutSettingsScreen: View {
    var body: some View {
        SettingsList {
            Section {
                Text("Tincall 在后台时，也能通过快捷指令随时给 TA 发送文字和截图，回复仍在原通话中播放。")
                    .font(.subheadline).lineSpacing(4)
                Link(destination: URL(string: "https://www.icloud.com/shortcuts/eddf5bf36a5545a5a97ca678a2a49077")!) {
                    SettingsActionLabel(title: String(localized: "添加到快捷指令"), symbol: "plus",
                                        detail: String(localized: "打开分享页面，由你确认添加"))
                }
            } header: { SettingsSectionHeading(title: String(localized: "给 TA 发消息")) }
            Section {
                Text("先在 Tincall 中接通电话，再运行「给 TA 发消息」。")
                Text("选择「截屏」可附上补充文字，选择「文字」可直接输入。确认后发送到当前通话。")
                Text("添加后，可将快捷指令放到主屏幕，或在系统设置中绑定操作按钮、轻点背面。")
            } header: { SettingsSectionHeading(title: String(localized: "使用方法")) }
        }
        .modifier(SettingsPageStyle(title: String(localized: "快捷指令"), subtitle: String(localized: "App 在后台时，也能随时发送文字和截图"),
                                    symbol: "square.stack.3d.up", index: "SHORTCUTS"))
    }
}
