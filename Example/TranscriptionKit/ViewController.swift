//
//  ViewController.swift
//  TranscriptionKit
//
//  Created by Francis Li on 06/09/2021.
//  Copyright (c) 2021 Francis Li. All rights reserved.
//

import AVFoundation
import Speech
import TranscriptionKit
import Keys
import UIKit

class ViewController: UIViewController, TranscriberDelegate {
    @IBOutlet weak var recordButton: UIButton!
    @IBOutlet weak var btButton: UIButton!
    @IBOutlet weak var playButton: UIButton!
    @IBOutlet weak var transcriptLabel: UILabel!
    @IBOutlet weak var timeLabel: UILabel!

    var transcriber: Transcriber?
    var audioInputPortUID: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }

    func present(error: Error) {
        let alert = UIAlertController(title: "Error", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel, handler: nil))
        present(alert, animated: true, completion: nil)
    }

    @IBAction func recordPressed(_ sender: Any) {
        if let transcriber = transcriber, recordButton.isSelected {
            // disable everything until recognition finalized
            playButton.isEnabled = false
            recordButton.isEnabled = false
            btButton.isEnabled = false
            // stop
            recordButton.isSelected = false
            transcriber.stopRecording()
            return
        }

        recordButton.isSelected = true
        playButton.isEnabled = false
        transcriptLabel.text = nil
        timeLabel.text = nil

        transcriber = Transcriber()
//        transcriber?.recognizer = AppleRecognizer()
        let keys = TranscriptionKitKeys()
        transcriber?.recognizer = AWSRecognizer(accessKey: keys.awsTranscribeAccessKeyId,
                                                secretKey: keys.awsTranscribeSecretAccessKey,
                                                region: .USWest2)
        transcriber?.audioInputPortUID = audioInputPortUID
        transcriber?.delegate = self
        do {
            try transcriber?.startRecording()
        } catch {
            present(error: error)
            recordButton.isSelected = false
        }
    }

    @IBAction func btPressed(_ sender: Any) {
        if btButton.isSelected {
            btButton.isSelected = false
            audioInputPortUID = nil
            transcriber?.audioInputPortUID = nil
        } else {
            let bluetoothHFPInputs = Transcriber.bluetoothHFPInputs
            if bluetoothHFPInputs.count == 0 {
                let alert = UIAlertController(title: "Bluetooth", message: "No Bluetooth devices detected", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .cancel, handler: nil))
                present(alert, animated: true, completion: nil)
            } else if bluetoothHFPInputs.count == 1 {
                audioInputPortUID = bluetoothHFPInputs[0].uid
                transcriber?.audioInputPortUID = audioInputPortUID
                btButton.isSelected = true
            } else if bluetoothHFPInputs.count > 1 {
                let alert = UIAlertController(title: "Bluetooth", message: nil, preferredStyle: .actionSheet)
                for bluetoothHFPInput in bluetoothHFPInputs {
                    alert.addAction(UIAlertAction(title: bluetoothHFPInput.portName, style: .default, handler: { [weak self] (_) in
                        guard let self = self else { return }
                        self.audioInputPortUID = bluetoothHFPInput.uid
                        self.transcriber?.audioInputPortUID = self.audioInputPortUID
                        self.btButton.isSelected = true
                    }))
                }
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
                present(alert, animated: true, completion: nil)
            }
        }
    }

    @IBAction func playPressed(_ sender: Any) {
        if let transcriber = transcriber, playButton.isSelected {
            transcriber.stopPressed()
            playButton.isSelected = false
            return
        }

        playButton.isSelected = true
        timeLabel.text = nil
        do {
            try transcriber?.playPressed()
        } catch {
            present(error: error)
            playButton.isSelected = false
        }
    }

    // MARK: - TranscriberDelegate

    func transcriberDidFinishRecognition(_ transcriber: Transcriber, withError error: Error?) {
        playButton.isEnabled = true
        recordButton.isEnabled = true
        btButton.isEnabled = true
    }

    func transcriber(_ transcriber: Transcriber, didFinishPlaying successfully: Bool) {
        playButton.isSelected = false
    }

    func transcriber(_ transcriber: Transcriber, didTransformBuffer data: [Float]) {

    }

    func transcriber(_ transcriber: Transcriber, didRequestSpeechAuthorization status: TranscriberAuthorizationStatus) {
        switch status {
        case .granted:
            do {
                try transcriber.startRecording()
            } catch {
                present(error: error)
            }
        case .denied:
            present(error: TranscriberError.speechRecognitionNotAuthorized)
            recordButton.isSelected = false
        case .restricted:
            present(error: TranscriberError.speechRecognitionRestricted)
            recordButton.isSelected = false
        default:
            present(error: TranscriberError.unexpected)
            recordButton.isSelected = false
        }
    }

    func transcriber(_ transcriber: Transcriber, didRequestRecordAuthorization status: TranscriberAuthorizationStatus) {
        switch status {
        case .granted:
            do {
                try transcriber.startRecording()
            } catch {
                present(error: error)
            }
        case .denied:
            present(error: TranscriberError.recordNotAuthorized)
            recordButton.isSelected = false
        default:
            present(error: TranscriberError.unexpected)
            recordButton.isSelected = false
        }
    }

    func transcriber(_ transcriber: Transcriber, didPlay seconds: TimeInterval, formattedDuration duration: String) {
        DispatchQueue.main.async { [weak self] in
            self?.timeLabel.text = duration
        }
    }

    func transcriber(_ transcriber: Transcriber, didRecord seconds: TimeInterval, formattedDuration duration: String) {
        DispatchQueue.main.async { [weak self] in
            self?.timeLabel.text = duration
        }
    }

    func transcriber(_ transcriber: Transcriber, didRecognizeText text: String, sourceId: String, metadata: [String: Any], isFinal: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.transcriptLabel.text = text
        }
    }
}
