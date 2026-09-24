//
//  AVAudioSession+Extensions.swift
//  TranscriptionKit
//
//  Created by Francis Li on 9/18/26.
//

import AVFoundation

extension AVAudioSession {
    static func hasPermissionToRecord() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { authorized in
                    continuation.resume(returning: authorized)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { authorized in
                    continuation.resume(returning: authorized)
                }
            }
        }
    }
}
