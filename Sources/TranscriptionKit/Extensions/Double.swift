//
//  Double.swift
//  TranscriptionKit
//
//  Created by Francis Li on 9/18/26.
//

import Foundation

extension Double {
    public func asTimeIntervalString() -> String {
        if self > 3600 {
            return String(format: "%02.0f:%02.0f:%02.0f",
                          self / 3600, self / 60, self.truncatingRemainder(dividingBy: 60))
        }
        return String(format: "%02.0f:%02.0f",
                      self / 60, self.truncatingRemainder(dividingBy: 60))
    }
}
