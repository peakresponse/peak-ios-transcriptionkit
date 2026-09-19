//
//  Recorder.swift
//  TranscriptionKit
//
//  Created by Francis Li on 9/18/26.
//

import Accelerate
import AVFoundation
import Foundation

@MainActor public protocol RecorderDelegate: AnyObject {
    func recorderDidFailToStart(_ recorder: Recorder, error: Error)
    func recorderDidFinishRecording(_ recorder: Recorder, duration: TimeInterval)
    func recorderDidRequestRecordPermission(_ recorder: Recorder, granted: Bool)
    func recorderDidTransformBuffer(_ recorder: Recorder, data: [Float])
}

extension RecorderDelegate {
    public func recorderDidFailToStart(_ recorder: Recorder, error: Error) { }
    public func recorderDidFinishRecording(_ recorder: Recorder, duration: TimeInterval) { }
    public func recorderDidRequestRecordPermission(_ recorder: Recorder, granted: Bool) { }
    public func recorderDidTransformBuffer(_ recorder: Recorder, data: [Float]) { }
}

public actor Recorder {
    @MainActor public var delegate: RecorderDelegate?

    private var fileURL: URL?
    private var audioEngine: AVAudioEngine?
    private var audioInputPortUID: String?
    private var recordingStart: Date?

    nonisolated public static var bluetoothHFPInputs: [AVAudioSessionPortDescription] {
        get throws {
            var inputs: [AVAudioSessionPortDescription] = []
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothHFP, .defaultToSpeaker, .duckOthers])
            for port in audioSession.availableInputs ?? [] where port.portType == .bluetoothHFP {
                inputs.append(port)
            }
            return inputs
        }
    }

    public init() {
        
    }

    public func setAudioInputPortUID(_ audioInputPortUID: String?) {
        self.audioInputPortUID = audioInputPortUID
    }

    public func setFileURL(_ fileURL: URL) {
        self.fileURL = fileURL
    }

    @MainActor public func startRecording(fileURL: URL) {
        Task {
            await setFileURL(fileURL)
            await start()
        }
    }

    @MainActor public func stopRecording() {
        Task {
            await stop()
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func start() async {
        guard let fileURL, audioEngine == nil else { return }

        let audioSession = AVAudioSession.sharedInstance()
        if audioSession.recordPermission == .granted {
            do {
                let audioEngine = AVAudioEngine()
                self.audioEngine = audioEngine

                try audioSession.setCategory(.playAndRecord, mode: .measurement,
                                             options: [.allowBluetoothHFP, .defaultToSpeaker, .duckOthers])
                var customInput = false
                if let audioInputPortUID = audioInputPortUID {
                    for port in audioSession.availableInputs ?? [] where port.uid == audioInputPortUID {
                        try audioSession.setPreferredInput(port)
                        customInput = true
                        break
                    }
                }
                if !customInput {
                    for port in audioSession.availableInputs ?? [] where port.portType == .builtInMic {
                        try audioSession.setPreferredInput(port)
                        break
                    }
                }
                try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
                let inputNode = audioEngine.inputNode

                // Configure the microphone input.
                let recordingFormat = inputNode.outputFormat(forBus: 0)
                let audioFile = try AVAudioFile(forWriting: fileURL,
                                                settings: [AVFormatIDKey: kAudioFormatMPEG4AAC],
                                                commonFormat: recordingFormat.commonFormat,
                                                interleaved: false)
                inputNode.installTap(onBus: 0, bufferSize: 1024,
                                     format: recordingFormat) { [weak self] (buffer: AVAudioPCMBuffer, _: AVAudioTime) in
                    //                            self?.recognizer?.append(recordingFormat: recordingFormat, buffer: buffer)
                    self?.performFFT(buffer: buffer)
                    do {
                        try audioFile.write(from: buffer)
                    } catch {
                        print(error)
                    }
                }

                audioEngine.prepare()
                try audioEngine.start()

                let recordingStart = Date()
                self.recordingStart = recordingStart                
            } catch {
                Task { @MainActor in
                    delegate?.recorderDidFailToStart(self, error: error)
                }
            }
        } else {
            let result = await audioSession.hasPermissionToRecord()
            Task { @MainActor in
                delegate?.recorderDidRequestRecordPermission(self, granted: result)
            }
        }
    }

    private func stop() {
        if let audioEngine, audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            self.audioEngine = nil

            let now = Date()
            if let recordingStart {
                let duration = recordingStart.dist(to: now)
                Task { @MainActor in
                    delegate?.recorderDidFinishRecording(self, duration: duration)
                }
            }
            recordingStart = nil
        }
    }

    /**
     * FFT implementation from: https://medium.com/deezer-engineering/real-time-music-visualization-on-the-iphone-gpu-579d631272d3
     */
    nonisolated private func performFFT(buffer: AVAudioPCMBuffer) {
        let frameCount = buffer.frameLength
        let log2n = UInt(round(log2(Double(frameCount))))
        let bufferSizePOT = Int(1 << log2n)
        let inputCount = bufferSizePOT / 2
        let fftSetup = vDSP_create_fftsetup(log2n, Int32(kFFTRadix2))

        let realp = UnsafeMutablePointer<Float>.allocate(capacity: inputCount)
        let imagp = UnsafeMutablePointer<Float>.allocate(capacity: inputCount)
        var output = DSPSplitComplex(realp: realp, imagp: imagp)

        let windowSize = bufferSizePOT
        let transferBuffer = UnsafeMutablePointer<Float>.allocate(capacity: windowSize)
        let window = UnsafeMutablePointer<Float>.allocate(capacity: windowSize)

        // Hann windowing to reduce the frequency leakage
        vDSP_hann_window(window, vDSP_Length(windowSize), Int32(vDSP_HANN_NORM))
        vDSP_vmul((buffer.floatChannelData?.pointee)!, 1, window,
                  1, transferBuffer, 1, vDSP_Length(windowSize))

        // Transforming the [Float] buffer into a UnsafePointer<Float> object for the vDSP_ctoz method
        // And then pack the input into the complex buffer (output)
        transferBuffer.withMemoryRebound(to: DSPComplex.self, capacity: windowSize) {
            vDSP_ctoz($0, 2, &output, 1, vDSP_Length(inputCount))
        }

        // Perform the FFT
        vDSP_fft_zrip(fftSetup!, &output, 1, log2n, FFTDirection(FFT_FORWARD))

        let magnitudes = UnsafeMutablePointer<Float>.allocate(capacity: inputCount)
        vDSP_zvmags(&output, 1, magnitudes, 1, vDSP_Length(inputCount))

        // Normalising
        let normalizedMagnitudes = UnsafeMutablePointer<Float>.allocate(capacity: inputCount)
        vDSP_vsmul(sqrtq(Array(UnsafeBufferPointer(start: magnitudes, count: inputCount))), 1, [2.0 / Float(inputCount)],
                   normalizedMagnitudes, 1, vDSP_Length(inputCount))

        vDSP_destroy_fftsetup(fftSetup)

        // Dispatch the normalized buffer data
        let data = Array(UnsafeBufferPointer(start: normalizedMagnitudes, count: inputCount))
        Task { @MainActor in
            delegate?.recorderDidTransformBuffer(self, data: data)
        }
    }

    private nonisolated func sqrtq(_ x: [Float]) -> [Float] {
        var results = [Float](repeating: 0.0, count: x.count)
        vvsqrtf(&results, x, [Int32(x.count)])
        return results
    }
}
