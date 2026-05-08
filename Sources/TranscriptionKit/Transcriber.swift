//
//  Transcriber.swift
//  TranscriptionKit
//
//  Created by Francis Li on 11/14/19.
//  Copyright © 2019 Francis Li. All rights reserved.
//

import Accelerate
import AVFoundation
import Speech

@objc public enum TranscriberAuthorizationStatus: Int {
    case granted, denied, restricted, unknown
}

public enum TranscriberError: Error {
    case recordNotAuthorized
    case speechRecognitionNotAuthorized
    case speechRecognitionRestricted
    case unexpected
}

@objc public protocol TranscriberDelegate {
    @objc optional func transcriber(_ transcriber: Transcriber, didFinishPlaying successfully: Bool)
    @objc optional func transcriber(_ transcriber: Transcriber, didPlay seconds: TimeInterval, formattedDuration duration: String)
    // swiftlint:disable:next function_parameter_count
    @objc optional func transcriber(_ transcriber: Transcriber, didRecognizeText text: String, fileId: String,
                                    transcriptId: String, metadata: [String: Any], isFinal: Bool)
    @objc optional func transcriber(_ transcriber: Transcriber, didRecord seconds: TimeInterval, formattedDuration duration: String)
    @objc optional func transcriber(_ transcriber: Transcriber, didTransformBuffer data: [Float])
    @objc optional func transcriberDidFinishRecognition(_ transcriber: Transcriber, withError error: Error?)
    @objc optional func transcriber(_ transcriber: Transcriber, didRequestRecordAuthorization status: TranscriberAuthorizationStatus)
    @objc optional func transcriber(_ transcriber: Transcriber, didRequestSpeechAuthorization status: TranscriberAuthorizationStatus)
}

public class Transcriber: NSObject, AVAudioPlayerDelegate, RecognizerDelegate {
    let audioEngine = AVAudioEngine()

    public var recognizer: Recognizer? {
        didSet { recognizer?.delegate = self }
    }

    public var fileId: String!
    public var fileURL: URL!
    public var recordingLength: TimeInterval = 0
    public var recordingLengthFormatted: String {
        return String(format: "%02.0f:%02.0f:%02.0f",
                      recordingLength / 3600, recordingLength / 60, recordingLength.truncatingRemainder(dividingBy: 60))
    }
    var recordingStart: Date?
    var timer: Timer?
    var player: AVAudioPlayer?
    public var isPlaying: Bool {
        return player?.isPlaying ?? false
    }

    public var audioInputPortUID: String?
    public weak var delegate: TranscriberDelegate?

    override public init() {
        super.init()
        recognizer = AppleRecognizer()
        recognizer?.delegate = self // set explicitly because didSet not called during initialization
        reset()
    }

    public static var bluetoothHFPInputs: [AVAudioSessionPortDescription] {
        var inputs: [AVAudioSessionPortDescription] = []
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetooth, .defaultToSpeaker, .duckOthers])
            for port in audioSession.availableInputs ?? [] where port.portType == .bluetoothHFP {
                inputs.append(port)
            }
        } catch {
            print(error)
        }
        return inputs
    }

    public func reset() {
        player = nil
        let tempDirURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        fileId = UUID().uuidString
        fileURL = tempDirURL.appendingPathComponent(fileId).appendingPathExtension("mp4")
    }

    public func prepareToPlay() throws {
        player = try AVAudioPlayer(contentsOf: fileURL)
        recordingLength = player?.duration ?? 0
        player?.delegate = self
        player?.prepareToPlay()
        player?.volume = 1
    }

    public func playPressed() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        if player == nil {
            try prepareToPlay()
        }
        player?.play()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] (_) in
            guard let self = self else { return }
            if let seconds = self.player?.currentTime {
                let duration = String(format: "%02.0f:%02.0f:%02.0f",
                                      seconds / 3600, seconds / 60, seconds.truncatingRemainder(dividingBy: 60))
                self.delegate?.transcriber?(self, didPlay: seconds, formattedDuration: duration)
            }
        }
    }

    public func stopPressed() {
        player?.stop()
        player = nil
        timer?.invalidate()
        timer = nil
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public func startRecording() throws {
        let audioSession = AVAudioSession.sharedInstance()
        if audioSession.recordPermission == .granted {
            if recognizer?.isAuthorized() ?? false {
                if !audioEngine.isRunning {
                    try audioSession.setCategory(.playAndRecord, mode: .measurement,
                                                 options: [.allowBluetooth, .defaultToSpeaker, .duckOthers])
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

                    try recognizer?.startTranscribing { [weak self] in
                        guard let self = self else { return }
                        // Configure the microphone input.
                        let recordingFormat = inputNode.outputFormat(forBus: 0)
                        guard let audioFile = try? AVAudioFile(forWriting: self.fileURL,
                                                               settings: [AVFormatIDKey: kAudioFormatMPEG4AAC],
                                                               commonFormat: recordingFormat.commonFormat,
                                                               interleaved: false) else { return }
                        inputNode.installTap(onBus: 0, bufferSize: 1024,
                                             format: recordingFormat) { [weak self] (buffer: AVAudioPCMBuffer, _: AVAudioTime) in
                            self?.recognizer?.append(recordingFormat: recordingFormat, buffer: buffer)
                            self?.performFFT(buffer: buffer)
                            do {
                                try audioFile.write(from: buffer)
                            } catch {
                                print(error)
                            }
                        }

                        self.audioEngine.prepare()
                        try? self.audioEngine.start()

                        self.recordingStart = Date()
                        self.timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] (_) in
                            guard let self = self else { return }
                            let now = Date()
                            if let start = self.recordingStart {
                                let seconds = self.recordingLength + start.dist(to: now)
                                let duration = String(format: "%02.0f:%02.0f:%02.0f",
                                                      seconds / 3600, seconds / 60, seconds.truncatingRemainder(dividingBy: 60))
                                self.delegate?.transcriber?(self, didRecord: seconds, formattedDuration: duration)
                            }
                        }
                    }
                }
            } else {
                recognizer?.requestAuthorization { [weak self] (status) in
                    guard let self = self else { return }
                    var transcriberStatus: TranscriberAuthorizationStatus
                    switch status {
                    case .denied:
                        transcriberStatus = .denied
                    case .restricted:
                        transcriberStatus = .restricted
                    case .authorized:
                        transcriberStatus = .granted
                    default:
                        transcriberStatus = .unknown
                    }
                    self.delegate?.transcriber?(self, didRequestSpeechAuthorization: transcriberStatus)
                }
            }
        } else {
            audioSession.requestRecordPermission { [weak self] (granted) in
                guard let self = self else { return }
                self.delegate?.transcriber?(self, didRequestRecordAuthorization: granted ? .granted : .denied)
            }
        }
    }

    public func stopRecording() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)

            recognizer?.stopTranscribing()

            timer?.invalidate()
            timer = nil
            let now = Date()
            if let start = recordingStart {
                recordingLength += start.dist(to: now)
            }
            recordingStart = nil
        }
    }

    /**
     * FFT implementation from: https://deezer.io/real-time-music-visualization-on-the-iphone-gpu-579d631272d3
     */
    func performFFT(buffer: AVAudioPCMBuffer) {
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

        delegate?.transcriber?(self, didTransformBuffer: Array(UnsafeBufferPointer(start: normalizedMagnitudes, count: inputCount)))

        vDSP_destroy_fftsetup(fftSetup)
    }

    func sqrtq(_ x: [Float]) -> [Float] {
        var results = [Float](repeating: 0.0, count: x.count)
        vvsqrtf(&results, x, [Int32(x.count)])
        return results
    }

    // MARK: - AVAudioPlayerDelegate

    public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        if let error = error {
            print(error)
        }
        delegate?.transcriber?(self, didFinishPlaying: false)
    }

    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        delegate?.transcriber?(self, didFinishPlaying: flag)
    }

    // MARK: - RecognizerDelegate

    public func recognizer(_ recognizer: Recognizer,
                           didRecognizeText text: String, transcriptId: String, metadata: [String: Any], isFinal: Bool) {
        delegate?.transcriber?(self, didRecognizeText: text, fileId: fileId, transcriptId: transcriptId,
                               metadata: metadata, isFinal: isFinal)
    }

    public func recognizer(_ recognizer: Recognizer, didFinishWithError error: Error?) {
        delegate?.transcriberDidFinishRecognition?(self, withError: error)
    }
}
