// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI

@ViewBuilder
func callDuration(_ record: CallRecord) -> some View {
    if record.endedAbnormally != true, let endedAt = record.endedAt {
        let seconds = Int(max(0, endedAt.timeIntervalSince(record.startedAt)))
        if seconds < 60 {
            Text("时长 \(seconds) 秒")
        } else {
            Text("时长 \(seconds / 60) 分 \(seconds % 60) 秒")
        }
    } else if record.endedAbnormally != true {
        Text("通话尚未结束")
    }
}
