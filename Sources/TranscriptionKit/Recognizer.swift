//
//  Recognizer.swift
//  TranscriptionKit
//
//  Created by Francis Li on 1/28/22.
//

import AVFoundation
import Foundation
import Speech

public enum RecognizerAuthorizationStatus: Int {
    case granted, denied, restricted, unknown
}

public enum RecognizerError: Error {
    case unauthorized, unexpected, unsupported
}

@MainActor public protocol RecognizerDelegate: AnyObject {
    func recognizer(_ recognizer: Recognizer, didRecognizeText text: String, transcriptId: String, metadata: [String: Any], isFinal: Bool)
    func recognizer(_ recognizer: Recognizer, didFinishWithError error: Error?)
    func recognizerDidRequestAuthorization(_ recognizer: Recognizer, status: TranscriberAuthorizationStatus)
}

public protocol Recognizer: Actor {
    @MainActor var delegate: RecognizerDelegate? { get set }
    @MainActor var isAuthorized: Bool { get }
    @MainActor func requestAuthorization()
    @MainActor func startTranscribing()
    @MainActor func stopTranscribing()
    func append(wrappedBuffer: SendableAVAudioPCMBuffer)
}
