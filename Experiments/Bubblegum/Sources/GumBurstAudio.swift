#if os(iOS)
import AVFAudio

@MainActor
final class GumBurstAudio {
    private var player: AVAudioPlayer?

    func prepare() {
        guard let url = Bundle.main.url(forResource: "GumBurst", withExtension: "wav") else {
            return
        }
        if player == nil { player = try? AVAudioPlayer(contentsOf: url) }
        player?.prepareToPlay()
    }

    @discardableResult
    func play() -> Bool {
        if player == nil { prepare() }
        guard let player else { return false }
        player.currentTime = 0
        return player.play()
    }
}
#endif
