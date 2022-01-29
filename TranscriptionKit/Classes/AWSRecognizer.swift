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
    var region: AWSRegionType
    var client: AWSTranscribeStreaming?

    public init(accessKey: String, secretKey: String, region: AWSRegionType) {
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.region = region
        super.init()
    }

    public func isAuthorized() -> Bool {
        return true
    }

    public func requestAuthorization(_ handler: @escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) {
        handler(.authorized)
    }

    public func startTranscribing(_ handler: @escaping () -> Void) {
        let credentialsProvider = AWSStaticCredentialsProvider(accessKey: accessKey, secretKey: secretKey)
        let configuration = AWSServiceConfiguration(region: region, credentialsProvider: credentialsProvider)
        AWSServiceManager.default().defaultServiceConfiguration = configuration

        guard let config = AWSServiceManager.default().defaultServiceConfiguration else {
            fatalError("Can't get default service configuration")
        }

        AWSTranscribeStreaming.register(with: config, forKey: accessKey)
        client = AWSTranscribeStreaming(forKey: accessKey)

        let delegate = AWSRecognizerClientDelegate()
        delegate.connectionStatusCallback = { (status, error) in
            if status == .connected {
                DispatchQueue.main.async {
                    print("Connected")
                    handler()
                }
            }
            if status == .closed && error == nil {
                DispatchQueue.main.async {
                    print("Disconnected")
                }
            }
        }
        delegate.receiveEventCallback = { [weak self] (event, error) in
            self?.didReceiveEvent(event, decodingError: error)
        }
        client?.setDelegate(delegate, callbackQueue: DispatchQueue.global())

        guard let request = AWSTranscribeStreamingStartStreamTranscriptionRequest() else {
            fatalError("request unexpectedly nil")
        }
        request.languageCode = .enUS
        request.mediaEncoding = .pcm
        request.mediaSampleRateHertz = 16000

        client?.startTranscriptionWSS(request)
    }

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
        client?.sendEndFrame()
        client?.endTranscription()
    }

    // MARK: - AWSTranscribeStreamingClientDelegate

    func didReceiveEvent(_ event: AWSTranscribeStreamingTranscriptResultStream?, decodingError: Error?) {
        if let error = decodingError {
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
                let content = alternative.items?.map({ $0.content ?? "" }).joined(separator: " ")
                print("stream content: \(content ?? "")")

                alternative.items?.forEach({ item in
//                        print("final content: \(item.content ?? "")")
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
        delegate?.recognizer(self, didRecognizeText: text,
                                  sourceId: sourceId, metadata: metadata, isFinal: isFinal)

        if /*error != nil ||*/ isFinal {
            DispatchQueue.main.async {
                print("Ending transcription")
                self.client?.endTranscription()
            }
            delegate?.recognizer(self, didFinishWithError: nil)
        }
    }
}
