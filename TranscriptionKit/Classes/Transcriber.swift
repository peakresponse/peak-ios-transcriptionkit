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
import AWSTranscribeStreaming

@objc public protocol TranscriberDelegate {
    @objc optional func transcriber(_ transcriber: Transcriber, didFinishPlaying successfully: Bool)
    @objc optional func transcriber(_ transcriber: Transcriber, didPlay seconds: TimeInterval, formattedDuration duration: String)
    @objc optional func transcriber(_ transcriber: Transcriber, didRecognizeText text: String,
                                    sourceId: String, metadata: [String: Any], isFinal: Bool)
    @objc optional func transcriber(_ transcriber: Transcriber, didRecord seconds: TimeInterval, formattedDuration duration: String)
    @objc optional func transcriber(_ transcriber: Transcriber, didTransformBuffer data: [Float])
    @objc optional func transcriberDidFinishRecognition(_ transcriber: Transcriber)
    @objc optional func transcriber(_ transcriber: Transcriber, didRequestRecordAuthorization status: AVAudioSession.RecordPermission)
    @objc optional func transcriber(_ transcriber: Transcriber, didRequestSpeechAuthorization status: SFSpeechRecognizerAuthorizationStatus)
}

public enum TranscriberError: Error {
    case recordNotAuthorized
    case speechRecognitionNotAuthorized
    case unexpected
}

open class Transcriber: NSObject, AVAudioPlayerDelegate {

    let audioEngine = AVAudioEngine()
    let speechRecognizer = SFSpeechRecognizer()
    var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    var recognitionTask: SFSpeechRecognitionTask?
    var inputNode: AVAudioInputNode?

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

    let accessKey = "AKIAYBXMYJKEKR7ELO6R"
    let secretKey = "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"
    let region = AWSRegionType.USEast1

    private let networkOperationTimeout = 30.0
    var transcribeStreamingClient: AWSTranscribeStreaming!
    var converter: AVAudioConverter!
    var compressedBuffer: AVAudioCompressedBuffer?

    public var audioInputPortUID: String?
    public weak var delegate: TranscriberDelegate?

    override public init() {
        super.init()
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

    // MARK: - Public Methods

    public func startRecording() throws {
        prepareEngines()
    }

    public func stopRecording() {
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

            print("Sending end frame")
            self.transcribeStreamingClient.sendEndFrame()
            self.transcribeStreamingClient.endTranscription()
        }
    }

    // MARK: - Internal Methods

    private func prepareEngines() {
        try? startAudioSession { [weak self] in
            try? self?.startAWSTranscribe {
                try? self?.record()
            }
        }
    }

    private func startAudioSession(completion: (() -> Void)) throws {
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
                    inputNode = audioEngine.inputNode

                    completion()
                }
            } else {
                SFSpeechRecognizer.requestAuthorization { [weak self] (status) in
                    guard let self = self else { return }
                    self.delegate?.transcriber?(self, didRequestSpeechAuthorization: status)
                }
            }
        } else {
            audioSession.requestRecordPermission { [weak self] (granted) in
                guard let self = self else { return }
                self.delegate?.transcriber?(self, didRequestRecordAuthorization: granted ? .granted : .denied)
            }
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func startAWSTranscribe(completion: @escaping (() -> Void)) throws {

        let credentialsProvider = AWSStaticCredentialsProvider(accessKey: accessKey, secretKey: secretKey)
        let configuration = AWSServiceConfiguration(region: region, credentialsProvider: credentialsProvider)
        AWSServiceManager.default().defaultServiceConfiguration = configuration

        guard let config = AWSServiceManager.default().defaultServiceConfiguration else {
            fatalError("Can't get default service configuration")
        }

        AWSTranscribeStreaming.register(with: config, forKey: accessKey)
        transcribeStreamingClient = AWSTranscribeStreaming(forKey: accessKey)

        AWSDDLog.sharedInstance.logLevel = .info
        AWSDDLog.add(AWSDDTTYLogger.sharedInstance)

        // Create a recognition task for the speech recognition session.
        // Keep a reference to the task so that it can be canceled.

        guard let request = AWSTranscribeStreamingStartStreamTranscriptionRequest() else {
            fatalError("request unexpectedly nil")
        }

        request.languageCode = .enUS
        request.mediaEncoding = .pcm
        request.mediaSampleRateHertz = 8000

        // Set up delegate and its expectations
        let delegate = TranscriberStreamingClientDelegate()
        transcribeStreamingClient.setDelegate(delegate, callbackQueue: DispatchQueue.global())

        // Connection open/close
        delegate.connectionStatusCallback = { status, error in
            if status == .connected {
                DispatchQueue.main.async {
                    print("Connected")
                    completion()
                }
            }

            if status == .closed && error == nil {
                DispatchQueue.main.async {
                    print("Disconnected")
                }
            }
        }

        // Event: for this test, we expect to only receive transcriptions, not errors
        delegate.receiveEventCallback = { event, error in
            if let error = error {
                fatalError("Unexpected error receiving event: \(error)")
            }

            guard let event = event else {
                fatalError("event unexpectedly nil")
            }

            guard let transcriptEvent = event.transcriptEvent else {
                fatalError("transcriptEvent unexpectedly nil: event may be an error \(event)")
            }

            guard let results = transcriptEvent.transcript?.results else {
                print("No results, waiting for next event")
                return
            }

            guard let firstResult = results.first else {
                print("firstResult nil--possibly a partial result: \(event)")
                return
            }

            guard let isPartial = firstResult.isPartial as? Bool else {
                fatalError("isPartial unexpectedly nil, or cannot cast NSNumber to Bool")
            }

            var text = ""
            var segmentsMetadata: [[String: Any]] = []
            results.forEach { result in
                result.alternatives?.forEach({ alternative in
                    alternative.items?.forEach({ item in
                        print("final content: \(item.content ?? "")")
                        text = item.content ?? ""
                        let duration = (item.endTime?.decimalValue ?? 0) - (item.startTime?.decimalValue ?? 0)
                        let segmentMetadata: [String: Any] = [
                            "substring": text,
                            "substringRange": [
                                // "location": segment.substringRange.location,
                                "length": text.count
                            ],
                            //                            "alternativeSubstrings": segment.alternativeSubstrings,
                            //                            "confidence": segment.confidence,
                            //                            "timestamp": segment.timestamp,
                            "duration": duration
                        ]
                        segmentsMetadata.append(segmentMetadata)
                    })
                })
            }
            // Update the text view with the results.
            let isFinal = !isPartial
            // convert the transcription segments into a metadata payload

            let sourceId = UUID().uuidString
            let metadata: [String: Any] = [
                "type": "SPEECH",
                "provider": "AWS",
                "segments": segmentsMetadata
            ]
            self.delegate?.transcriber?(self, didRecognizeText: text,
                                        sourceId: sourceId, metadata: metadata, isFinal: isFinal)

            if error != nil || isFinal {
                // Stop recognizing speech if there is a problem.
                self.audioEngine.stop()
                self.inputNode?.removeTap(onBus: 0)

                self.recognitionRequest = nil
                self.recognitionTask = nil

                DispatchQueue.main.async {
                    print("Ending transcription")
                    self.transcribeStreamingClient.endTranscription()
                }

                self.delegate?.transcriberDidFinishRecognition?(self)
            }
        }
        transcribeStreamingClient.startTranscriptionWSS(request)
    }

    private func record() throws {

        guard let inputNode = inputNode else { return }

        let recordingFormat = inputNode.outputFormat(forBus: 0)

        var outDesc = AudioStreamBasicDescription()
        outDesc.mSampleRate = recordingFormat.sampleRate
        outDesc.mChannelsPerFrame = 1
        outDesc.mFormatID = kAudioFormatFLAC

        let framesPerPacket: UInt32 = 1152
        outDesc.mFramesPerPacket = framesPerPacket
        outDesc.mBitsPerChannel = 24
        outDesc.mBytesPerPacket = 0

        let convertFormat = AVAudioFormat(streamDescription: &outDesc)!
        let converter = AVAudioConverter(from: recordingFormat, to: convertFormat)
        self.converter = converter

        let packetSize: UInt32 = 8
        let bufferSize = 1 * packetSize

        let audioFile = try AVAudioFile(forWriting: fileURL, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC],
                                        commonFormat: recordingFormat.commonFormat, interleaved: false)
        inputNode.installTap(onBus: 0, bufferSize: bufferSize,
                             format: recordingFormat) { [weak self] (buffer: AVAudioPCMBuffer, _: AVAudioTime) in

            guard let self = self else { return }

            let count = Int(buffer.frameLength)
            guard count > 0 else { return }

            let headers = [
                ":content-type": "audio/flac",
                ":message-type": "event",
                ":event-type": "AudioEvent"
            ]
            
            /*
             * AVAudioPCMBuffer -> transcribeStreamingClient.send(data
             */
        
            self.compressedBuffer = AVAudioCompressedBuffer(
                format: convertFormat,
                packetCapacity: packetSize,
                maximumPacketSize: self.converter.maximumOutputPacketSize
            )

            let inputBlock: AVAudioConverterInputBlock = { (_, outStatus) -> AVAudioBuffer? in
                outStatus.pointee = AVAudioConverterInputStatus.haveData
                return buffer
            }

            var outError: NSError?
            self.converter.convert(to: self.compressedBuffer!, error: &outError, withInputFrom: inputBlock)

            let audioBuffer = buffer.audioBufferList.pointee.mBuffers
            if let mData = audioBuffer.mData {
                let length = Int(audioBuffer.mDataByteSize)
                let dataChunk: Data = Data(bytes: mData, count: length)

                let chunkSize = 4096
                let audioDataSize = dataChunk.count

                var currentStart = 0
                var currentEnd = min(chunkSize, audioDataSize - currentStart)

                while currentStart < audioDataSize {
                    let dataChunk = dataChunk[currentStart ..< currentEnd]
                    self.transcribeStreamingClient.send(dataChunk, headers: headers)

                    currentStart = currentEnd
                    currentEnd = min(currentStart + chunkSize, audioDataSize)
                }

            } else {
                print("error")
            }

            self.performFFT(buffer: buffer)
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
                self.delegate?.transcriber?(self, didRecord: seconds, formattedDuration: duration)
            }
        }
    }

    private func sqrtq(_ x: [Float]) -> [Float] {
      var results = [Float](repeating: 0.0, count: x.count)
      vvsqrtf(&results, x, [Int32(x.count)])
      return results
    }

    /**
     * FFT implementation from: https://deezer.io/real-time-music-visualization-on-the-iphone-gpu-579d631272d3
     */
    private func performFFT(buffer: AVAudioPCMBuffer) {
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

    private func reset() {
        player = nil
        let tempDirURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        fileURL = tempDirURL.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
    }

    private func prepareToPlay() throws {
        player = try AVAudioPlayer(contentsOf: fileURL)
        recordingLength = player?.duration ?? 0
        player?.delegate = self
        player?.prepareToPlay()
        player?.volume = 1
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
}

class TranscriberStreamingClientDelegate: NSObject, AWSTranscribeStreamingClientDelegate {
    var receiveEventCallback: ((AWSTranscribeStreamingTranscriptResultStream?, Error?) -> Void)?
    var connectionStatusCallback: ((AWSTranscribeStreamingClientConnectionStatus, Error?) -> Void)?

    func didReceiveEvent(_ event: AWSTranscribeStreamingTranscriptResultStream?, decodingError: Error?) {
        receiveEventCallback?(event, decodingError)
    }

    func connectionStatusDidChange(_ connectionStatus: AWSTranscribeStreamingClientConnectionStatus,
                                   withError error: Error?) {
        connectionStatusCallback?(connectionStatus, error)
    }
}
