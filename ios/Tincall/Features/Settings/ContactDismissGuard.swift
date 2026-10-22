// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI
import UIKit

struct ContactDismissGuard: UIViewControllerRepresentable {
    let isBlocked: Bool
    let hasUnsavedChanges: Bool
    let onAttempt: () -> Void

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.isBlocked = isBlocked
        controller.hasUnsavedChanges = hasUnsavedChanges
        controller.onAttempt = onAttempt
    }

    final class Controller: UIViewController, UIAdaptivePresentationControllerDelegate {
        var isBlocked = false
        var hasUnsavedChanges = false
        var onAttempt: (() -> Void)?
        private weak var guardedPresentation: UIPresentationController?
        private weak var previousDelegate: (any UIAdaptivePresentationControllerDelegate)?

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            var host: UIViewController = self
            while let parent = host.parent { host = parent }
            guard let presentation = host.presentationController else { return }
            guardedPresentation = presentation
            previousDelegate = presentation.delegate
            presentation.delegate = self
        }

        override func viewWillDisappear(_ animated: Bool) {
            if guardedPresentation?.delegate === self { guardedPresentation?.delegate = previousDelegate }
            guardedPresentation = nil
            previousDelegate = nil
            super.viewWillDisappear(animated)
        }

        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
            guard !isBlocked, !hasUnsavedChanges else { return false }
            return previousDelegate?.presentationControllerShouldDismiss?(presentationController) ?? true
        }

        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            if !isBlocked, hasUnsavedChanges { onAttempt?() }
        }

        func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
            previousDelegate?.presentationControllerWillDismiss?(presentationController)
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            previousDelegate?.presentationControllerDidDismiss?(presentationController)
        }
    }
}
