import SwiftUI

struct ConnectionDataSharingSection: View {
    let connection: ConnectionProfile
    @State private var allowed = false

    var body: some View {
        if connection.provider != .appleSpeech {
            Section {
                LabeledContent("接收方") {
                    Text(verbatim: DataSharingConsent.recipient(connection)).textSelection(.enabled)
                }
                Text(DataSharingConsent.disclosure(connection))
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("允许向此服务发送上述数据", isOn: Binding(get: { allowed }, set: {
                    DataSharingConsent.setAllowed($0, for: connection)
                    allowed = DataSharingConsent.isAllowed(connection)
                }))
                .disabled(!DataSharingConsent.canAuthorize(connection))
                if connection.provider == .genericConnector {
                    Text("关闭授权后，仍可向原服务发送设备解绑请求，以停用后台来电。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Link("隐私政策", destination: DataSharingConsent.privacyURL)
            } header: { SettingsSectionHeading(title: String(localized: "数据发送授权"), caption: "PRIVACY") }
            .onAppear { allowed = DataSharingConsent.isAllowed(connection) }
            .onChange(of: DataSharingConsent.destination(connection)) { _, _ in
                allowed = DataSharingConsent.isAllowed(connection)
            }
        }
    }
}
