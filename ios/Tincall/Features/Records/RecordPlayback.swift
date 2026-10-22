import AVFoundation
import Observation

/// Detail-local replay only. Live-call media remains owned by the voice service.
@MainActor @Observable
final class RecordPlayback: NSObject, AVAudioPlayerDelegate {
    struct Clip {
        let messageID: UUID
        let url: URL
        let duration: TimeInterval?
    }

    private struct PreparedClip {
        let messageID: UUID
        let url: URL
        let duration: TimeInterval
    }

    private(set) var isPlaying = false
    private(set) var currentMessageID: UUID?
    private(set) var progress = 0.0
    private(set) var durations: [UUID: TimeInterval] = [:]
    private(set) var errorMessage: String?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var clips: [PreparedClip] = []
    @ObservationIgnored private var queue: [PreparedClip] = []
    @ObservationIgnored private var clipIndex = 0
    @ObservationIgnored private var completedDuration: TimeInterval = 0
    @ObservationIgnored private var progressTimer: Timer?
    @ObservationIgnored private var ownsAudioSession = false
    private var selection: UUID?
    private(set) var hasPlayback = false

    var isPlayingAll: Bool { hasPlayback && selection == nil }

    func prepare(_ sources: [Clip]) async throws {
        stop()
        guard !ownsAudioSession else { throw TincallError(message: String(localized: "重听音频会话未能释放，请重试。")) }
        errorMessage = nil
        clips = []
        durations = [:]
        var prepared: [PreparedClip] = []
        var totals: [UUID: TimeInterval] = [:]
        for source in sources {
            try Task.checkCancellation()
            let duration: TimeInterval
            if let saved = source.duration, saved.isFinite, saved > 0 {
                duration = saved
            } else {
                duration = try await AVURLAsset(url: source.url).load(.duration).seconds
            }
            guard duration.isFinite, duration > 0 else { throw TincallError(message: String(localized: "保存的音频时长无效。")) }
            prepared.append(PreparedClip(messageID: source.messageID, url: source.url, duration: duration))
            totals[source.messageID, default: 0] += duration
        }
        try Task.checkCancellation()
        clips = prepared
        durations = totals
    }

    /// A second tap pauses; the next tap resumes the same sample and segment queue.
    func toggle(messageID: UUID? = nil) {
        if hasPlayback, selection == messageID || (messageID != nil && currentMessageID == messageID) {
            if isPlaying { pause() } else { resume() }
            return
        }
        stop()
        guard !ownsAudioSession else { return }
        errorMessage = nil
        queue = clips.filter { messageID == nil || $0.messageID == messageID }
        guard !queue.isEmpty else { errorMessage = String(localized: "此记录没有可播放的已保存音频"); return }
        selection = messageID
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            ownsAudioSession = true
            try playCurrentClip()
        } catch {
            stop()
            errorMessage = String(localized: "保存的音频无法播放，请检查文件是否完整。")
        }
    }

    func stop() {
        clearPlayback()
        currentMessageID = nil
        progress = 0
    }

    private func clearPlayback() {
        progressTimer?.invalidate()
        progressTimer = nil
        player?.stop()
        player?.delegate = nil
        player = nil
        queue = []
        clipIndex = 0
        completedDuration = 0
        selection = nil
        isPlaying = false
        hasPlayback = false
        if ownsAudioSession {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                ownsAudioSession = false
            } catch { errorMessage = String(localized: "重听已停止，音频会话释放失败。") }
        }
    }

    private func pause() {
        updateProgress()
        player?.pause()
        isPlaying = false
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func resume() {
        guard let player else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            guard player.play() else { throw TincallError(message: String(localized: "音频未能继续播放")) }
            isPlaying = true
            startProgressUpdates()
        } catch {
            stop()
            errorMessage = String(localized: "音频未能继续播放，请重试。")
        }
    }

    private func playCurrentClip(shouldPlay: Bool = true) throws {
        guard queue.indices.contains(clipIndex) else {
            stop()
            return
        }
        let clip = queue[clipIndex]
        if currentMessageID != clip.messageID {
            currentMessageID = clip.messageID
            completedDuration = 0
            progress = 0
        }
        let next = try AVAudioPlayer(contentsOf: clip.url)
        next.delegate = self
        player = next
        guard next.prepareToPlay() else { throw TincallError(message: String(localized: "音频播放准备失败")) }
        if shouldPlay {
            guard next.play() else { throw TincallError(message: String(localized: "音频播放启动失败")) }
            startProgressUpdates()
        } else {
            progressTimer?.invalidate()
            progressTimer = nil
        }
        isPlaying = shouldPlay
        hasPlayback = true
    }

    private func startProgressUpdates() {
        progressTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateProgress() }
        }
        progressTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateProgress() {
        guard let player, let currentMessageID, let total = durations[currentMessageID], total > 0 else { return }
        progress = min(1, max(0, (completedDuration + player.currentTime) / total))
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identifier = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let current = self.player, ObjectIdentifier(current) == identifier else { return }
            guard flag else { self.stop(); self.errorMessage = String(localized: "音频未能完整播放。"); return }
            self.completedDuration += self.queue[self.clipIndex].duration
            self.clipIndex += 1
            do { try self.playCurrentClip(shouldPlay: self.isPlaying) }
            catch { self.stop(); self.errorMessage = String(localized: "下一段音频无法播放。") }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        let identifier = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let current = self.player, ObjectIdentifier(current) == identifier else { return }
            self.stop()
            self.errorMessage = String(localized: "音频文件无法解码。")
        }
    }
}
