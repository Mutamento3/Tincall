// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI
import UIKit

struct RoleContextSettings: View {
    @Binding var role: CallRole
    let connections: [ConnectionProfile]
    let records: [CallRecord]
    let userName: String
    @State private var previewInput = ""
    @State private var preview: CallRequestPreview?
    @State private var errorMessage: String?

    var body: some View {
        SettingsList {
            Section {
                LabeledContent("对话设定", value: role.effectivePersonaEnabled ? String(localized: "使用已填写的设定") : String(localized: "未填写"))
                LabeledContent("历史摘要", value: role.effectiveHistorySummaryCount > 0 ? String(localized: "最近 \(role.effectiveHistorySummaryCount) 条") : String(localized: "不携带"))
                if role.canReorderContextModules {
                    SettingsPickerRow(title: String(localized: "排列顺序"), value: role.effectiveContextModuleOrder.first == .historySummaries ? String(localized: "历史摘要 → 对话设定") : String(localized: "对话设定 → 历史摘要"), selection: Binding(get: { role.effectiveContextModuleOrder.first == .historySummaries }, set: { summariesFirst in
                        role.contextModuleOrder = summariesFirst ? [.historySummaries, .persona, .currentConversation] : [.persona, .historySummaries, .currentConversation]
                    })) {
                        Text("对话设定 → 历史摘要").tag(false)
                        Text("历史摘要 → 对话设定").tag(true)
                    }
                }
            } header: { SettingsSectionHeading(number: "01", title: String(localized: "上下文内容"), caption: "CONTEXT") } footer: {
                Text("通话场景说明自动携带。对话设定填写后自动使用，留空则不携带。摘要关闭或携带条数为 0 时不带入历史摘要。当前通话按时间顺序放在最后。")
                .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("最多携带", value: String(localized: "\(role.effectiveContextCharacterBudget) 字符"))
            } header: { SettingsSectionHeading(number: "02", title: String(localized: "上下文上限"), caption: "LIMIT") } footer: {
                Text("在联系人编辑页的「上下文上限」修改。优先保留本轮输入；字符数不等于 token 数，请为模型回复留出空间。")
                .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                SettingsField(title: String(localized: "试写一句话")) {
                    TextField("查看这句话会带上哪些上下文", text: $previewInput, axis: .vertical)
                        .lineLimit(2...5)
                }
                Button("生成预览", action: makePreview)
                    .foregroundStyle(Color.accentColor)
                Text("只在本机展示，不发起模型请求，也不显示凭据。")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { SettingsSectionHeading(number: "03", title: String(localized: "实际请求预览"), caption: "PREVIEW") }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
            if let preview {
                Section {
                    LabeledContent("字符数", value: "\(preview.characterCount) / \(preview.characterBudget)")
                    LabeledContent("带入摘要", value: "\(preview.includedSummaryCount)")
                    ScrollView(.vertical) {
                        Text(preview.requestJSON)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(height: 320)
                } header: { SettingsSectionHeading(number: "04", title: String(localized: "预览结果"), caption: "RESULT") }
            }
        }
        .modifier(SettingsPageStyle(title: String(localized: "上下文与预览"), subtitle: String(localized: "系统提示、历史记录与请求预览"), symbol: "text.alignleft", index: "CONTEXT"))
        .onChange(of: role) { preview = nil }
        .onChange(of: previewInput) { preview = nil }
        .onChange(of: userName) { preview = nil }
    }

    private func makePreview() {
        do {
            guard let connection = connections.first(where: { $0.id == role.modelConnectionID }) else {
                throw TincallError(message: String(localized: "请先选择聊天模型"))
            }
            preview = try CallContextBuilder.requestPreview(role: role, connection: connection,
                                                            historyRecords: records, input: previewInput,
                                                            ttsConnection: connections.first(where: { $0.id == role.ttsConnectionID }),
                                                            userName: userName)
            errorMessage = nil
        } catch {
            preview = nil
            errorMessage = error.localizedDescription
        }
    }
}

struct RoleContextLimitRow: View {
    @Binding var role: CallRole
    @State private var budgetText: String
    @FocusState private var budgetIsFocused: Bool

    init(role: Binding<CallRole>) {
        _role = role
        _budgetText = State(initialValue: String(role.wrappedValue.effectiveContextCharacterBudget))
    }

    private var validBudget: Int? {
        guard let value = Int(budgetText), (1_000...200_000).contains(value) else { return nil }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("上下文上限").foregroundStyle(.primary)
                Spacer()
                TextField("60000", text: $budgetText)
                    .keyboardType(.numberPad).focused($budgetIsFocused)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .frame(width: 90).frame(minHeight: 31)
                    .accessibilityLabel("上下文字符上限")
                Text("字符").font(.caption).foregroundStyle(.secondary)
            }
            if validBudget == nil {
                Text("请输入 1,000～200,000 的整数。")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .onChange(of: budgetText) {
            if let value = validBudget { role.contextCharacterBudget = value }
        }
        .onChange(of: budgetIsFocused) {
            if !budgetIsFocused && validBudget == nil { budgetText = String(role.effectiveContextCharacterBudget) }
        }
        .toolbar {
            if budgetIsFocused {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { budgetIsFocused = false }
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }
}

struct RoleSummarySettings: View {
    let isExisting: Bool
    let connection: ConnectionProfile?
    let records: [CallRecord]
    private let roleID: UUID
    private let userName: String
    private let contactName: String
    @State private var previewRecordID: UUID?
    @State private var previewText = ""
    let onSave: (String, Int?) throws -> Void
    @State private var prompt: String
    @State private var targetLength: String
    @State private var modelSelectionNeedsSaving: Bool
    @State private var savedPrompt: String
    @State private var savedTargetLength: String
    @State private var errorMessage: String?
    @State private var actionConfirmed = false
    @State private var actionFeedbackTrigger = 0
    @State private var confirmationToken = UUID()
    @FocusState private var targetLengthIsFocused: Bool

    init(role: CallRole, isExisting: Bool, connection: ConnectionProfile?, records: [CallRecord], userName: String,
         hasUnsavedModelSelection: Bool = false, onSave: @escaping (String, Int?) throws -> Void) {
        self.isExisting = isExisting
        self.connection = connection
        self.records = records
        self.roleID = role.id
        self.userName = userName
        self.contactName = role.displayName
        _modelSelectionNeedsSaving = State(initialValue: hasUnsavedModelSelection)
        self.onSave = onSave
        let length = role.summaryMaxCharacters.map { String($0) } ?? ""
        _prompt = State(initialValue: role.effectiveSummaryPrompt)
        _targetLength = State(initialValue: length)
        _savedPrompt = State(initialValue: role.effectiveSummaryPrompt)
        _savedTargetLength = State(initialValue: length)
    }

    private var hasUnsavedChanges: Bool {
        prompt != savedPrompt || targetLength != savedTargetLength
    }

    var body: some View {
        SettingsList {
            Section {
                TextEditor(text: $prompt)
                    .font(.subheadline)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120, maxHeight: 180)
                    .padding(8)
                    .background(Color.settingsSurface(), in: RoundedRectangle(cornerRadius: 4))
                    .accessibilityLabel("摘要提示词")
                    .listRowSeparator(.hidden)
                Button("恢复默认提示词") { prompt = CallRole.defaultSummaryPrompt }
                    .font(.caption).foregroundStyle(Color.accentColor)
            } header: { SettingsSectionHeading(number: "01", title: String(localized: "摘要提示词"), caption: "PROMPT") } footer: {
                Text("通话结束后，摘要模型会收到这里的提示词、目标字数和本次通话文字。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Text("目标长度")
                    Spacer()
                    TextField(text: $targetLength, prompt: Text(verbatim: "500")) {
                        Text("目标长度")
                    }
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    .frame(maxWidth: 150)
                    .focused($targetLengthIsFocused)
                    Text("字").foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { targetLengthIsFocused = true })
            } header: { SettingsSectionHeading(number: "02", title: String(localized: "摘要长度"), caption: "LENGTH") } footer: {
                Text("目标字数用于提示模型，不能保证严格一致。")
                .font(.footnote).foregroundStyle(.secondary)
            }
            summaryPreview
            if !isExisting {
                Section {
                    Text("新建联系人时，摘要设置随联系人一起保存。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
        }
        .modifier(SettingsPageStyle(title: String(localized: "通话摘要"), subtitle: String(localized: "生成要求 · 目标字数 · 请求预览"), symbol: "text.book.closed", index: "CALL SUMMARY",
                                   actionTitle: String(localized: "保存"), actionSymbol: "checkmark",
                                   actionDisabled: !hasUnsavedChanges && !modelSelectionNeedsSaving,
                                   actionConfirmed: actionConfirmed, actionFeedbackTrigger: actionFeedbackTrigger,
                                   onAction: { _ = save() },
                                   hasUnsavedChanges: hasUnsavedChanges,
                                   onSaveBeforeDismiss: { completion in if save() { completion() } }))
        .toolbar {
            if targetLengthIsFocused {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { targetLengthIsFocused = false }
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    private var availableRecords: [CallRecord] {
        records.filter { $0.roleID == roleID && $0.endedAt != nil && !$0.messages.isEmpty }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private func parsedTargetLength() throws -> Int? {
        let text = targetLength.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard text.allSatisfy({ $0.isNumber }), let value = Int(text), value > 0 else {
            throw TincallError(message: String(localized: "请输入大于 0 的目标字数，或留空使用默认 500 字。"))
        }
        return value
    }

    private var previewResult: Result<String, Error> {
        Result {
            guard let connection else { throw TincallError(message: String(localized: "请先选择摘要模型")) }
            let transcript: String
            let previewContactName: String
            if let previewRecordID, let record = availableRecords.first(where: { $0.id == previewRecordID }) {
                transcript = CallSummaryRequestBuilder.transcript(from: record.messages)
                previewContactName = record.roleName
            } else {
                transcript = previewText
                previewContactName = contactName
            }
            let messages = CallSummaryRequestBuilder.messages(prompt: prompt, targetLength: try parsedTargetLength() ?? 500,
                                                              transcript: transcript, userName: userName,
                                                              contactName: previewContactName)
            let data = try ModelRequestCodec.requestBody(connection: connection, messages: messages, stream: false)
            guard let json = String(data: data, encoding: .utf8) else {
                throw TincallError(message: String(localized: "请求预览编码失败"))
            }
            return json
        }
    }

    private var summaryPreview: some View {
        Section {
            if let connection {
                LabeledContent("摘要模型", value: connection.name)
            }
            if !availableRecords.isEmpty {
                SettingsPickerRow(title: String(localized: "预览内容"),
                                  value: availableRecords.first(where: { $0.id == previewRecordID })?.startedAt.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "填写预览文字"),
                                  selection: $previewRecordID) {
                    Text("填写预览文字").tag(nil as UUID?)
                    ForEach(availableRecords) { record in
                        Text(record.startedAt.formatted(date: .abbreviated, time: .shortened)).tag(Optional(record.id))
                    }
                }
            }
            if previewRecordID == nil {
                SettingsField(title: String(localized: "用于预览的通话文字")) {
                    TextField("填写通话文字，查看完整请求", text: $previewText, axis: .vertical)
                        .lineLimit(3...8)
                }
                if previewText.isEmpty {
                    Text("尚未填写通话文字，下方请求的通话正文为空。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            switch previewResult {
            case .success(let json):
                ScrollView(.vertical) {
                    Text(verbatim: json)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                }
                .frame(height: 320)
                .background(Color.settingsSurface(), in: RoundedRectangle(cornerRadius: 4))
                .listRowSeparator(.hidden)
            case .failure(let error):
                Text(error.localizedDescription).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            SettingsSectionHeading(number: "03", title: String(localized: "完整请求预览"), caption: "PREVIEW")
        } footer: {
            Text("使用当前页面的设置与所选摘要模型生成完整请求正文，包含模型参数。选择已有通话或填写文字即可预览；不会发送请求，也不包含密钥。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func save() -> Bool {
        do {
            let characters = try parsedTargetLength()
            try onSave(prompt, characters)
            targetLength = characters.map { String($0) } ?? ""
            modelSelectionNeedsSaving = false
            savedPrompt = prompt
            savedTargetLength = targetLength
            errorMessage = nil
            targetLengthIsFocused = false
            actionConfirmed = true
            actionFeedbackTrigger &+= 1
            let token = UUID()
            confirmationToken = token
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                guard confirmationToken == token else { return }
                actionConfirmed = false
            }
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
}
