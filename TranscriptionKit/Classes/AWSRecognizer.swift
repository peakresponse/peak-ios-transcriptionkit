//
//  AWSRecognizer.swift
//  TranscriptionKit
//
//  Created by Francis Li on 1/28/22.
//

import AVFoundation
import Foundation
import Speech

public class AWSRecognizer: NSObject, Recognizer {
    public weak var delegate: RecognizerDelegate?

    public func isAuthorized() -> Bool {
        return true
    }

    public func requestAuthorization(_ handler: @escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) {
        handler(.authorized)
    }

    public func startTranscribing() {

    }

    public func append(_ buffer: AVAudioPCMBuffer) {

    }

    public func stopTranscribing() {

    }
}
