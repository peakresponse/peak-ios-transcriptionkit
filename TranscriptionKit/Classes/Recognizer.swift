//
//  Recognizer.swift
//  TranscriptionKit
//
//  Created by Francis Li on 1/28/22.
//

import AVFoundation
import Foundation
import Speech

public protocol RecognizerDelegate: AnyObject {
    func recognizer(_ recognizer: Recognizer, didRecognizeText text: String, transcriptId: String, metadata: [String: Any], isFinal: Bool)
    func recognizer(_ recognizer: Recognizer, didFinishWithError error: Error?)
}

public protocol Recognizer: AnyObject {
    var delegate: RecognizerDelegate? { get set }
    func isAuthorized() -> Bool
    func requestAuthorization(_ handler: @escaping (SFSpeechRecognizerAuthorizationStatus) -> Void)
    func startTranscribing(_ handler: @escaping () -> Void) throws
    func append(recordingFormat: AVAudioFormat, buffer: AVAudioPCMBuffer)
    func stopTranscribing()
}
