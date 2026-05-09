//
//  AWSRecognizer.swift
//  TranscriptionKit
//

import AVFoundation
import AWSTranscribeStreaming
import Foundation
import SmithyIdentity
import Speech

public class AWSRecognizer: NSObject, Recognizer, @unchecked Sendable {
    public weak var delegate: RecognizerDelegate?

    private let accessKey: String
    private let secretKey: String
    private let region: String

    private var audioContinuation: AsyncThrowingStream<TranscribeStreamingClientTypes.AudioStream, Error>.Continuation?
    private var audioStream: AsyncThrowingStream<TranscribeStreamingClientTypes.AudioStream, Error>?
    private var streamTask: Task<Void, Never>?

    private var finalText: String = ""
    private var finalItems: [[String: Any]] = []

    public init(accessKey: String, secretKey: String, region: String) {
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.region = region
    }

    public func isAuthorized() -> Bool { true }

    public func requestAuthorization(_ handler: @escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) {
        handler(.authorized)
    }

    public func startTranscribing(_ handler: @escaping () -> Void) throws {
        finalText = ""
        finalItems = []
        audioStream = AsyncThrowingStream { [weak self] continuation in
            self?.audioContinuation = continuation
        }
        handler()
    }

    public func append(recordingFormat: AVAudioFormat, buffer: AVAudioPCMBuffer) {
        if streamTask == nil, let stream = audioStream {
            let sampleRate = Int(recordingFormat.sampleRate)
            let credentialResolver = StaticAWSCredentialIdentityResolver(
                AWSCredentialIdentity(accessKey: accessKey, secret: secretKey)
            )
            let region = self.region
            streamTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let config = try await TranscribeStreamingClient.TranscribeStreamingClientConfig(
                        awsCredentialIdentityResolver: credentialResolver,
                        region: region
                    )
                    let client = TranscribeStreamingClient(config: config)
                    let input = StartStreamTranscriptionInput(
                        audioStream: stream,
                        languageCode: .enUs,
                        mediaEncoding: .pcm,
                        mediaSampleRateHertz: sampleRate
                    )
                    let output = try await client.startStreamTranscription(input: input)
                    guard let resultStream = output.transcriptResultStream else { return }
                    for try await event in resultStream {
                        switch event {
                        case .transcriptevent(let transcriptEvent):
                            for result in transcriptEvent.transcript?.results ?? [] {
                                self.handleResult(result)
                            }
                        default:
                            break
                        }
                    }
                    let delegate = self.delegate
                    await MainActor.run { delegate?.recognizer(self, didFinishWithError: nil) }
                } catch {
                    let delegate = self.delegate
                    await MainActor.run { delegate?.recognizer(self, didFinishWithError: error) }
                }
            }
        }
        guard let data = convertToLinearPCM(buffer: buffer) else { return }
        audioContinuation?.yield(.audioevent(.init(audioChunk: data)))
    }

    public func stopTranscribing() {
        audioContinuation?.finish()
        audioContinuation = nil
        audioStream = nil
    }

    private func handleResult(_ result: TranscribeStreamingClientTypes.Result) {
        let isFinal = !result.isPartial
        let resultText = result.alternatives?.first?.transcript ?? ""
        let transcriptId = result.resultId ?? UUID().uuidString
        var resultItems: [[String: Any]] = []
        for item in result.alternatives?.first?.items ?? [] {
            resultItems.append([
                "content": item.content ?? "",
                "type": item.type?.rawValue ?? "",
                "startTime": item.startTime,
                "endTime": item.endTime,
                "confidence": item.confidence ?? 0.0
            ])
        }
        if isFinal {
            finalText = finalText.isEmpty ? resultText : "\(finalText) \(resultText)"
            finalItems.append(contentsOf: resultItems)
        }
        let completeText = isFinal ? finalText : (finalText.isEmpty ? resultText : "\(finalText) \(resultText)")
        let completeItems = isFinal ? finalItems : finalItems + resultItems
        let metadata: [String: Any] = [
            "type": "SPEECH",
            "provider": "AWS",
            "items": completeItems
        ]
        let delegate = self.delegate
        Task { @MainActor in
            delegate?.recognizer(self, didRecognizeText: completeText, transcriptId: transcriptId,
                                 metadata: metadata, isFinal: isFinal && audioStream == nil)
        }
    }

    private func convertToLinearPCM(buffer: AVAudioPCMBuffer) -> Data? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameLength > 0, channelCount > 0 else { return nil }

        var int16Samples = [Int16](repeating: 0, count: frameLength)
        for frame in 0..<frameLength {
            var sample: Float = 0
            for channel in 0..<channelCount {
                sample += channelData[channel][frame]
            }
            sample /= Float(channelCount)
            let clamped = max(-1.0, min(1.0, sample))
            int16Samples[frame] = Int16(clamped * Float(Int16.max))
        }
        return int16Samples.withUnsafeBytes { Data($0) }
    }
}
