import SwiftUI

struct IncomingCallSettings: View {
    let configuration: LocalConfigurationStore
    let controller: IncomingCallController
    let isCallActive: Bool
    @State private var scheduleEditor: ScheduleEditorSelection?
    @State private var scheduleRefreshID = UUID()
    @State private var isWorking = false
    @State private var showsEnableNotice = false
    @State private var unavailableMessage: String?
    @State private var errorMessage: String?

    private var connections: [ConnectionProfile] {
        configuration.connections.filter { $0.provider == .genericConnector }
    }

    var body: some View {
        SettingsList {
            Section {
                Group {
                    Toggle("允许后台来电", isOn: Binding(
                        get: { controller.isEnabled },
                        set: { enabled in
                            if enabled { requestEnable() }
                            else { changeEnabled(false) }
                        }
                    ))
                    VStack(alignment: .leading, spacing: 8) {
                        if isWorking {
                            ProgressView("正在更新设备绑定…")
                        } else {
                            Text(stateTitle)
                        }
                        if !controller.isEnabled {
                            Text(connections.isEmpty
                                 ? String(localized: "先到「设置 → Tincall 云端」部署或连接服务，再开启后台来电。")
                                 : String(localized: "开启并完成绑定后，可接听后台来电和设置定时计划。"))
                        }
                        Text("不开启也能在 App 前台接听已配置联系人的来电；后台或锁屏接听需要开启并完成推送绑定。")
                        if let message = errorMessage ?? controller.errorMessage ?? controller.foregroundErrorMessage {
                            Text(message).foregroundStyle(.red)
                        }
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)
                    if controller.isEnabled && controller.registrationStates.values.contains(.failed) {
                        Button { changeEnabled(true) } label: {
                            SettingsActionLabel(title: String(localized: "重试绑定"), symbol: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                    }
                    if connections.count > 1 {
                        ForEach(connections) { connection in
                            HStack(spacing: 16) {
                                Text(connection.name)
                                Spacer()
                                Text(bindingTitle(connection.id)).foregroundStyle(.secondary)
                            }
                            .frame(minHeight: 44)
                            if let message = controller.registrationErrors[connection.id] {
                                Text(message).font(.footnote).foregroundStyle(.red)
                            }
                        }
                    } else if let id = connections.first?.id, let message = controller.registrationErrors[id] {
                        Text(message).font(.footnote).foregroundStyle(.red)
                    }
                    if controller.needsDeviceRemoval {
                        Button { changeEnabled(false) } label: {
                            SettingsActionLabel(title: String(localized: "重试解除设备绑定"), symbol: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowSeparator(.hidden)
            } header: {
                SettingsSectionHeading(number: controller.isEnabled ? "01" : nil, title: String(localized: "接听设置"), caption: "INCOMING")
            }
            .disabled(isWorking || isCallActive)
            if controller.isEnabled {
                ScheduledCallSettings(configuration: configuration, incoming: controller, isCallActive: isCallActive,
                                      refreshID: scheduleRefreshID, onEdit: { scheduleEditor = $0 })
            }
        }
        .modifier(SettingsPageStyle(title: String(localized: "后台来电"), subtitle: String(localized: "在后台或锁屏时接听，设置来电时间"), symbol: "phone.badge.waveform", index: "INCOMING CALLS",
                                   dismissDisabled: isWorking))
        .sheet(item: $scheduleEditor) { selection in
            NavigationStack {
                ScheduledCallEditor(configuration: configuration, incoming: controller, isCallActive: isCallActive,
                                    selection: selection) { scheduleRefreshID = UUID() }
            }
            .environment(\.navigationDockClearance, 0)
            .presentationDetents([.height(500), .large])
            .presentationDragIndicator(.visible)
        }
        .alert("绑定后台来电", isPresented: $showsEnableNotice) {
            Button("启用") { changeEnabled(true) }
            Button("取消", role: .cancel) { }
        } message: {
            Text("设备推送标识会分别绑定到已配置的云端及其推送服务，用于向这台 iPhone 发起来电；来电不带聊天正文或录音。请确认这些都是你信任的服务。")
        }
        .alert("无法启用后台来电", isPresented: Binding(
            get: { unavailableMessage != nil },
            set: { if !$0 { unavailableMessage = nil } }
        )) {
            Button("好", role: .cancel) { unavailableMessage = nil }
        } message: {
            Text(unavailableMessage ?? "")
        }
    }

    private var stateTitle: String {
        if controller.needsDeviceRemoval { return String(localized: "远端解绑待确认") }
        switch controller.state {
        case .disabled: return String(localized: "未启用")
        case .registering: return String(localized: "正在绑定")
        case .registered: return String(localized: "已绑定")
        case .failed: return String(localized: "绑定需要处理")
        }
    }

    private func bindingTitle(_ id: UUID) -> String {
        guard controller.isEnabled else { return String(localized: "未启用") }
        switch controller.registrationStates[id] {
        case .registered: return String(localized: "已绑定")
        case .failed: return String(localized: "绑定需要处理")
        default: return String(localized: "正在绑定")
        }
    }

    private func requestEnable() {
        guard !isWorking, !isCallActive else { return }
        guard !connections.isEmpty else {
            unavailableMessage = String(localized: "先到「设置 → Tincall 云端」部署或连接服务")
            return
        }
        guard IncomingCallController.signedPushEnvironment() != nil else {
            unavailableMessage = String(localized: "当前安装包未包含推送权限，暂时只能在 App 打开时接听。后台来电还需要支持推送的签名和云端推送服务。")
            return
        }
        showsEnableNotice = true
    }

    private func changeEnabled(_ enabled: Bool) {
        guard !isWorking, !isCallActive else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                if enabled {
                    guard let environment = IncomingCallController.signedPushEnvironment() else {
                        throw TincallError(message: String(localized: "当前安装方式不支持后台来电"))
                    }
                    try await controller.enable(connections: connections, environment: environment)
                } else { try await controller.disable() }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
