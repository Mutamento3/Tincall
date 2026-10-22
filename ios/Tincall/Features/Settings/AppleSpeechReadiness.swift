// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Speech
import SwiftUI

/// Reports actual system availability without starting capture or requesting a download.
struct AppleSpeechReadiness: View {
    let language: String
    @State private var status = String(localized: "正在检查本机识别…")

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(status, systemImage: "iphone")
                .font(.subheadline)
            Text("无需 API Key。开始通话并开麦时，系统会检查麦克风权限，按需下载所选语言资源，再在本机转写。选中服务不代表麦克风正在收音。")
                .font(.footnote).foregroundStyle(.secondary).lineSpacing(3)
        }
        .padding(.vertical, 8)
        .task(id: language) {
            guard SpeechTranscriber.isAvailable else {
                status = String(localized: "当前设备不支持 Apple 本机识别")
                return
            }
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
                status = String(localized: "此语言不受支持，请检查语言代码")
                return
            }
            let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            let availability = await AssetInventory.status(forModules: [module])
            guard !Task.isCancelled else { return }
            status = availability == .installed ? String(localized: "语言资源已就绪，通话时可用") : String(localized: "首次使用需要下载系统语言资源")
        }
    }
}
