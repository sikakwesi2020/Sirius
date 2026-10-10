import AVFoundation

final class AudioPipeline {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let inputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private let stateLock = NSLock()
    private var inputEnabled = true
    var onAudio: ((Data) -> Void)?

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredInputNumberOfChannels(1)
        try session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        input.isVoiceProcessingAGCEnabled = true
        let hardwareFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: hardwareFormat, to: inputFormat)
        input.installTap(onBus: 0, bufferSize: 2048, format: hardwareFormat) { [weak self] buffer, _ in
            guard let self, let converter = self.converter, self.shouldForwardInput else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * self.inputFormat.sampleRate / hardwareFormat.sampleRate) + 1
            guard let converted = AVAudioPCMBuffer(pcmFormat: self.inputFormat, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, converted.frameLength > 0, let pointer = converted.int16ChannelData?[0] else { return }
            self.onAudio?(Data(bytes: pointer, count: Int(converted.frameLength) * MemoryLayout<Int16>.size))
        }
        engine.prepare()
        try engine.start()
    }

    func play(_ data: Data) {
        let frames = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frames),
              let destination = buffer.int16ChannelData?[0] else { return }
        buffer.frameLength = frames
        _ = data.copyBytes(to: UnsafeMutableBufferPointer(start: destination, count: Int(frames)))
        // Keep the voice-processed microphone open during playback. Apple's voice
        // processing removes speaker echo; Gemini's VAD can then hear a real person
        // begin speaking and issue an immediate barge-in interruption.
        player.scheduleBuffer(buffer)
        if !player.isPlaying { player.play() }
    }

    func interruptPlayback() { player.stop() }

    func setInputEnabled(_ enabled: Bool) {
        stateLock.lock()
        inputEnabled = enabled
        stateLock.unlock()
    }

    func stop() {
        if engine.isRunning { engine.inputNode.removeTap(onBus: 0) }
        player.stop()
        engine.stop()
        converter = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private var shouldForwardInput: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return inputEnabled
    }
}
