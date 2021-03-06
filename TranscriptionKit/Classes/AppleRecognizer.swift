//
//  AppleRecognizer.swift
//  TranscriptionKit
//
//  Created by Francis Li on 1/28/22.
//

import Foundation
import Speech

public class AppleRecognizer: NSObject, Recognizer {
    public weak var delegate: RecognizerDelegate?

    let speechRecognizer = SFSpeechRecognizer()
    var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    var recognitionTask: SFSpeechRecognitionTask?

    public func isAuthorized() -> Bool {
        return SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    public func requestAuthorization(_ handler: @escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) {
        SFSpeechRecognizer.requestAuthorization(handler)
    }

    public func startTranscribing(_ handler: @escaping () -> Void) throws {
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { throw TranscriberError.unexpected }
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
                let transcriptId = UUID().uuidString
                let metadata: [String: Any] = [
                    "type": "SPEECH",
                    "provider": "APPLE",
                    "segments": segmentsMetadata
                ]
                if let self = self {
                    self.delegate?.recognizer(self, didRecognizeText: text, transcriptId: transcriptId,
                                              metadata: metadata, isFinal: isFinal)
                }
            }

            if error != nil || isFinal {
                // Stop recognizing speech if there is a problem.
                self?.recognitionRequest = nil
                self?.recognitionTask = nil

                if let self = self {
                    self.delegate?.recognizer(self, didFinishWithError: error)
                }
            }
        }
        handler()
    }

    public func append(recordingFormat: AVAudioFormat, buffer: AVAudioPCMBuffer) {
        recognitionRequest?.append(buffer)
    }

    public func stopTranscribing() {
        recognitionRequest?.endAudio()
    }
}
