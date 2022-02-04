//
//  AWSRecognizer.swift
//  TranscriptionKit
//
//  Created by Francis Li on 1/28/22.
//

import AVFoundation
import AWSTranscribeStreaming
import Foundation
import Speech

class AWSRecognizerClientDelegate: NSObject, AWSTranscribeStreamingClientDelegate {
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

public class AWSRecognizer: NSObject, Recognizer {
    public weak var delegate: RecognizerDelegate?

    var accessKey: String
    var secretKey: String
    var sessionToken: String?
    var region: AWSRegionType
    var client: AWSTranscribeStreaming?

    var isStarted = false
    var isFinal = false
    var fullTranscript = ""
    var fullTranscriptSegmentsMetadata: [[String: Any]] = []

    public init(accessKey: String, secretKey: String, sessionToken: String? = nil, region: AWSRegionType) {
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.sessionToken = sessionToken
        self.region = region
        super.init()
    }

    public func isAuthorized() -> Bool {
        return true
    }

    public func requestAuthorization(_ handler: @escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) {
        handler(.authorized)
    }

    public func startTranscribing(_ handler: @escaping () -> Void) throws {
        var credentialsProvider: AWSCredentialsProvider
        if let sessionToken = sessionToken {
            credentialsProvider = AWSBasicSessionCredentialsProvider(accessKey: accessKey, secretKey: secretKey, sessionToken: sessionToken)
        } else {
            credentialsProvider = AWSStaticCredentialsProvider(accessKey: accessKey, secretKey: secretKey)
        }
        let configuration = AWSServiceConfiguration(region: region, credentialsProvider: credentialsProvider)
        AWSServiceManager.default().defaultServiceConfiguration = configuration

        guard let config = AWSServiceManager.default().defaultServiceConfiguration else { throw TranscriberError.unexpected }

        AWSTranscribeStreaming.register(with: config, forKey: accessKey)
        client = AWSTranscribeStreaming(forKey: accessKey)
        guard client != nil else { throw TranscriberError.unexpected }
        let delegate = AWSRecognizerClientDelegate()
        delegate.connectionStatusCallback = { (status, error) in
            if status == .connected {
                DispatchQueue.main.async {
                    handler()
                }
            }
            if status == .closed {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.recognizer(self, didFinishWithError: error)
                }
            }
        }
        delegate.receiveEventCallback = { [weak self] (event, error) in
            self?.didReceiveEvent(event, decodingError: error)
        }
        client?.setDelegate(delegate, callbackQueue: DispatchQueue.global())

        guard let request = AWSTranscribeStreamingStartStreamTranscriptionRequest() else { throw TranscriberError.unexpected }
        request.languageCode = .enUS
        request.mediaEncoding = .pcm
        request.mediaSampleRateHertz = 16000

        isStarted = true
        isFinal = false
        fullTranscript = ""
        fullTranscriptSegmentsMetadata = []

        client?.startTranscriptionWSS(request)
    }

    // swiftlint:disable:next function_body_length
    public func append(inputNode: AVAudioInputNode, buffer: AVAudioPCMBuffer) {
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard let convertFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                sampleRate: Double(16000), channels: 1, interleaved: true) else { return }
        let convertedBuffer = AVAudioPCMBuffer(pcmFormat: convertFormat,
                                               frameCapacity: AVAudioFrameCount(convertFormat.sampleRate) *
                                                buffer.frameLength /
                                                AVAudioFrameCount(buffer.format.sampleRate))!

        guard let converter = AVAudioConverter(from: recordingFormat, to: convertFormat) else { return }
        var newBufferAvailable = true
        let inputCallback: AVAudioConverterInputBlock = { (_, outStatus) in
            if newBufferAvailable {
                outStatus.pointee = .haveData
                newBufferAvailable = false
                return buffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }
        var error: NSError?
        converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputCallback)

        guard error == nil else {
            print(error?.localizedDescription ?? "")
            return
        }
        let headers = [
            ":content-type": "audio/wav",
            ":message-type": "event",
            ":event-type": "AudioEvent"
        ]

        let audioBuffer = convertedBuffer.audioBufferList.pointee.mBuffers
        guard let mData = audioBuffer.mData else { return }
        let length = Int(audioBuffer.mDataByteSize)
        let dataChunk: Data = Data(bytes: mData, count: length)

        let chunkSize = 4096
        let audioDataSize = dataChunk.count

        var currentStart = 0
        var currentEnd = min(chunkSize, audioDataSize - currentStart)

        while currentStart < audioDataSize {
            let dataChunk = dataChunk[currentStart ..< currentEnd]
            client?.send(dataChunk, headers: headers)

            currentStart = currentEnd
            currentEnd = min(currentStart + chunkSize, audioDataSize)
        }
    }

    public func stopTranscribing() {
        isStarted = false
        client?.sendEndFrame()
        if isFinal {
            client?.endTranscription()
        }
    }

    // MARK: - AWSTranscribeStreamingClientDelegate

    // swiftlint:disable:next function_body_length
    func didReceiveEvent(_ event: AWSTranscribeStreamingTranscriptResultStream?, decodingError: Error?) {
        if let decodingError = decodingError {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.client?.endTranscription()
                self.delegate?.recognizer(self, didFinishWithError: decodingError)
            }
            return
        }

        guard let transcriptResults = event?.transcriptEvent?.transcript?.results, !transcriptResults.isEmpty else {
            return
        }

        var isFinal = true
        var text = ""
        var segmentsMetadata: [[String: Any]] = []
        for transcriptResult in transcriptResults {
            isFinal = isFinal && !(transcriptResult.isPartial as? Bool ?? true)
            if let alternative = transcriptResult.alternatives?.first {
                let transcript = alternative.transcript ?? ""
                var index = transcript.startIndex
                alternative.items?.forEach { (item) in
                    if let content = item.content,
                       let range = transcript.range(of: content, options: [], range: index..<transcript.endIndex, locale: nil),
                       let startTime = item.startTime, let endTime = item.endTime {
                        let segmentMetadata: [String: Any] = [
                            "substring": content,
                            "substringRange": [
                                "location": transcript.distance(from: transcript.startIndex, to: range.lowerBound),
                                "length": content.count
                            ],
                            "timestamp": startTime.doubleValue,
                            "duration": endTime.doubleValue - startTime.doubleValue
                        ]
                        segmentsMetadata.append(segmentMetadata)
                        index = range.upperBound
                    }
                }
                text = "\(text) \(transcript)".trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // convert the transcription segments into a metadata payload
        let sourceId = UUID().uuidString
        let metadata: [String: Any] = [
            "type": "SPEECH",
            "provider": "AWS",
            "segments": fullTranscriptSegmentsMetadata + segmentsMetadata
        ]
        delegate?.recognizer(self, didRecognizeText: "\(fullTranscript) \(text)".trimmingCharacters(in: .whitespacesAndNewlines),
                             sourceId: sourceId, metadata: metadata, isFinal: !isStarted && isFinal)
        if isFinal {
            fullTranscript = "\(fullTranscript) \(text)".trimmingCharacters(in: .whitespacesAndNewlines)
            fullTranscriptSegmentsMetadata.append(contentsOf: segmentsMetadata)
            if !isStarted {
                client?.endTranscription()
            }
        }
        self.isFinal = isFinal
    }
}
