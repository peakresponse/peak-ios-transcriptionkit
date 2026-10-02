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
    func recognizerDidRecognize(_ recognizer: Recognizer, text: String, transcriptId: String, metadata: [String: Any], isFinal: Bool)
    func recognizerDidFinish(_ recognizer: Recognizer, error: Error?)
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
