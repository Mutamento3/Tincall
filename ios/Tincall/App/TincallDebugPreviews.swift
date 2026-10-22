import Contacts
import SwiftUI
import UIKit

#if DEBUG
struct TincallDebugContactEditor: View {
    @State private var configuration: LocalConfigurationStore?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            if let configuration, let role = configuration.roles.first {
                RoleEditor(role: role, store: configuration)
            } else if let errorMessage {
                Text(errorMessage)
            } else {
                ProgressView()
            }
        }
        .task {
            guard configuration == nil else { return }
            do {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TincallEditorPreview-\(UUID().uuidString)")
                let store = try LocalConfigurationStore(directory: directory)
                try store.saveRole(CallRole(name: "TA"))
                configuration = store
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

struct TincallDebugCallPreview: View {
    @State private var callActivity = CallActivityController()
    private let backgroundData: Data?

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let color: UIColor?
        if arguments.contains("-TincallPreviewLightBackground") { color = .white }
        else if arguments.contains("-TincallPreviewDarkBackground") { color = .black }
        else { color = nil }
        backgroundData = color.map { color in
            UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).pngData { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            }
        }
    }

    var body: some View {
        NavigationStack {
            CallPreviewScreen(callActivity: callActivity, contactID: nil, name: "TA",
                              avatarData: nil, backgroundData: backgroundData)
        }
    }
}
#endif
