//
//  Date+Extensions.swift
//  Triage
//
//  Created by Francis Li on 3/16/20.
//  Copyright © 2020 Francis Li. All rights reserved.
//

import Foundation

extension Date {
    func dist(to other: Date) -> TimeInterval {
        if #available(iOS 13.0, *) {
            return distance(to: other)
        } else {
            return other.timeIntervalSinceReferenceDate - timeIntervalSinceReferenceDate
        }
    }
}
