//
//  AVAudioPCMBuffer.swift
//  TranscriptionKit
//
//  Created by Francis Li on 9/18/26.
//

import AVFoundation

extension AVAudioPCMBuffer {
    func makeCopy() -> AVAudioPCMBuffer? {
        // 1. Create a new buffer with matching format and capacity
        guard let copy = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: self.frameCapacity) else {
            return nil
        }

        // 2. Set the frame length to match the current buffer data size
        copy.frameLength = self.frameLength

        // 3. Handle 32-bit Float formats (most common in AVFoundation)
        if let srcChannels = self.floatChannelData, let destChannels = copy.floatChannelData {
            for channel in 0..<Int(self.format.channelCount) {
                let size = Int(self.frameLength) * MemoryLayout<Float>.size
                memcpy(destChannels[channel], srcChannels[channel], size)
            }
            return copy
        }

        // 4. Handle 16-bit Int formats
        if let srcChannels = self.int16ChannelData, let destChannels = copy.int16ChannelData {
            for channel in 0..<Int(self.format.channelCount) {
                let size = Int(self.frameLength) * MemoryLayout<Int16>.size
                memcpy(destChannels[channel], srcChannels[channel], size)
            }
            return copy
        }

        // 5. Handle 32-bit Int formats
        if let srcChannels = self.int32ChannelData, let destChannels = copy.int32ChannelData {
            for channel in 0..<Int(self.format.channelCount) {
                let size = Int(self.frameLength) * MemoryLayout<Int32>.size
                memcpy(destChannels[channel], srcChannels[channel], size)
            }
            return copy
        }

        return nil
    }
}
