// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI

struct CloudBackupScreen: View {
    let configuration: LocalConfigurationStore
    let records: CallRecordStore
    let sync: CloudSyncStore
    let isCallActive: Bool
    @State private var loadingError: String?
    @State private var confirmation: Confirmation?
    @State private var operation: Task<Void, Never>?
    @State private var searchText = ""
    @State private var activeRecordID: UUID?

    private enum Confirmation: Identifiable {
        case destination, media, delete(UUID), deleteAll(ConnectionProfile, [CloudSyncRemote]), useLocal(UUID), restore(UUID, Bool), discard
        var id: String {
            if case .deleteAll(let connection, _) = self { return "delete-all-\(connection.id)" }
            return String(describing: self)
        }
        var isDestructive: Bool {
            switch self { case .delete, .deleteAll, .discard: true; default: false }
        }
        var recordID: UUID? {
            switch self {
            case .delete(let id), .useLocal(let id), .restore(let id, _): id
            default: nil
            }
        }
    }

    private var connection: ConnectionProfile? {
        configuration.connections.first { $0.id == sync.selectedConnectionID && $0.provider == .genericConnector }
    }

    var body: some View {
        SettingsList { backupSections(sync) }
            .modifier(SettingsPageStyle(title: String(localized: "云端同步"), subtitle: String(localized: "在本机与自己的云端之间同步通话记录"), symbol: "icloud", index: "SYNC"))
        .task(id: isCallActive ? nil : connection?.id) {
            guard let connection, !isCallActive, !sync.isBusy, !sync.connected else { return }
            if await sync.refresh(connection: connection) { confirmation = .destination }
        }
        .alert("云端操作未完成", isPresented: Binding(get: { activeRecordID == nil && (sync.errorMessage != nil || loadingError != nil) }, set: { if !$0 { sync.clearError(); loadingError = nil } })) {
            Button("好", role: .cancel) { sync.clearError(); loadingError = nil }
        } message: { Text(sync.errorMessage ?? loadingError ?? "") }
        .confirmationDialog(confirmationTitle, isPresented: Binding(get: { confirmation != nil && confirmation?.recordID == nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
            confirmationButtons
        } message: { Text(confirmationMessage) }
    }

    @ViewBuilder private func backupSections(_ sync: CloudSyncStore) -> some View {
        if !configuration.connections.contains(where: { $0.provider == .genericConnector }) {
            Section {
                Text("请到「设置 → Tincall 云端」部署或连接服务。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { SettingsSectionHeading(title: String(localized: "同步服务"), caption: "SERVICE") }
        }
        if configuration.connections.contains(where: { $0.provider == .genericConnector }) {
            Section {
                SettingsPickerRow(title: String(localized: "使用的云端"), value: connection?.name ?? String(localized: "未选择"), selection: Binding(get: { sync.selectedConnectionID }, set: { id in save { try sync.select(id) } })) {
                    Text("未选择").tag(nil as UUID?)
                    ForEach(configuration.connections.filter { $0.provider == .genericConnector }) { value in
                        Text(value.name).tag(Optional(value.id))
                    }
                }
                .disabled(sync.isBusy || isCallActive)
                if let connection {
                    DisclosureGroup("服务地址") {
                        Text(connection.endpoint?.absoluteString ?? String(localized: "尚未填写地址"))
                            .font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            } header: { SettingsSectionHeading(title: String(localized: "同步服务"), caption: "SERVICE") }
        }
        if connection != nil {
            Section {
                Toggle("自动同步通话内容", isOn: Binding(get: { sync.automaticSyncEnabled }, set: { enabled in save { try sync.setAutomaticSyncEnabled(enabled) } }))
                if let connection {
                    Button("立即同步") {
                        run {
                            do { try sync.setTextSyncEnabled(true) }
                            catch { loadingError = error.localizedDescription; return }
                            await sync.synchronize(connection: connection)
                        }
                    }
                    .disabled(sync.isBusy || isCallActive)
                }
            } header: { SettingsSectionHeading(title: String(localized: "通话内容"), caption: "CALLS") } footer: {
                Text("同步文字、图片和摘要：本机更新上传到云端，云端更新下载到本机。开启后在打开 App、回到前台或通话保存后自动同步；通话期间暂停。联系人与设置保留在本机。")
                .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Toggle("同步已保存的录音", isOn: Binding(get: { sync.mediaEnabled }, set: { enabled in
                    if enabled { confirmation = .media } else { save { try sync.setMediaEnabled(false) } }
                }))
                .disabled(!sync.mediaEnabled && (!sync.connected || sync.isBusy))
                if !sync.connected {
                    Text(sync.isBusy ? String(localized: "正在连接云端，连接成功后可开启录音同步。") : String(localized: "请先在下方刷新云端记录，连接成功后可开启录音同步。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let connection {
                    Button("上传本机已有录音") { run { await sync.backupMedia(connection: connection) } }
                        .disabled(!sync.mediaEnabled || sync.isBusy || isCallActive)
                }
            } header: { SettingsSectionHeading(title: String(localized: "录音"), caption: "AUDIO") } footer: {
                Text("录音文件可能较大，会占用云端存储和上传、下载流量，因此默认不同步。允许后，自动同步会上传已保存的录音，并下载本机缺少的录音。此开关不会开启通话录音。")
                .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Text(sync.status).font(.footnote)
                if let connection {
                    Button("刷新云端记录") {
                        run { if await sync.refresh(connection: connection) { confirmation = .destination } }
                    }
                        .disabled(sync.isBusy || isCallActive)
                }
                if sync.isBusy {
                    ProgressView()
                    if let operation {
                        Button("停止本次操作") { operation.cancel() }
                    } else if sync.automaticSyncEnabled {
                        Button("停止自动同步") { save { try sync.setAutomaticSyncEnabled(false) } }
                    }
                }
                if sync.hasPendingOperation, let connection {
                    Button("继续上次操作") { run { await sync.continuePending(connection: connection) } }
                        .disabled(sync.isBusy || isCallActive)
                    if sync.canDiscardPending {
                        Button("清理未提交的操作", role: .destructive) { confirmation = .discard }
                            .disabled(sync.isBusy || isCallActive)
                    }
                }
                if isCallActive { Text("通话结束后再同步或恢复记录。").foregroundStyle(.secondary) }
            } header: { SettingsSectionHeading(title: String(localized: "同步状态"), caption: "STATUS") } footer: {
                Text("刷新只读取云端列表。「立即同步」会上传和下载通话内容，即使自动同步已关闭也可使用。")
                    .font(.footnote).foregroundStyle(.secondary)
                if sync.hasPendingOperation {
                    Text("未完成的操作已保存在本机。继续时沿用原请求，提交结果未确认前不会删除已上传录音。")
                    .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        if !sync.remoteRecords.isEmpty {
            Section {
                NavigationLink {
                    cloudRecords
                } label: {
                    SettingsActionLabel(title: String(localized: "云端记录"), symbol: "clock",
                                        detail: String(localized: "共 \(sync.remoteRecords.count) 通"))
                }
                if let connection {
                    Button("清空当前云端备份", role: .destructive) {
                        run {
                            if let selection = await sync.backupsForDeletion(connection: connection), !selection.isEmpty {
                                confirmation = .deleteAll(connection, selection)
                            }
                        }
                    }
                    .disabled(sync.isBusy || isCallActive || sync.hasPendingOperation || !sync.remoteRecords.contains(where: { !$0.deleted }))
                }
            } header: { SettingsSectionHeading(title: String(localized: "记录管理"), caption: "RECORDS") }
        }
    }

    private var cloudRecords: some View {
        SettingsList {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索联系人或日期", text: $searchText)
                        .autocorrectionDisabled()
                }
            }
            Section {
                ForEach(visibleRemoteRecords) { remote in
                    NavigationLink {
                        cloudRecordDetails(id: remote.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(recordName(remote)).foregroundStyle(.primary)
                            if let date = recordDate(remote) {
                                Text(date, format: .dateTime.year().month().day().hour().minute())
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            if remote.deleted {
                                Text("云端已删除").font(.caption).foregroundStyle(.secondary)
                            } else if sync.conflicts.contains(remote.id) {
                                Text("需要处理冲突").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
                if visibleRemoteRecords.isEmpty {
                    Text("没有找到匹配的通话").foregroundStyle(.secondary)
                }
            }
        }
        .modifier(SettingsPageStyle(title: String(localized: "云端记录"), subtitle: String(localized: "选择一通电话，查看并管理云端副本"), symbol: "clock", index: "CLOUD RECORDS"))
    }

    private var visibleRemoteRecords: [CloudSyncRemote] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return sync.remoteRecords.filter { remote in
            query.isEmpty || recordName(remote).localizedStandardContains(query) ||
                recordDate(remote)?.formatted(.dateTime.year().month().day().hour().minute()).localizedStandardContains(query) == true
        }.sorted { (recordDate($0) ?? .distantPast) > (recordDate($1) ?? .distantPast) }
    }

    private func recordName(_ remote: CloudSyncRemote) -> String {
        records.records.first { $0.id == remote.id }?.roleName ?? remote.record?.call.roleName ?? String(localized: "云端通话")
    }

    private func recordDate(_ remote: CloudSyncRemote) -> Date? {
        records.records.first { $0.id == remote.id }?.startedAt ?? remote.record?.call.startedAt ?? updatedDate(remote)
    }

    private func updatedDate(_ remote: CloudSyncRemote) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: remote.updated_at) ?? ISO8601DateFormatter().date(from: remote.updated_at)
    }

    private func cloudRecordDetails(id: UUID) -> some View {
        SettingsList {
            if let remote = sync.remoteRecords.first(where: { $0.id == id }) {
                Section {
                    Text(recordName(remote)).font(.headline)
                    if let date = recordDate(remote) {
                        Text(date, format: .dateTime.year().month().day().hour().minute())
                            .foregroundStyle(.secondary)
                    }
                    if let date = updatedDate(remote) {
                        LabeledContent("云端更新", value: date.formatted(.dateTime.year().month().day().hour().minute()))
                    }
                    if remote.deleted { Text("云端已删除，本机副本保留").foregroundStyle(.secondary) }
                    if sync.conflicts.contains(id) { Text("版本冲突，尚未覆盖任一份内容").foregroundStyle(.orange) }
                } header: { SettingsSectionHeading(title: String(localized: "通话信息"), caption: "CALL") }
                Section {
                    if !remote.deleted {
                        Button("下载云端内容") { confirmation = .restore(id, false) }
                        if sync.mediaEnabled { Button("下载内容与已备份录音") { confirmation = .restore(id, true) } }
                    }
                    if records.records.contains(where: { $0.id == id }) {
                        Button(remote.deleted ? String(localized: "重新建立云端副本") : String(localized: "用本机内容更新云端")) { confirmation = .useLocal(id) }
                    }
                    if !remote.deleted { Button("删除云端副本", role: .destructive) { confirmation = .delete(id) } }
                } header: { SettingsSectionHeading(title: String(localized: "管理副本"), caption: "ACTIONS") }
                .disabled(sync.isBusy || isCallActive)
                if sync.isBusy { ProgressView("正在处理…") }
            }
        }
        .modifier(SettingsPageStyle(title: String(localized: "云端通话"), subtitle: String(localized: "管理这通电话的云端副本"), symbol: "icloud", index: "CLOUD RECORD"))
        .onAppear { activeRecordID = id }
        .onDisappear { if activeRecordID == id { activeRecordID = nil } }
        .confirmationDialog(confirmationTitle, isPresented: Binding(get: { confirmation?.recordID == id }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
            confirmationButtons
        } message: { Text(confirmationMessage) }
        .alert("云端操作未完成", isPresented: Binding(get: { activeRecordID == id && (sync.errorMessage != nil || loadingError != nil) }, set: { if !$0 { sync.clearError(); loadingError = nil } })) {
            Button("好", role: .cancel) { sync.clearError(); loadingError = nil }
        } message: { Text(sync.errorMessage ?? loadingError ?? "") }
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .destination: return String(localized: "确认同步目标？")
        case .media: return String(localized: "允许录音上传与下载？")
        case .delete: return String(localized: "删除这通电话的云端副本？")
        case .deleteAll: return String(localized: "清空当前云端备份？")
        case .useLocal: return String(localized: "用本机文字更新云端？")
        case .restore: return String(localized: "恢复此云端版本？")
        case .discard: return String(localized: "清理未提交的云端操作？")
        case nil: return String(localized: "确认操作")
        }
    }

    private var confirmationMessage: String {
        switch confirmation {
        case .destination:
            return String(localized: "目的地：\(connection?.endpoint?.absoluteString ?? String(localized: "未配置"))。将读取此服务和当前令牌所属账户的记录；之后会按已开启的同步设置向该目标发送通话文字、图片、摘要及另行允许的录音。请确认这是你信任的服务和账户。")
        case .media:
            return String(localized: "目的地：\(connection?.endpoint?.absoluteString ?? String(localized: "未配置"))。录音包含声音和对话隐私，会保存到该项目的私有存储；项目管理者可访问。上传、存储及下载可能产生费用。开启自动同步后，会上传本机已保存的录音，并下载云端已有的录音，不会开启新的录音。")
        case .delete: return String(localized: "将删除这通电话的云端文字、图片、摘要和已备份录音，本机记录保留。之后自动同步或手动点击同步，都不会将这通记录重新上传；其他通话仍正常同步。")
        case .deleteAll(let connection, let selection):
            return String(localized: "将删除「\(connection.name)」中的 \(selection.count) 通云端备份，包括文字、图片、摘要和已备份录音。本机记录、MCP 通话数据和来电计划保留。已删除的记录不会随自动或手动同步重新上传，之后的新通话仍正常同步。")
        case .useLocal: return String(localized: "按当前云端版本提交本机文字与摘要。此操作可能替换另一台设备保存的文字，已有云端录音保留；若版本又有变化会再次停止。")
        case .restore(_, let media): return String(localized: "本机文字不同时先另存完整本机副本，再采用云端文字。\(media ? String(localized: "同时下载云端已备份录音，可能产生流量费用。") : String(localized: "不下载云端录音，本机已保存录音尽量保留。"))不会恢复旧通话的发送或取消任务。")
        case .discard: return String(localized: "清理本次未发布且未被云端记录引用的图片和录音对象，保留本机记录及已发布的云端内容。")
        case nil: return ""
        }
    }

    @ViewBuilder private var confirmationButtons: some View {
        if let confirmation, let connection {
            Button("确认", role: confirmation.isDestructive ? .destructive : nil) {
                switch confirmation {
                case .destination: run { await sync.refresh(connection: connection, confirmDestinationChange: true) }
                case .media: save { try sync.setMediaEnabled(true) }
                case .delete(let id): run { await sync.deleteRemote(connection: connection, id: id) }
                case .deleteAll(let selectedConnection, let selection):
                    run { await sync.deleteAllRemote(connection: selectedConnection, selection: selection) }
                case .useLocal(let id):
                    run {
                        do { try sync.setTextSyncEnabled(true) }
                        catch { loadingError = error.localizedDescription; return }
                        await sync.useLocal(connection: connection, id: id)
                    }
                case .restore(let id, let media): run { await sync.restore(connection: connection, id: id, includeMedia: media) }
                case .discard: run { await sync.discardPending(connection: connection) }
                }
                self.confirmation = nil
            }
            .disabled(sync.isBusy || isCallActive)
        }
        Button("取消", role: .cancel) { confirmation = nil }
    }

    private func save(_ body: () throws -> Void) {
        do { try body() } catch { loadingError = error.localizedDescription }
    }

    private func run(_ body: @escaping @MainActor () async -> Void) {
        operation = Task {
            defer { operation = nil }
            await body()
        }
    }

}
