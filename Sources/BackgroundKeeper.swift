import AVFoundation

/// Keeps the app running in the background by playing silence through the "audio" background mode.
/// It mixes with other audio, so music and videos keep playing normally.
final class BackgroundKeeper {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private lazy var silence: AVAudioPCMBuffer = {
        let frames = AVAudioFrameCount(self.format.sampleRate) // one second, looped
        let buffer = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: frames)!
        buffer.frameLength = frames
        buffer.floatChannelData?[0].initialize(repeating: 0, count: Int(frames))
        return buffer
    }()
    private var observers: [NSObjectProtocol] = []
    private var isRunning = false

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            // Resume after a phone call or Siri.
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self?.resume()
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.resume()
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.resume()
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
        try engine.start()
        player.stop()
        player.scheduleBuffer(silence, at: nil, options: .loops)
        player.play()
        isRunning = true
    }

    func stop() {
        isRunning = false
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func resume() {
        guard isRunning else { return }
        try? start()
    }
}
