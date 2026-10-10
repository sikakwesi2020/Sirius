import AVFoundation

@MainActor
final class QuizFeedbackPlayer {
    enum Cue: String, CaseIterable { case success, error, progress }
    static let shared = QuizFeedbackPlayer()

    private var player: AVAudioPlayer?
    private var remaining: [Cue: [Int]] = [:]
    private var lastPlayed: [Cue: Int] = [:]

    private init() {}

    func play(_ cue: Cue) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        let index = nextIndex(for: cue)
        let resource = "\(cue.rawValue)_\(String(format: "%02d", index))"
        let url = Bundle.main.url(forResource: resource, withExtension: "mp3", subdirectory: "QuizFeedback")
            ?? Bundle.main.url(forResource: resource, withExtension: "mp3")
        guard let url else { return }
        player?.stop()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        player?.play()
    }

    private func nextIndex(for cue: Cue) -> Int {
        var bag = remaining[cue] ?? []
        if bag.isEmpty {
            bag = Array(1...10).shuffled()
            if bag.last == lastPlayed[cue], bag.count > 1 { bag.swapAt(0, bag.count - 1) }
        }
        let index = bag.removeLast()
        remaining[cue] = bag
        lastPlayed[cue] = index
        return index
    }
}
