import CoreMedia
import Foundation

package struct ADTSHeader: Equatable {
    static let size: Int = 7
    static let sizeWithCrc = 9
    static let sync: UInt8 = 0xFF

    var sync = Self.sync
    var id: UInt8 = 0
    var layer: UInt8 = 0
    var protectionAbsent = false
    var profile: UInt8 = 0
    var sampleFrequencyIndex: UInt8 = 0
    var channelConfiguration: UInt8 = 0
    var originalOrCopy = false
    var home = false
    var copyrightIdBit = false
    var copyrightIdStart = false
    package var aacFrameLength: UInt16 = 0
    var bufferFullness: UInt16 = 0
    var aacFrames: UInt8 = 0

    package init() {
    }

    package init(data: Data) {
        self.data = data
    }

    package func makeFormatDescription() -> CMFormatDescription? {
        guard
            let type = AudioSpecificConfig.AudioObjectType(rawValue: profile + 1),
            let frequency = AudioSpecificConfig.SamplingFrequency(rawValue: sampleFrequencyIndex),
            let channel = AudioSpecificConfig.ChannelConfiguration(rawValue: channelConfiguration) else {
            return nil
        }
        // LM-Monitor patch: use the real channel count, and refuse to build a
        // format we cannot describe.
        //
        // mChannelsPerFrame used to be `channel.rawValue`, which is the enum's
        // raw ADTS value rather than a channel count. They coincide up to 5.1
        // but 7.1 has raw value 7 and eight channels, so its format described
        // one channel too few.
        //
        // channelConfiguration 0 means "the layout lives in the stream's
        // program_config_element", which is what an encoder emits for a
        // non-standard layout such as quad (OBS does this). channelCount is
        // then 0, and the old code happily created a zero-channel format that
        // no decoder can use, so audio was silently dropped with no clue why.
        // Returning nil keeps the failure visible in the log instead.
        let channelCount = channel.channelCount
        guard 0 < channelCount else {
            logger.warn("unsupported AAC channel_configuration=0 (layout defined in the program_config_element); audio will not be played")
            return nil
        }
        var formatDescription: CMAudioFormatDescription?
        var audioStreamBasicDescription = AudioStreamBasicDescription(
            mSampleRate: frequency.sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: UInt32(type.rawValue),
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &audioStreamBasicDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr else {
            return nil
        }
        return formatDescription
    }
}

extension ADTSHeader: DataConvertible {
    package var data: Data {
        get {
            Data()
        }
        set {
            guard ADTSHeader.size <= newValue.count else {
                return
            }
            sync = newValue[0]
            id = (newValue[1] & 0b00001111) >> 3
            layer = (newValue[1] >> 2) & 0b00000011
            protectionAbsent = (newValue[1] & 0b00000001) == 1
            profile = newValue[2] >> 6 & 0b11
            sampleFrequencyIndex = (newValue[2] >> 2) & 0b00001111
            channelConfiguration = ((newValue[2] & 0b1) << 2) | newValue[3] >> 6
            originalOrCopy = (newValue[3] & 0b00100000) == 0b00100000
            home = (newValue[3] & 0b00010000) == 0b00010000
            copyrightIdBit = (newValue[3] & 0b00001000) == 0b00001000
            copyrightIdStart = (newValue[3] & 0b00000100) == 0b00000100
            aacFrameLength = UInt16(newValue[3] & 0b00000011) << 11 | UInt16(newValue[4]) << 3 | UInt16(newValue[5] >> 5)
            bufferFullness = UInt16(newValue[5]) >> 2 | UInt16(newValue[6] >> 2)
            aacFrames = newValue[6] & 0b00000011
        }
    }
}
