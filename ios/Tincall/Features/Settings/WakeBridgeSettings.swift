// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI

struct WakeBridgeSettings: View {
    let connection: ConnectionProfile
    @State private var contacts: [WakeBridgeContacts.Contact] = []
    @State private var contactID: String?
    @State private var configurations: [String: WakeBridgeConfiguration] = [:]
    @State private var loadingContacts = true
    @State private var loadingConfiguration = false
    @State private var issue: String?
    @State private var copied = false
    @State private var copyFeedbackTrigger: Date?
    @State private var confirmReset = false
    @State private var mcpUsesSSE = false
    @State private var configurationLoadID: UUID?
    private let client = ExternalCallClient()

    private var configuration: WakeBridgeConfiguration? {
        contactID.flatMap { configurations[$0] }
    }

    var body: some View {
        SettingsList {
            Section {
                Text("接入程序收到通话建立或新消息事件后，自动读取本轮输入，再携带消息启动 AI。AI 通过专用 MCP 回复后结束本轮，下次消息再启动；AI 不需要自己读取或等待下一条消息。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("复制下方配置，按仓库「唤醒桥接入」指南运行接入程序，并自行填写所用 AI 平台的启动命令、配置专用 MCP。也可在支持自动化的平台自行配置同样的接收事件与启动 AI 流程。完成后，每轮消息会自动交给 AI，无需手动读取。")
                    .font(.footnote).foregroundStyle(.secondary)
                SettingsPickerRow(title: String(localized: "联系人"),
                                  value: contacts.first { $0.id == contactID }?.display_name ?? String(localized: "请选择"), selection: $contactID) {
                    Text("请选择").tag(nil as String?)
                    ForEach(contacts) { Text($0.display_name).tag(Optional($0.id)) }
                }
                .disabled(loadingContacts || loadingConfiguration)
                if loadingContacts || loadingConfiguration { ProgressView() }
                if !loadingContacts && contacts.isEmpty && issue == nil {
                    Text("请先在联系人编辑页选择此服务和 MCP 模式，保存联系人后再来获取配置。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let issue { Text(issue).font(.footnote).foregroundStyle(.red) }
                Button("刷新联系人") { Task { await loadContacts() } }
                    .disabled(loadingContacts || loadingConfiguration)
            } header: { SettingsSectionHeading(title: String(localized: "MCP＋唤醒桥"), caption: "WAKE BRIDGE") }

            if let configuration {
                Section {
                    SettingsPickerRow(title: String(localized: "传输方式"), value: mcpUsesSSE ? "SSE" : "HTTP", selection: $mcpUsesSSE) {
                        Text("HTTP（Streamable HTTP）").tag(false)
                        Text("SSE").tag(true)
                    }
                    .onChange(of: mcpUsesSSE) { _, _ in copied = false }
                    LabeledContent("MCP URL") {
                        Text(configuration.mcpEndpoint(usesSSE: mcpUsesSSE).url.absoluteString).textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("唤醒地址") {
                        Text(configuration.wake.url.absoluteString).textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                    Button {
                        do {
                            UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: try configuration.exportText(mcpUsesSSE: mcpUsesSSE)]],
                                                         options: [.expirationDate: Date().addingTimeInterval(600)])
                            copied = true
                            copyFeedbackTrigger = Date()
                        } catch { issue = String(localized: "配置复制失败，请重试。") }
                    } label: {
                        SettingsActionLabel(title: String(localized: "复制接入配置"), symbol: copied ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(loadingConfiguration)
                    .sensoryFeedback(.success, trigger: copyFeedbackTrigger)
                    .preference(key: CopySuccessPreferenceKey.self, value: copyFeedbackTrigger)
                    .task(id: copyFeedbackTrigger) {
                        guard copied else { return }
                        do { try await Task.sleep(for: .seconds(3)) } catch { return }
                        copied = false
                    }
                    .onDisappear { copied = false }
                    Text("配置包含这位联系人的专用凭据，可订阅唤醒并使用其 MCP 通话工具，不能访问其他联系人或备份。只交给你信任的平台；剪贴板内容十分钟后清除。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("重置接入凭据", role: .destructive) { confirmReset = true }
                        .disabled(loadingConfiguration)
                } header: { SettingsSectionHeading(title: String(localized: "接入配置"), caption: "CONFIGURATION") }
            }
        }
        .modifier(SettingsPageStyle(title: String(localized: "获取唤醒桥配置"), subtitle: connection.name, symbol: "bolt", index: "WAKE BRIDGE"))
        .task { await loadContacts() }
        .task(id: contactID) {
            copied = false; issue = nil
            guard let contactID else { return }
            guard configurations[contactID] == nil else { return }
            await loadConfiguration(contactID: contactID, rotate: false)
        }
        .alert("重置接入凭据？", isPresented: $confirmReset) {
            Button("取消", role: .cancel) {}
            Button("重置", role: .destructive) {
                if let contactID { Task { await loadConfiguration(contactID: contactID, rotate: true) } }
            }
        } message: { Text("旧唤醒桥配置将失效，需要重新复制给外部平台。普通 MCP 接入配置不受影响。") }
    }

    @MainActor private func loadContacts() async {
        loadingContacts = true; issue = nil
        defer { loadingContacts = false }
        do {
            let result = try await client.wakeBridgeContacts(connection: connection)
            try Task.checkCancellation()
            contacts = result.contacts
            if !contacts.contains(where: { $0.id == contactID }) {
                contactID = contacts.count == 1 ? contacts.first?.id : nil
            } else if let contactID {
                await loadConfiguration(contactID: contactID, rotate: false)
            }
        } catch {
            guard !Task.isCancelled else { return }
            issue = message(for: error)
        }
    }

    @MainActor private func loadConfiguration(contactID: String, rotate: Bool) async {
        let loadID = UUID()
        configurationLoadID = loadID
        loadingConfiguration = true; issue = nil
        // A reset may commit even if its response is lost. Never offer an old
        // credential for copying after an uncertain reset; a normal read recovers it.
        if rotate { configurations[contactID] = nil; copied = false }
        defer { if configurationLoadID == loadID { loadingConfiguration = false } }
        do {
            let result = try await client.wakeBridgeConfiguration(connection: connection, contactID: contactID, rotate: rotate)
            try Task.checkCancellation()
            guard self.contactID == contactID, configurationLoadID == loadID else { return }
            configurations[contactID] = result
        } catch {
            guard !Task.isCancelled, self.contactID == contactID, configurationLoadID == loadID else { return }
            issue = message(for: error)
        }
    }

    private func message(for error: Error) -> String {
        if let failure = error as? ExternalCallFailure {
            if [404,405,422].contains(failure.status) {
                return String(localized: "服务尚未支持唤醒桥或联系人已变更，请更新一键部署并刷新联系人。")
            }
            if [401,403].contains(failure.status) {
                return String(localized: "无法读取唤醒桥，请检查此服务的手机访问令牌。")
            }
        }
        return String(localized: "唤醒桥配置未能读取，请检查连接后重试。")
    }
}
