@preconcurrency import AVFoundation
import Foundation

final actor AudioPlayerNode {
    static let bufferCounts: Int = 10

    var currentTime: TimeInterval {
        if playerNode.isPlaying {
            guard
                let nodeTime = playerNode.lastRenderTime,
                let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
                return 0.0
            }
            return TimeInterval(playerTime.sampleTime) / playerTime.sampleRate
        }
        return 0.0
    }
    private(set) var isPaused = false
    private(set) var isRunning = false
    private(set) var soundTransfrom = SoundTransform()
    private let playerNode: AVAudioPlayerNode
    private var audioTime = AudioTime()
    private var scheduledAudioBuffers: Int = 0
    private var isBuffering = true
    private weak var player: AudioPlayer?
    private var format: AVAudioFormat? {
        didSet {
            guard format != oldValue else {
                return
            }
            Task { [format] in
                await player?.connect(self, format: format)
            }
        }
    }

    init(player: AudioPlayer, playerNode: AVAudioPlayerNode) {
        self.player = player
        self.playerNode = playerNode
    }

    func setSoundTransfrom(_ soundTransfrom: SoundTransform) {
        soundTransfrom.apply(playerNode)
    }

    func enqueue(_ audioBuffer: AVAudioBuffer, when: AVAudioTime) async {
        // LM-Monitor diagnostic: trace entry into the player node
        let isPCM = audioBuffer is AVAudioPCMBuffer
        let connected = await player?.isConnected(self) == true
        print("LM-fork/PlayerNode: enqueue class=\(type(of: audioBuffer)) isPCM=\(isPCM) connected=\(connected) format=\(audioBuffer.format)")
        format = audioBuffer.format
        guard let audioBuffer = audioBuffer as? AVAudioPCMBuffer, await player?.isConnected(self) == true else {
            return
        }
        scheduledAudioBuffers += 1
        // LM-Monitor patch: start the player node as soon as a buffer
        // arrives. The original threshold-based start
        //   Self.bufferCounts (= 10) <= scheduledAudioBuffers
        // never triggers in practice for live SRT: AVAudioPlayerNode's
        // scheduleBuffer completes in microseconds (it just enqueues),
        // so the async Task below decrements 'scheduledAudioBuffers'
        // well before the next 20 ms audio frame arrives. The counter
        // therefore oscillates between 0 and 1 and never reaches 10,
        // so playerNode.play() is never called and the host hears
        // silence even though engine.isRunning is true and the volume
        // is 1.0.
        //
        // Starting at the first buffer adds a small amount of initial
        // jitter (no jitter buffer pre-roll) but is the only way to
        // make audio audible at all on this code path until the
        // counter logic is reworked upstream.
        if !isPaused && !playerNode.isPlaying {
            playerNode.play()
        }
        Task {
            // LM-Monitor patch: schedule buffers with at: nil so each
            // PCM buffer plays immediately after the previous one.
            //
            // The original audioTime.at construction is broken for the
            // live-receive path:
            //
            //   if !audioTime.hasAnchor {
            //       audioTime.anchor(
            //           playerNode.lastRenderTime ?? AVAudioTime(hostTime: 0))
            //   }
            //
            // playerNode.lastRenderTime is nil before play() starts
            // rendering, so the anchor falls back to
            // AVAudioTime(hostTime: 0). That fallback has
            // sampleRate = 0, so AudioTime.sampleRate is set to 0 too.
            // audioTime.at then returns
            //   AVAudioTime(sampleTime: N, atRate: 0)
            // (extrapolateTime cannot succeed with a 0 sample rate)
            // which AVAudioPlayerNode treats as an invalid schedule
            // time and silently does not render the buffer.
            //
            // Symptom: engine.isRunning = true, volume = 1.0,
            // enqueue() is called continuously with valid PCM buffers
            // (isPCM=true, connected=true), playerNode.play() is
            // called -- and the host still hears silence.
            //
            // For a live SRT receiver we do not want a jitter buffer
            // or sample-accurate host-time alignment; we want each
            // buffer played as fast as it arrives. Passing at: nil
            // is the documented way to do that ("plays immediately
            // after the previously scheduled buffer").
            //
            // We also leave the audioTime housekeeping out of the
            // hot path entirely since nothing reads it once we bypass
            // the at: parameter.
            await playerNode.scheduleBuffer(audioBuffer, at: nil)
            scheduledAudioBuffers -= 1
            if scheduledAudioBuffers == 0 {
                isBuffering = true
            }
        }
    }

    func detach() async {
        stopRunning()
        await player?.detach(self)
    }
}

extension AudioPlayerNode: AsyncRunner {
    // MARK: AsyncRunner
    func startRunning() {
        guard !isRunning else {
            return
        }
        scheduledAudioBuffers = 0
        isRunning = true
    }

    func stopRunning() {
        guard isRunning else {
            return
        }
        if playerNode.isPlaying {
            playerNode.stop()
            playerNode.reset()
        }
        audioTime.reset()
        format = nil
        isRunning = false
    }
}

extension AudioPlayerNode: Hashable {
    // MARK: Hashable
    nonisolated public static func == (lhs: AudioPlayerNode, rhs: AudioPlayerNode) -> Bool {
        lhs === rhs
    }

    nonisolated public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
