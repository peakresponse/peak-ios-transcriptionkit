//
//  AudioHelper.swift
//  Triage
//
//  Created by Francis Li on 11/14/19.
//  Copyright © 2019 Francis Li. All rights reserved.
//

import Accelerate
import AVFoundation
import Speech

@objc protocol AudioHelperDelgate {
    @objc optional func audioHelper(_ audioHelper: AudioHelper, didFinishPlaying successfully: Bool)
    @objc optional func audioHelper(_ audioHelper: AudioHelper, didPlay seconds: TimeInterval, formattedDuration duration: String)
    @objc optional func audioHelper(_ audioHelper: AudioHelper, didRecognizeText text: String,
                                    sourceId: String, metadata: [String: Any], isFinal: Bool)
    @objc optional func audioHelper(_ audioHelper: AudioHelper, didRecord seconds: TimeInterval, formattedDuration duration: String)
    @objc optional func audioHelper(_ audioHelper: AudioHelper, didTransformBuffer data: [Float])
    @objc optional func audioHelperDidFinishRecognition(_ audioHelper: AudioHelper)
    @objc optional func audioHelper(_ audioHelper: AudioHelper, didRequestRecordAuthorization status: AVAudioSession.RecordPermission)
    @objc optional func audioHelper(_ audioHelper: AudioHelper, didRequestSpeechAuthorization status: SFSpeechRecognizerAuthorizationStatus)
}

enum AudioHelperError: Error {
    case recordNotAuthorized
    case speechRecognitionNotAuthorized
}

class AudioHelper: NSObject, AVAudioPlayerDelegate {
    let audioEngine = AVAudioEngine()
    let speechRecognizer = SFSpeechRecognizer()
    var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    var recognitionTask: SFSpeechRecognitionTask?

    var fileURL: URL!
    var recordingLength: TimeInterval = 0
    var recordingLengthFormatted: String {
        return String(format: "%02.0f:%02.0f:%02.0f",
                      recordingLength / 3600, recordingLength / 60, recordingLength.truncatingRemainder(dividingBy: 60))
    }
    var recordingStart: Date?
    var timer: Timer?
    var player: AVAudioPlayer?
    var isPlaying: Bool {
        return player?.isPlaying ?? false
    }

    var audioInputPortUID: String?
    weak var delegate: AudioHelperDelgate?

    override init() {
        super.init()
        reset()
    }

    /*
    static var bluetoothHFPInputs: [AVAudioSessionPortDescription] {
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
     */

    func reset() {
        player = nil
        let tempDirURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        fileURL = tempDirURL.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
    }

    func prepareToPlay() throws {
        player = try AVAudioPlayer(contentsOf: fileURL)
        recordingLength = player?.duration ?? 0
        player?.delegate = self
        player?.prepareToPlay()
        player?.volume = 1
    }

    func playPressed() throws {
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
                self.delegate?.audioHelper?(self, didPlay: seconds, formattedDuration: duration)
            }
        }
    }

    func stopPressed() {
        player?.stop()
        player = nil
        timer?.invalidate()
        timer = nil
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func startRecording() throws {
        let audioSession = AVAudioSession.sharedInstance()
        if audioSession.recordPermission == .granted {
            if SFSpeechRecognizer.authorizationStatus() == .authorized {
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

                    recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
                    guard let recognitionRequest = recognitionRequest else {
                        fatalError("Unable to create a SFSpeechAudioBufferRecognitionRequest object") }
                    recognitionRequest.shouldReportPartialResults = true

                    // Create a recognition task for the speech recognition session.
                    // Keep a reference to the task so that it can be canceled.
                    recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] (result, error) in
                        var isFinal = false

                        if let result = result {
                            // Update the text view with the results.
                            isFinal = result.isFinal
                            let text = result.bestTranscription.formattedString
                            // convert the transcription segments into a metadata payload
                            var segmentsMetadata: [[String: Any]] = []
                            for segment in result.bestTranscription.segments {
                                let segmentMetadata: [String: Any] = [
                                    "substring": segment.substring,
                                    "substringRange": [
                                        "location": segment.substringRange.location,
                                        "length": segment.substringRange.length
                                    ],
                                    "alternativeSubstrings": segment.alternativeSubstrings,
                                    "confidence": segment.confidence,
                                    "timestamp": segment.timestamp,
                                    "duration": segment.duration
                                ]
                                segmentsMetadata.append(segmentMetadata)
                            }
                            let sourceId = UUID().uuidString
                            let metadata: [String: Any] = [
                                "type": "SPEECH",
                                "provider": "APPLE",
                                "segments": segmentsMetadata
                            ]
                            if let self = self {
                                self.delegate?.audioHelper?(self, didRecognizeText: text,
                                                            sourceId: sourceId, metadata: metadata, isFinal: isFinal)
                            }
                        }

                        if error != nil || isFinal {
                            // Stop recognizing speech if there is a problem.
                            self?.audioEngine.stop()
                            inputNode.removeTap(onBus: 0)

                            self?.recognitionRequest = nil
                            self?.recognitionTask = nil

                            if let self = self {
                                self.delegate?.audioHelperDidFinishRecognition?(self)
                            }
                        }
                    }

                    // Configure the microphone input.
                    let recordingFormat = inputNode.outputFormat(forBus: 0)
                    let audioFile = try AVAudioFile(forWriting: fileURL, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC],
                                                    commonFormat: recordingFormat.commonFormat, interleaved: false)
                    inputNode.installTap(onBus: 0, bufferSize: 1024,
                                         format: recordingFormat) { [weak self] (buffer: AVAudioPCMBuffer, _: AVAudioTime) in
                        self?.recognitionRequest?.append(buffer)
                        self?.performFFT(buffer: buffer)
                        do {
                            try audioFile.write(from: buffer)
                        } catch {
                            print(error)
                        }
                    }

                    audioEngine.prepare()
                    try audioEngine.start()

                    recordingStart = Date()
                    timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] (_) in
                        guard let self = self else { return }
                        let now = Date()
                        if let start = self.recordingStart {
                            let seconds = self.recordingLength + start.dist(to: now)
                            let duration = String(format: "%02.0f:%02.0f:%02.0f",
                                                  seconds / 3600, seconds / 60, seconds.truncatingRemainder(dividingBy: 60))
                            self.delegate?.audioHelper?(self, didRecord: seconds, formattedDuration: duration)
                        }
                    }
                }
            } else {
                SFSpeechRecognizer.requestAuthorization { [weak self] (status) in
                    guard let self = self else { return }
                    self.delegate?.audioHelper?(self, didRequestSpeechAuthorization: status)
                }
            }
        } else {
            audioSession.requestRecordPermission { [weak self] (granted) in
                guard let self = self else { return }
                self.delegate?.audioHelper?(self, didRequestRecordAuthorization: granted ? .granted : .denied)
            }
        }
    }

    func stopRecording() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            recognitionRequest?.endAudio()

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

        delegate?.audioHelper?(self, didTransformBuffer: Array(UnsafeBufferPointer(start: normalizedMagnitudes, count: inputCount)))

        vDSP_destroy_fftsetup(fftSetup)
    }

    func sqrtq(_ x: [Float]) -> [Float] {
      var results = [Float](repeating: 0.0, count: x.count)
      vvsqrtf(&results, x, [Int32(x.count)])
      return results
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        if let error = error {
            print(error)
        }
        delegate?.audioHelper?(self, didFinishPlaying: false)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        delegate?.audioHelper?(self, didFinishPlaying: flag)
    }
}
