// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI

struct CallAccessScreen: View {
    var isModal = false
    @State private var access = CallAccessStore.shared

    var body: some View {
        SettingsList {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(statusTitle).font(.title3.weight(.semibold))
                    Text(statusDetail).font(.subheadline).foregroundStyle(.secondary)
                    if case .trial(let end) = access.state {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text("剩余 \(Duration.seconds(max(0, end.timeIntervalSince(context.date))).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2)))")
                                .font(.subheadline.weight(.medium))
                        }
                        Text(end, format: .dateTime.year().month().day().hour().minute())
                            .font(.subheadline.monospacedDigit())
                    }
                }
                .padding(.vertical, 4)
            } header: { SettingsSectionHeading(number: "01", title: String(localized: "当前状态")) }

            if CallAccessStore.isStoreBuild && access.state != .purchased {
                Section {
                    if access.state == .notStarted {
                        Button {
                            if let product = access.trialProduct { Task { await access.purchase(product) } }
                        } label: {
                            SettingsActionLabel(title: String(localized: "开始 7 天免费试用"), symbol: "clock",
                                                detail: String(localized: "确认领取后开始计时，到期不会自动扣款"))
                        }
                        .disabled(access.isPurchasing || access.trialProduct == nil || access.unlockProduct == nil)
                    }
                    Button {
                        if let product = access.unlockProduct { Task { await access.purchase(product) } }
                    } label: {
                        SettingsActionLabel(title: String(localized: "永久解锁"), symbol: "checkmark.seal",
                                            detail: access.unlockProduct?.displayPrice ?? String(localized: "一次性购买"))
                    }
                    .disabled(access.isPurchasing || access.unlockProduct == nil || access.state == .checking)
                    if access.isPurchasing { ProgressView("等待 App Store 确认…") }
                    if let error = access.productError {
                        Text(error).font(.subheadline).foregroundStyle(.secondary)
                        Button("重新加载") { Task { await access.loadProducts(); await access.refresh() } }
                            .disabled(access.isLoadingProducts || access.isPurchasing)
                    }
                } header: { SettingsSectionHeading(number: "02", title: String(localized: "试用与购买")) } footer: {
                    Text("试用包含 7 天核心通话功能。未开始试用或试用结束后，需要买断才能拨打和接听通话。已有记录仍可查看、播放和导出；设置与帮助始终可用。")
                }
            }

            if CallAccessStore.isStoreBuild {
                Section {
                    Button { Task { await access.restore() } } label: {
                        SettingsActionLabel(title: String(localized: "恢复购买"), symbol: "arrow.clockwise",
                                            detail: String(localized: "重装或换机后，恢复当前 Apple 账户的购买"))
                    }
                    .disabled(access.isPurchasing)
                    if let message = access.message { Text(message).font(.subheadline).foregroundStyle(.secondary) }
                } header: { SettingsSectionHeading(title: String(localized: "购买记录")) }
            }

            Section {
                Text("一次购买，永久解锁核心通话功能，无订阅。模型、语音和个人云端服务需使用自己的账号和配置，相关费用由对应服务商另行收取。")
                Text("作者负责 Tincall 的持续开发、系统适配，以及后台来电推送服务的运行和维护。App Store 版本的买断收入用于支持这些工作。项目同时提供源码，可按项目许可自行构建使用。")
            } header: { SettingsSectionHeading(title: String(localized: "购买说明")) }
                .font(.subheadline)
        }
        .modifier(SettingsPageStyle(title: String(localized: "试用与解锁"),
                                    subtitle: String(localized: "免费体验 7 天，喜欢再一次买断"),
                                    symbol: "checkmark.seal", index: "TINCALL ACCESS", isModal: isModal))
        .task { access.start(); await access.refresh(); await access.loadProducts() }
    }

    private var statusTitle: String {
        switch access.state {
        case .sourceBuild: String(localized: "自行构建版")
        case .checking: String(localized: "正在确认购买状态")
        case .notStarted: String(localized: "尚未开始试用")
        case .trial: String(localized: "免费试用中")
        case .expired: String(localized: "免费试用已结束")
        case .purchased: String(localized: "已永久解锁")
        case .unavailable: String(localized: "暂时无法确认购买状态")
        }
    }

    private var statusDetail: String {
        switch access.state {
        case .sourceBuild: String(localized: "核心功能已可用，请遵守项目源码许可")
        case .checking: String(localized: "正在读取 Apple 账户的购买记录")
        case .notStarted: String(localized: "可以先完成模型与语音配置，再领取免费试用")
        case .trial: String(localized: "通话功能已可用，试用截止时间为")
        case .expired: String(localized: "已有记录与设置保留，买断后可继续拨打和接听通话")
        case .purchased: String(localized: "核心通话功能已解锁，无需续费")
        case .unavailable: String(localized: "请使用恢复购买重新确认，已有记录不会受影响")
        }
    }
}
