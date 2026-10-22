import SwiftUI
import UIKit

struct RootKeyboardDismissal: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.installGestureIfNeeded()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.removeGesture()
    }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        private weak var attachedWindow: UIWindow?
        private var gesture: UITapGestureRecognizer?

        override func loadView() {
            let view = UIView(frame: .zero)
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            self.view = view
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            installGestureIfNeeded()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            installGestureIfNeeded()
        }

        func installGestureIfNeeded() {
            guard let window = viewIfLoaded?.window else { return }
            guard attachedWindow !== window || gesture == nil else { return }
            removeGesture()

            let gesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            gesture.cancelsTouchesInView = false
            gesture.delaysTouchesBegan = false
            gesture.delaysTouchesEnded = false
            gesture.delegate = self
            window.addGestureRecognizer(gesture)
            attachedWindow = window
            self.gesture = gesture
        }

        func removeGesture() {
            if let gesture, let attachedWindow {
                attachedWindow.removeGestureRecognizer(gesture)
            }
            gesture = nil
            attachedWindow = nil
        }

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let window = attachedWindow,
                  let firstResponder = firstResponder(in: window),
                  firstResponder is UITextField || firstResponder is UITextView else { return }
            window.endEditing(true)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let window = attachedWindow,
                  let firstResponder = firstResponder(in: window) else { return false }
            return firstResponder is UITextField || firstResponder is UITextView
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UITextField || current is UITextView { return false }
                // Alert actions own both saving and dismissing their text-field keyboard.
                if current.next is UIAlertController { return false }
                // Opening an input accessory menu must not count as tapping the background.
                if let button = current as? UIButton, button.menu != nil { return false }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        private func firstResponder(in view: UIView) -> UIView? {
            if view.isFirstResponder { return view }
            for subview in view.subviews {
                if let responder = firstResponder(in: subview) { return responder }
            }
            return nil
        }
    }
}
