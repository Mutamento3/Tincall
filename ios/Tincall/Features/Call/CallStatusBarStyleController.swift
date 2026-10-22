import SwiftUI
import UIKit

struct CallStatusBarStyleController: UIViewControllerRepresentable {
    var clearsPresentationBackground = false
    @Environment(\.colorScheme) private var colorScheme

    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ viewController: Controller, context: Context) {
        viewController.clearsPresentationBackground = clearsPresentationBackground
        viewController.statusBarStyle = colorScheme == .light ? .darkContent : .lightContent
        viewController.setNeedsStatusBarAppearanceUpdate()
        viewController.parent?.setNeedsStatusBarAppearanceUpdate()
    }

    final class Controller: UIViewController {
        var clearsPresentationBackground = false
        var statusBarStyle: UIStatusBarStyle = .lightContent
        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }

        override var preferredStatusBarStyle: UIStatusBarStyle { statusBarStyle }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            clearPresentationBackground()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            clearPresentationBackground()
        }

        private func clearPresentationBackground() {
            guard clearsPresentationBackground else { return }
            var controller: UIViewController = self
            while let parent = controller.parent { controller = parent }
            guard let container = controller.presentationController?.containerView else { return }
            // Clear only the sheet's surface wrappers, stopping at its presentation container.
            var surface: UIView? = controller.view
            while let current = surface, current !== container {
                current.backgroundColor = .clear
                current.isOpaque = false
                surface = current.superview
            }
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            parent?.setNeedsStatusBarAppearanceUpdate()
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            parent?.setNeedsStatusBarAppearanceUpdate()
        }
    }
}
