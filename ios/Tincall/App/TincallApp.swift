import Contacts
import SwiftUI
import UIKit

@main
struct TincallApp: App {
    @UIApplicationDelegateAdaptor(TincallAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("tincall.appearance") private var appearance = AppAppearance.system
    init() {
        UIView.appearance().tintColor = UIColor(named: "AccentColor")
        #if DEBUG
        _ = RequestLogExamples.shared
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-TincallCallPreview") {
                    TincallDebugCallPreview()
                } else if ProcessInfo.processInfo.arguments.contains("-TincallOpenConnectionHelp") {
                    NavigationStack { ConnectionHelpScreen() }
                } else if ProcessInfo.processInfo.arguments.contains("-TincallOpenAppearanceLanguage") {
                    NavigationStack { AppearanceLanguageSettings() }
                } else if ProcessInfo.processInfo.arguments.contains("-TincallOpenContactEditor") {
                    TincallDebugContactEditor()
                } else {
                    TincallRootView()
                }
                #else
                TincallRootView()
                #endif
            }
            .tint(.accentColor)
            .preferredColorScheme(appearance.colorScheme)
            .onChange(of: scenePhase, initial: true) { _, phase in
                TincallRuntime.shared.setAppActive(phase == .active)
            }
        }
    }
}
