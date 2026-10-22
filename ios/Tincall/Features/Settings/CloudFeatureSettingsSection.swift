// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI

struct CloudFeatureSettingsSection: View {
    let configuration: LocalConfigurationStore
    let records: CallRecordStore?
    let sync: CloudSyncStore?
    let syncLoadingError: String?
    let incomingController: IncomingCallController?
    let isCallActive: Bool

    var body: some View {
        Section {
            syncLink
            incomingLink
        } header: {
            SettingsSectionHeading(title: String(localized: "同步与来电"), caption: "SYNC & CALLS")
        } footer: {
            Text("连接云端后，可按需分别开启同步和来电。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    var syncLink: some View {
        NavigationLink {
            if let records, let sync {
                CloudBackupScreen(configuration: configuration, records: records, sync: sync, isCallActive: isCallActive)
            } else {
                SettingsList {
                    Section {
                        if let syncLoadingError {
                            Text("同步设置暂时无法读取：\(syncLoadingError)")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else if records == nil {
                            Text("本地记录尚未就绪，请返回后重试。")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            ProgressView("正在读取同步设置…")
                        }
                    }
                }
                .modifier(SettingsPageStyle(title: String(localized: "云端同步"), subtitle: "", symbol: "icloud", index: "BACKUP"))
            }
        } label: {
            SettingsActionLabel(title: String(localized: "云端同步"), symbol: "icloud.and.arrow.up",
                                detail: String(localized: "自动同步通话文字、图片与摘要，录音单独选择"))
        }
    }

    var incomingLink: some View {
        NavigationLink {
            if let incomingController {
                IncomingCallSettings(configuration: configuration, controller: incomingController, isCallActive: isCallActive)
            } else {
                SettingsList {
                    Section {
                        Text("来电设置暂时不可用，请返回后重试。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .modifier(SettingsPageStyle(title: String(localized: "后台与定时来电"), subtitle: "", symbol: "phone.badge.waveform", index: "INCOMING CALLS"))
            }
        } label: {
            SettingsActionLabel(title: String(localized: "后台与定时来电"), symbol: "phone.badge.waveform",
                                detail: String(localized: "后台或锁屏时接听来电，设置定时来电"))
        }
    }
}
