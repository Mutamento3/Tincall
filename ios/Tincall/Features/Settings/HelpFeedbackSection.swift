// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Darwin
import MessageUI
import SwiftUI

struct HelpFeedbackSection: View {
    @Environment(\.openURL) private var openURL
    @State private var showsComposer = false
    @State private var composerFailed = false
    @State private var errorMessage: String?
    @State private var copyFeedbackTrigger: Date?

    var body: some View {
        Section {
            Button(action: composeFeedback) {
                SettingsActionLabel(title: String(localized: "提交反馈"), symbol: "envelope",
                                    detail: FeedbackEmail.address)
            }
            .id("help-feedback")
            // A Section expands into multiple List hosts; present from this single row.
            .sheet(isPresented: $showsComposer, onDismiss: {
                if composerFailed {
                    errorMessage = String(localized: "邮件未能发送。请稍后重试，或复制邮箱和反馈模板后手动发送。")
                    composerFailed = false
                }
            }) {
                FeedbackMailComposer(messageBody: FeedbackEmail.body) { failed in
                    composerFailed = failed
                    showsComposer = false
                }
                .ignoresSafeArea()
                .presentationDetents([.large])
            }
            .alert("邮件反馈", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            Button {
                copy(FeedbackEmail.address)
            } label: {
                SettingsActionLabel(title: String(localized: "复制邮箱"), symbol: "doc.on.doc")
            }
            Button {
                copy(FeedbackEmail.body)
            } label: {
                SettingsActionLabel(title: String(localized: "复制反馈模板"), symbol: "doc.text")
            }
        } header: {
            SettingsSectionHeading(title: String(localized: "仍未解决？"))
        } footer: {
            Text("此邮箱用于官方 App 和未修改源码版本的反馈。若修改过源码，请先确认原版是否存在相同问题；修改引起的问题请自行排查。\n\n会预填版本、iOS 和机型，发送前可修改。截图可自行添加，不自动附带对话或日志。无法打开邮件 App 时，可复制邮箱和模板手动发送。")
        }
        .sensoryFeedback(.success, trigger: copyFeedbackTrigger)
        .preference(key: CopySuccessPreferenceKey.self, value: copyFeedbackTrigger)
    }

    private func composeFeedback() {
        if MFMailComposeViewController.canSendMail() {
            showsComposer = true
            return
        }
        let draft = FeedbackEmail.body
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = FeedbackEmail.address
        components.queryItems = [
            URLQueryItem(name: "subject", value: FeedbackEmail.subject),
            URLQueryItem(name: "body", value: draft)
        ]
        guard let url = components.url else {
            errorMessage = String(localized: "无法打开邮件 App。请复制邮箱和反馈模板，在常用邮箱中发送。")
            return
        }
        openURL(url) { accepted in
            if !accepted {
                errorMessage = String(localized: "无法打开邮件 App。请复制邮箱和反馈模板，在常用邮箱中发送。")
            }
        }
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        copyFeedbackTrigger = Date()
    }
}

@MainActor
private enum FeedbackEmail {
    static let address = "tincall@chuli.win"
    static var subject: String { String(localized: "Tincall 使用反馈") }

    static var body: String {
        String(localized: """
        问题现象：


        复现步骤：
        1.
        2.

        期望结果（选填）：


        使用环境
        安装来源（保留一项）：App Store / 自行构建／签名安装
        是否修改源码（自行构建时填写）：未修改 / 已修改
        原版是否也有相同问题（仅修改版填写）：是 / 否 / 未尝试
        """) + "\n"
        + String(localized: "App 版本：") + TincallVersion.version + " (" + TincallVersion.build + ")\n"
        + "iOS：" + UIDevice.current.systemVersion + "\n"
        + String(localized: "设备型号：") + deviceModel + "\n\n"
        + String(localized: "可自行添加相关截图。请勿附上密钥、访问令牌或私人对话；如需提供日志，请先选取并审阅相关内容。")
    }

    private static var deviceModel: String {
        var system = utsname()
        guard uname(&system) == 0 else { return UIDevice.current.model }
        let capacity = MemoryLayout.size(ofValue: system.machine)
        return withUnsafePointer(to: &system.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
    }
}

private struct FeedbackMailComposer: UIViewControllerRepresentable {
    let messageBody: String
    let onFinish: (Bool) -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients([FeedbackEmail.address])
        controller.setSubject(FeedbackEmail.subject)
        controller.setMessageBody(messageBody, isHTML: false)
        return controller
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) { }

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: (Bool) -> Void

        init(onFinish: @escaping (Bool) -> Void) { self.onFinish = onFinish }

        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult, error: Error?) {
            onFinish(result == .failed || error != nil)
        }
    }
}
