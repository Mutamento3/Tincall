import Foundation
#if os(iOS)
import AVFoundation
#endif

@main
struct SpeechPlaybackChecks {
    static func main() {
#if os(iOS)
        precondition(MicrophoneCapture.needsEchoCancellation(outputPorts: [.builtInSpeaker]))
        precondition(MicrophoneCapture.needsEchoCancellation(outputPorts: [.builtInReceiver]))
        for port: AVAudioSession.Port in [.bluetoothA2DP, .bluetoothLE, .headphones, .airPlay, .usbAudio] {
            precondition(!MicrophoneCapture.needsEchoCancellation(outputPorts: [port]), "external output must retain media I/O")
        }
        precondition(!MicrophoneCapture.needsEchoCancellation(outputPorts: []))
        precondition(!MicrophoneCapture.needsEchoCancellation(outputPorts: [.builtInSpeaker, .bluetoothA2DP]))
#endif
        let value = SpeechSegment(text: "检查。", caption: "检查。", sourceEnd: 3, bodyCount: 3)
        let first = SpeechPlaybackSegment(value, previousText: "")
        let second = SpeechPlaybackSegment(value, previousText: value.text)
        let prefetched = SpeechPlaybackSegment(value, previousText: value.text)
        prefetched.firstAudio = true
        prefetched.pcm = Data(repeating: 1, count: 8192)
        prefetched.archivePCM = prefetched.pcm
        prefetched.receivedBytes = prefetched.pcm.count
        precondition(prefetched.resetUnplayedReception(), "a lost connection during unplayed prefetch may retry")
        precondition(prefetched.pcm.isEmpty && prefetched.archivePCM.isEmpty && prefetched.receivedBytes == 0 && !prefetched.firstAudio,
                     "retry discards the partial attempt so a new response cannot duplicate its prefix")
        prefetched.pcm = Data(repeating: 2, count: 6000)
        prefetched.firstAudio = true
        prefetched.receivedBytes = 6000
        precondition(prefetched.canStart && prefetched.pcm.allSatisfy { $0 == 2 }, "only the replacement response becomes playable")
        for phase in 0..<5 {
            let unsafe = SpeechPlaybackSegment(value, previousText: "")
            unsafe.pcm = Data([1, 2])
            if phase == 0 { unsafe.started = true }
            if phase == 1 { unsafe.scheduled = 1; unsafe.scheduledFrames = 1; unsafe.scheduledPCM = unsafe.pcm }
            if phase == 2 { unsafe.playedBytes = 2 }
            if phase == 3 { unsafe.received = true }
            if phase == 4 { unsafe.fail() }
            let originalPCM = unsafe.pcm
            precondition(!unsafe.resetUnplayedReception() && unsafe.pcm == originalPCM,
                         "started, scheduled, played, completed or failed segments must never restart")
        }
        second.pcm = Data(repeating: 0, count: 6000)
        second.received = true
        first.fail()
        precondition(first.failed && first.received && !first.canStart && second.canStart)

        let playing = SpeechPlaybackSegment(value, previousText: "")
        playing.started = true
        playing.scheduled = 2
        playing.pcm = Data(repeating: 0, count: 2000)
        playing.archivePCM = Data(repeating: 0, count: 2000)
        playing.fail()
        precondition(playing.failed && playing.pcm.isEmpty && playing.archivePCM.count == 2000)
        precondition(!playing.canStart && second.canStart, "failed audio cannot restart; following segment survives")
        let tail = SpeechPlaybackSegment(value, previousText: "")
        tail.scheduled = 1
        tail.scheduledFrames = 2400
        tail.armDrain(now: 10)
        precondition(tail.drainDeadline == nil, "network still receiving is not EOF")
        tail.received = true
        tail.pcm = Data(repeating: 0, count: 4800)
        tail.armDrain(now: 10)
        precondition(tail.drainDeadline == 13.2, "budget includes queued and unscheduled tail plus 3 seconds")
        precondition(!tail.drainExpired(now: 13.19) && tail.drainExpired(now: 13.21))
        tail.cancelDrain()
        precondition(!tail.drainExpired(now: 100), "system pause cancels the budget")
        tail.armDrain(now: 100)
        precondition(!tail.drainExpired(now: 103.19))
        tail.scheduled = 0
        tail.scheduledFrames = 0
        tail.pcm.removeAll()
        precondition(tail.isDrained && !tail.drainExpired(now: 200), "normal callback drains successfully")
        let cancelled = SpeechPlaybackSegment(value, previousText: "")
        cancelled.received = true
        cancelled.scheduled = 1
        cancelled.scheduledFrames = 2400
        cancelled.armDrain(now: 0)
        cancelled.fail()
        precondition(!cancelled.drainExpired(now: 100) && !cancelled.canStart)
        let reconfigured = SpeechPlaybackSegment(value, previousText: "")
        reconfigured.received = true
        reconfigured.pcm = Data([5, 6, 7, 8])
        reconfigured.scheduledPCM = Data([1, 2, 3, 4])
        reconfigured.scheduled = 1
        reconfigured.scheduledFrames = 2
        reconfigured.armDrain(now: 0)
        reconfigured.restoreScheduledAudio()
        precondition(reconfigured.pcm == Data([1, 2, 3, 4, 5, 6, 7, 8]))
        precondition(reconfigured.scheduled == 0 && reconfigured.scheduledFrames == 0 && reconfigured.scheduledPCM.isEmpty)
        precondition(reconfigured.drainDeadline == nil && !reconfigured.isDrained, "route graph change restores unacknowledged samples and invalidates old EOF deadline")
        reconfigured.restoreScheduledAudio()
        precondition(reconfigured.pcm == Data([1, 2, 3, 4, 5, 6, 7, 8]), "repeated graph change does not duplicate restored samples")
        reconfigured.scheduledPCM = Data([9, 10])
        reconfigured.fail()
        precondition(reconfigured.pcm.isEmpty && reconfigured.scheduledPCM.isEmpty, "terminal failure discards stale output buffers")
        print("PASS: segment failure before/after playback, next segment readiness, received audio retained, EOF tail budget, stalled callbacks, pause/rearm, terminal callback isolation")
    }
}
