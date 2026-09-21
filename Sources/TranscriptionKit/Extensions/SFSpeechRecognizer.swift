//
//  SFSpeechRecognizer.swift
//  TranscriptionKit
//
//  Created by Francis Li on 9/21/26.
//

import Speech

extension SFSpeechRecognizer {
    static func hasAuthorizationToRecognize() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}
