@preconcurrency import AVFoundation

/// An object that provides the interface to control audio playback.
public final actor AudioPlayer {
    private var connected: [AudioPlayerNode: Bool] = [:]
    private var audioEngine: AVAudioEngine?
    private var playerNodes: [AudioPlayerNode: AVAudioPlayerNode] = [:]

    /// Create an audio player object.
    public init(audioEngine: AVAudioEngine) {
        self.audioEngine = audioEngine
    }

    func isConnected(_ playerNode: AudioPlayerNode) -> Bool {
        return connected[playerNode] == true
    }

    func connect(_ playerNode: AudioPlayerNode, format: AVAudioFormat?) {
        guard let audioEngine, let avPlayerNode = playerNodes[playerNode] else {
            return
        }
        if let format {
            // LM-Monitor patch: route the player node through
            // mainMixerNode instead of going straight to outputNode.
            // AVAudioOutputNode does not perform automatic format
            // conversion, so when the decoded AAC -> Float32 format
            // does not exactly match the device's native output
            // format (sample rate, channel layout, interleaving),
            // the connection silently produces no audible audio even
            // though engine.isRunning is true and volume is 1.0.
            // AVAudioMixerNode handles the conversion transparently,
            // which matches the pattern every working AVAudioEngine
            // playback pipeline uses (including NDIMonitor's own
            // NDIWrapper).
            audioEngine.connect(avPlayerNode, to: audioEngine.mainMixerNode, format: format)
            if !audioEngine.isRunning {
                try? audioEngine.start()
            }
            connected[playerNode] = true
        } else {
            if audioEngine.isRunning {
                audioEngine.stop()
            }
            audioEngine.disconnectNodeOutput(avPlayerNode)
            connected[playerNode] = nil
        }
    }

    func detach(_ playerNode: AudioPlayerNode) {
        if let playerNode = playerNodes[playerNode] {
            audioEngine?.detach(playerNode)
        }
        playerNodes[playerNode] = nil
    }

    func makePlayerNode() -> AudioPlayerNode {
        let avAudioPlayerNode = AVAudioPlayerNode()
        audioEngine?.attach(avAudioPlayerNode)
        let playerNode = AudioPlayerNode(player: self, playerNode: avAudioPlayerNode)
        playerNodes[playerNode] = avAudioPlayerNode
        return playerNode
    }
}
