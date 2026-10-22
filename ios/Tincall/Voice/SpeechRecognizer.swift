// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

@MainActor
protocol SpeechRecognizer: AnyObject {
    var currentInputAudio: Data { get }
    var onSpeechActivityChange: ((Bool) -> Void)? { get set }
    func start(callback: @escaping (String, Bool, Data?) async -> Void,
               onError: @escaping (Error) async -> Void,
               onReset: @escaping () -> Void) async throws
    func setTranscriptionPaused(_ paused: Bool)
    /// End microphone input; return whether a transcription is still pending.
    func finishRecording() throws -> Bool
    func stop()
    func stopAndWait() async
}
