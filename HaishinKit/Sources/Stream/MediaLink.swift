import CoreMedia
import Foundation

final actor MediaLink {
    static let capacity = 90
    static let duration: TimeInterval = 0.0
    /// How long to wait for the audio clock before pacing video with the
    /// display link instead. Senders whose audio decodes start well inside
    /// this window and are therefore unaffected.
    static let audioClockGracePeriod: TimeInterval = 1.0

    var dequeue: AsyncStream<CMSampleBuffer> {
        AsyncStream { continutation in
            self.continutation = continutation
        }
    }
    private(set) var isRunning = false
    private var storage: TypedBlockQueue<CMSampleBuffer>?
    private var continutation: AsyncStream<CMSampleBuffer>.Continuation? {
        didSet {
            oldValue?.finish()
        }
    }
    private var duration: TimeInterval = MediaLink.duration
    private var isUsingDisplayLinkClock = false
    private var presentationTimeStampOrigin: CMTime = .invalid
    private lazy var displayLink = DisplayLinkChoreographer()
    private weak var audioPlayer: AudioPlayerNode?

    init() {
        do {
            storage = try .init(capacity: Self.capacity, handlers: .outputPTSSortedSampleBuffers)
        } catch {
            logger.error(error)
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard isRunning else {
            return
        }
        if presentationTimeStampOrigin == .invalid {
            presentationTimeStampOrigin = sampleBuffer.presentationTimeStamp
        }
        do {
            try storage?.enqueue(sampleBuffer)
        } catch {
            logger.error(error)
        }
    }

    func setAudioPlayer(_ audioPlayer: AudioPlayerNode?) {
        self.audioPlayer = audioPlayer
    }

    private func getCurrentTime(_ timestamp: TimeInterval) async -> TimeInterval {
        defer {
            duration += timestamp
        }
        // LM-Monitor patch: fall back to the display-link clock only when the
        // audio clock never starts at all.
        //
        // AudioPlayerNode.currentTime returns 0.0 while its playerNode is not
        // playing, which is the permanent state for a video-only stream (or
        // one whose audio never decodes). The original `?? duration` only
        // covers a *nil* audioPlayer, and a receiver that calls
        // attachAudioPlayer always has one, so currentTime stays pinned at 0.
        //
        // The release test in startRunning is
        //     pts - ptsOrigin <= currentTime
        // so with currentTime == 0 only the very first frame (pts == origin)
        // is ever yielded and every later frame stays in the queue.
        //
        // Symptom: such a source displays a single frozen frame while the
        // connection stays healthy and frames keep arriving.
        //
        // The grace period matters: senders whose audio decodes normally
        // start it within a few frames, so they keep the original
        // audio-driven pacing untouched and this branch never runs for them.
        // Switching to the display link is latched, because the audio clock
        // restarts near zero and adopting it late would run the clock
        // backwards and stall video that has already been released.
        if !isUsingDisplayLinkClock {
            if let audioTime = await audioPlayer?.currentTime, 0 < audioTime {
                return audioTime
            }
            guard Self.audioClockGracePeriod < duration else {
                return 0.0
            }
            isUsingDisplayLinkClock = true
            logger.info("audio clock never started; pacing video with the display link")
        }
        return duration
    }
}

extension MediaLink: AsyncRunner {
    // MARK: AsyncRunner
    func startRunning() {
        guard !isRunning else {
            return
        }
        isRunning = true
        duration = 0.0
        isUsingDisplayLinkClock = false
        displayLink.startRunning()
        Task {
            for await currentTime in displayLink.updateFrames {
                guard let storage else {
                    continue
                }
                let currentTime = await getCurrentTime(currentTime.targetTimestamp - currentTime.timestamp)
                var frameCount = 0
                while !storage.isEmpty {
                    guard let first = storage.head else {
                        break
                    }
                    if first.presentationTimeStamp.seconds - presentationTimeStampOrigin.seconds <= currentTime {
                        continutation?.yield(first)
                        frameCount += 1
                        _ = storage.dequeue()
                    } else {
                        if 2 < frameCount {
                            logger.info("droppedFrame: \(frameCount)")
                        }
                        break
                    }
                }
            }
        }
    }

    func stopRunning() {
        guard isRunning else {
            return
        }
        continutation = nil
        displayLink.stopRunning()
        presentationTimeStampOrigin = .invalid
        try? storage?.reset()
        isRunning = false
    }
}
