// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI
import UIKit
import Observation

/// Keep the dock mounted and let SwiftUI animate its visibility during navigation.
@MainActor
@Observable
final class NavigationDockPresentation {
    weak var tabBarController: UITabBarController?
    /// The dock's hosting view stays mounted; it must stop taking touches while the dock is away.
    @ObservationIgnored weak var hostView: UIView?
    var isDockShown = true
    var dockAnimation: Animation? = .easeInOut(duration: 0.3)

    func setVisible(_ visible: Bool, alongside coordinator: UIViewControllerTransitionCoordinator? = nil,
                    reduceMotion: Bool = false) {
        guard visible != isDockShown else { return }
        let previousVisibility = isDockShown
        dockAnimation = reduceMotion ? nil : .easeInOut(duration: coordinator?.transitionDuration ?? 0.3)
        isDockShown = visible
        hostView?.isUserInteractionEnabled = visible
        guard let coordinator else { return }
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            guard context.isCancelled, let self else { return }
            self.isDockShown = previousVisibility
            self.hostView?.isUserInteractionEnabled = previousVisibility
        }
    }

    func selectTab(at index: Int, reduceMotion: Bool, selection: @escaping () -> Void) {
        guard !reduceMotion, let tabBarController else {
            selection()
            return
        }
        // Change the native tab synchronously inside the crossfade; its view excludes the dock.
        UIView.transition(with: tabBarController.view, duration: 0.2,
                          options: [.transitionCrossDissolve, .beginFromCurrentState]) {
            tabBarController.selectedIndex = index
            selection()
        }
    }
}

struct DockSlideContainer<Content: View>: View {
    let presentation: NavigationDockPresentation
    @ViewBuilder var content: Content

    var body: some View {
        content
            .offset(y: presentation.isDockShown ? 0 : 120)
            .allowsHitTesting(presentation.isDockShown)
            .accessibilityHidden(!presentation.isDockShown)
            .animation(presentation.dockAnimation, value: presentation.isDockShown)
    }
}

struct NavigationDockHost<Content: View>: UIViewControllerRepresentable {
    let presentation: NavigationDockPresentation
    @ViewBuilder var content: Content

    func makeUIViewController(context: Context) -> UIHostingController<Content> {
        let controller = UIHostingController(rootView: content)
        controller.safeAreaRegions = []
        controller.view.backgroundColor = .clear
        presentation.hostView = controller.view
        controller.view.isUserInteractionEnabled = presentation.isDockShown
        return controller
    }

    func updateUIViewController(_ controller: UIHostingController<Content>, context: Context) {
        controller.rootView = content
    }
}

/// The representable only locates the root; observe appearance as a direct child of that root.
struct NavigationDockObserver: UIViewControllerRepresentable {
    let presentation: NavigationDockPresentation
    let isSelected: Bool
    let reduceMotion: Bool

    func makeUIViewController(context: Context) -> Controller {
        Controller(presentation: presentation, isSelected: isSelected, reduceMotion: reduceMotion)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        let observer = controller.rootObserver
        let becameSelected = isSelected && !observer.isSelected
        observer.isSelected = isSelected
        observer.reduceMotion = reduceMotion
        controller.installRootObserver()
        if becameSelected { observer.synchronizeVisibility() }
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.removeRootObserver()
    }

    final class Controller: UIViewController {
        let rootObserver: RootAppearanceObserver

        init(presentation: NavigationDockPresentation, isSelected: Bool, reduceMotion: Bool) {
            rootObserver = RootAppearanceObserver(presentation: presentation, isSelected: isSelected,
                                                  reduceMotion: reduceMotion)
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            installRootObserver()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            installRootObserver()
        }

        func installRootObserver() {
            var ancestor = parent
            while let root = ancestor {
                if let navigation = root.parent as? UINavigationController,
                   navigation.viewControllers.first === root {
                    guard rootObserver.parent !== root else { return }
                    removeRootObserver()
                    // UIKit forwards the root's appearance before navigation animates. Keeping this
                    // outside SwiftUI's nested representable avoids its deferred disappearance.
                    root.addChild(rootObserver)
                    root.view.insertSubview(rootObserver.view, at: 0)
                    rootObserver.didMove(toParent: root)
                    rootObserver.synchronizeVisibility()
                    return
                }
                ancestor = root.parent
            }
        }

        func removeRootObserver() {
            guard rootObserver.parent != nil else { return }
            rootObserver.willMove(toParent: nil)
            rootObserver.view.removeFromSuperview()
            rootObserver.removeFromParent()
        }
    }

    final class RootAppearanceObserver: UIViewController {
        let presentation: NavigationDockPresentation
        var isSelected: Bool
        var reduceMotion: Bool

        init(presentation: NavigationDockPresentation, isSelected: Bool, reduceMotion: Bool) {
            self.presentation = presentation
            self.isSelected = isSelected
            self.reduceMotion = reduceMotion
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func loadView() {
            view = UIView(frame: .zero)
            view.isUserInteractionEnabled = false
            view.accessibilityElementsHidden = true
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            synchronizeVisibility()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            synchronizeVisibility()
        }

        func synchronizeVisibility() {
            guard isSelected, let root = parent,
                  let navigation = root.parent as? UINavigationController,
                  navigation.viewControllers.first === root else { return }
            presentation.tabBarController = navigation.tabBarController
            if let coordinator = root.transitionCoordinator,
               let source = coordinator.viewController(forKey: .from),
               let destination = coordinator.viewController(forKey: .to),
               destination === root || (source === root && navigation.viewControllers.contains(destination)) {
                presentation.setVisible(destination === root, alongside: coordinator, reduceMotion: reduceMotion)
            } else {
                // Tab changes, sheets and unanimated navigation use the actual stack position.
                presentation.setVisible(navigation.topViewController === root)
            }
        }
    }
}

private struct NavigationDockClearanceKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var navigationDockClearance: CGFloat {
        get { self[NavigationDockClearanceKey.self] }
        set { self[NavigationDockClearanceKey.self] = newValue }
    }
}
