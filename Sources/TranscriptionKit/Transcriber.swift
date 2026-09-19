//
//  Transcriber.swift
//  TranscriptionKit
//
//  Created by Francis Li on 11/14/19.
//  Copyright © 2019 Francis Li. All rights reserved.
//

import Accelerate
import AVFoundation
import Speech

public enum TranscriberAuthorizationStatus: Int {
    case granted, denied, restricted, unknown
}

public enum TranscriberError: Error {
    case recordNotAuthorized
    case speechRecognitionNotAuthorized
    case speechRecognitionRestricted
    case unexpected
}

public protocol TranscriberDelegate: AnyObject {
    func transcriber(_ transcriber: Transcriber, didPlay seconds: TimeInterval)
    func transcriberDidFinishPlaying(_ transcriber: Transcriber, successfully: Bool, error: Error?)

    func transcriberDidFailToRecord(_ transcriber: Transcriber, error: Error)
    func transcriberDidRequestRecordAuthorization(_ transcriber: Transcriber, status: TranscriberAuthorizationStatus)
    func transcriberDidRecord(_ transcriber: Transcriber, seconds: TimeInterval, data: [Float])
    func transcriberDidFinishRecording(_ transcriber: Transcriber, duration seconds: TimeInterval)

    // swiftlint:disable:next function_parameter_count
    func transcriber(_ transcriber: Transcriber, didRequestSpeechAuthorization status: TranscriberAuthorizationStatus)
    func transcriber(_ transcriber: Transcriber, didRecognizeText text: String, fileId: String,
                     transcriptId: String, metadata: [String: Any], isFinal: Bool)
    func transcriberDidFinishRecognition(_ transcriber: Transcriber, withError error: Error?)
}

extension TranscriberDelegate {
    public func transcriber(_ transcriber: Transcriber, didPlay seconds: TimeInterval) { }
    public func transcriberDidFinishPlaying(_ transcriber: Transcriber, successfully: Bool, error: Error?) { }

    public func transcriberDidFailToRecord(_ transcriber: Transcriber, error: Error) { }
    public func transcriberDidRequestRecordAuthorization(_ transcriber: Transcriber, status: TranscriberAuthorizationStatus) { }
    public func transcriberDidRecord(_ transcriber: Transcriber, seconds: TimeInterval, data: [Float]) { }
    public func transcriberDidTransformBuffer(_ transcriber: Transcriber, data: [Float]) { }
    public func transcriberDidFinishRecording(_ transcriber: Transcriber, duration seconds: TimeInterval) { }

    // swiftlint:disable:next function_parameter_count
    public func transcriber(_ transcriber: Transcriber, didRequestSpeechAuthorization status: TranscriberAuthorizationStatus) { }
    public func transcriber(_ transcriber: Transcriber, didRecognizeText text: String, fileId: String,
                            transcriptId: String, metadata: [String: Any], isFinal: Bool) { }
    public func transcriberDidFinishRecognition(_ transcriber: Transcriber, withError error: Error?) { }
}

@MainActor
public class Transcriber: NSObject, AVAudioPlayerDelegate, @MainActor RecognizerDelegate, RecorderDelegate {
    public var fileId: String!
    public var fileURL: URL!
    public private(set) var recordingLength: TimeInterval = 0

    private var timer: Timer?

    public var recognizer: Recognizer? {
        didSet { recognizer?.delegate = self }
    }

    private var recorder = Recorder()

    private var player: AVAudioPlayer?
    public var isPlaying: Bool {
        return player?.isPlaying ?? false
    }

    public var audioInputPortUID: String?
    public weak var delegate: TranscriberDelegate?

    public static var bluetoothHFPInputs: [AVAudioSessionPortDescription] {
        get throws {
            return try Recorder.bluetoothHFPInputs
        }
    }

    public override init() {
        super.init()
        recorder.delegate = self
        reset()
    }

    public func reset() {
        player = nil
        let tempDirURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        fileId = UUID().uuidString
        fileURL = tempDirURL.appendingPathComponent(fileId).appendingPathExtension("mp4")
    }

    public func preparePlayback() throws {
        player = try AVAudioPlayer(contentsOf: fileURL)
        recordingLength = player?.duration ?? 0
        player?.delegate = self
        player?.prepareToPlay()
        player?.volume = 1
    }

    public func startPlayback() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        if player == nil {
            try preparePlayback()
        }
        player?.play()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { (_) in
            Task { @MainActor in
                if let seconds = self.player?.currentTime {
                    self.delegate?.transcriber(self, didPlay: seconds)
                }
            }
        }
    }

    public func stopPlayback() {
        player?.stop()
        player = nil
        timer?.invalidate()
        timer = nil
    }

    public func startRecording() throws {
        recorder.startRecording(fileURL: fileURL)
    }

    public func stopRecording() {
        recorder.stopRecording()
    }

    // MARK: - AVAudioPlayerDelegate

    public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        delegate?.transcriberDidFinishPlaying(self, successfully: false, error: error)
    }

    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        delegate?.transcriberDidFinishPlaying(self, successfully: flag, error: nil)
    }

    // MARK: - RecognizerDelegate

    public func recognizer(_ recognizer: Recognizer,
                           didRecognizeText text: String, transcriptId: String, metadata: [String: Any], isFinal: Bool) {
        delegate?.transcriber(self, didRecognizeText: text, fileId: fileId, transcriptId: transcriptId,
                               metadata: metadata, isFinal: isFinal)
    }

    public func recognizer(_ recognizer: Recognizer, didFinishWithError error: Error?) {
        delegate?.transcriberDidFinishRecognition(self, withError: error)
    }

    // MARK: - RecorderDelegate

    public func recorderDidRecord(_ recorder: Recorder, wrappedBuffer: SendableAVAudioPCMBuffer, normalizedData: [Float], seconds: TimeInterval) {
        delegate?.transcriberDidRecord(self, seconds: seconds, data: normalizedData)
    }

    public func recorderDidFailToRecord(_ recorder: Recorder, error: any Error) {
        delegate?.transcriberDidFailToRecord(self, error: error)
    }

    public func recorderDidFinishRecording(_ recorder: Recorder, duration: TimeInterval) {
        delegate?.transcriberDidFinishRecording(self, duration: duration)
    }
}
