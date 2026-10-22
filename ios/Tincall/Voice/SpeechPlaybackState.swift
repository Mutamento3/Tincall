import Foundation

/// Per-segment receive/playback state. A failed segment is terminal even when
/// its HTTP stream ended after playback had already started.
final class SpeechPlaybackSegment {
    let queuedAt = ProcessInfo.processInfo.systemUptime
    let value: SpeechSegment
    let previousText: String
    let sourceStart: Int
    var pcm = Data()
    var received = false
    var failed = false
    var scheduled = 0
    var scheduledFrames = 0
    var scheduledPCM = Data()
    private(set) var drainDeadline: TimeInterval?
    var started = false
    var firstAudio = false
    var archivePCM = Data()
    var receivedBytes = 0
    var playedBytes = 0

    init(_ value: SpeechSegment, previousText: String, sourceStart: Int = 0) {
        self.value = value
        self.previousText = previousText
        self.sourceStart = sourceStart
    }

    var canStart: Bool { !failed && (pcm.count >= 5760 || (received && !pcm.isEmpty)) }
    var isDrained: Bool { received && pcm.isEmpty && scheduled == 0 }

    /// A prefetched segment can be downloaded again only before any playback.
    /// Discard the failed attempt rather than appending the repeated prefix.
    func resetUnplayedReception() -> Bool {
        guard !started, !failed, !received, playedBytes == 0,
              scheduled == 0, scheduledFrames == 0, scheduledPCM.isEmpty else { return false }
        pcm.removeAll()
        archivePCM.removeAll()
        receivedBytes = 0
        firstAudio = false
        cancelDrain()
        return true
    }

    func armDrain(now: TimeInterval) {
        guard received, !failed, !isDrained, drainDeadline == nil else { return }
        drainDeadline = now + Double(scheduledFrames + pcm.count / 2) / 24_000 + 3
    }

    func cancelDrain() { drainDeadline = nil }

    func drainExpired(now: TimeInterval) -> Bool {
        guard let drainDeadline, received, !failed, !isDrained else { return false }
        return now >= drainDeadline
    }

    func restoreScheduledAudio() {
        pcm = scheduledPCM + pcm
        scheduledPCM.removeAll()
        scheduled = 0
        scheduledFrames = 0
        cancelDrain()
    }

    func fail() {
        failed = true
        received = true
        pcm.removeAll()
        scheduledPCM.removeAll()
        cancelDrain()
    }
}
