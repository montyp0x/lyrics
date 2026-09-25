import AVFoundation

/// Plays silence, mixed with other audio, so iOS keeps the app running in the background
/// and the Live Activity can follow the song line by line. Fine for private builds; App Review would reject it.
final class BackgroundKeeper {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var silence: AVAudioPCMBuffer?
    private var interruptionObserver: NSObjectProtocol?
    private(set) var isRunning = false

    init() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, self.isRunning,
                  let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self.isRunning = false
            self.start()
        }
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    func start() {
        guard !isRunning else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)

            let buffer = try silenceBuffer()
            if !engine.isRunning {
                try engine.start()
            }
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            isRunning = true
        } catch {
            print("BackgroundKeeper failed to start: \(error)")
        }
    }

    func stop() {
        guard isRunning else { return }
        player.stop()
        engine.stop()
        isRunning = false
    }

    private func silenceBuffer() throws -> AVAudioPCMBuffer {
        if let silence { return silence }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else {
            throw NSError(domain: "BackgroundKeeper", code: 1)
        }
        buffer.frameLength = buffer.frameCapacity
        if let samples = buffer.floatChannelData?[0] {
            samples.update(repeating: 0, count: Int(buffer.frameLength))
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        silence = buffer
        return buffer
    }
}
