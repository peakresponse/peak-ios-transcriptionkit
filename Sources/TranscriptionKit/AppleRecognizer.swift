//
//  AppleRecognizer.swift
//  TranscriptionKit
//
//  Created by Francis Li on 1/28/22.
//

import Foundation
import Speech

public actor AppleRecognizer: Recognizer {
    @MainActor public weak var delegate: RecognizerDelegate?
    @MainActor public var requiresOnDeviceRecognition = false

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    public init() {        
    }

    @MainActor public var isAuthorized: Bool {
        return SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    @MainActor public func requestAuthorization() {
        Task {
            let status = await SFSpeechRecognizer.hasAuthorizationToRecognize()
            switch status {
            case .authorized:
                delegate?.recognizerDidRequestAuthorization(self, status: .granted)
            case .denied:
                delegate?.recognizerDidRequestAuthorization(self, status: .denied)
            case .restricted:
                delegate?.recognizerDidRequestAuthorization(self, status: .restricted)
            default:
                delegate?.recognizerDidRequestAuthorization(self, status: .unknown)
            }
        }
    }

    @MainActor public func startTranscribing() {
        Task {
            await start(requiresOnDeviceRecognition)
        }
    }

    private func start(_ requiresOnDeviceRecognition: Bool) async {
        do {
            let status = await SFSpeechRecognizer.hasAuthorizationToRecognize()
            guard status == .authorized else { throw RecognizerError.unauthorized }
            speechRecognizer = SFSpeechRecognizer()
            guard let speechRecognizer, speechRecognizer.isAvailable else { throw RecognizerError.unsupported }
            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest else { throw RecognizerError.unexpected }
            recognitionRequest.shouldReportPartialResults = true
            recognitionRequest.requiresOnDeviceRecognition = requiresOnDeviceRecognition
            recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] (result, error) in
                var isFinal = false

                if let result = result {
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
                    let transcriptId = UUID().uuidString
                    let metadata: [String: Any] = [
                        "type": "SPEECH",
                        "provider": "APPLE",
                        "segments": segmentsMetadata
                    ]
                    if let self {
                        let copyIsFinal = isFinal
                        Task { @MainActor in
                            self.delegate?.recognizer(self, didRecognizeText: text, transcriptId: transcriptId,
                                                      metadata: metadata, isFinal: copyIsFinal)
                        }
                    }
                }

                if error != nil || isFinal {
                    // Stop recognizing speech if there is a problem or done
                    Task {
                        await self?.stop()
                        if let self {
                            Task { @MainActor in
                                self.delegate?.recognizer(self, didFinishWithError: error)
                            }
                        }
                    }
                }
            }
        } catch {
            print(error)
        }
    }

    @MainActor public func stopTranscribing() {
        Task {
            await stop()
        }
    }

    private func stop() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        speechRecognizer = nil
    }

    public func append(wrappedBuffer: SendableAVAudioPCMBuffer) {
        recognitionRequest?.append(wrappedBuffer.buffer)
    }
}
