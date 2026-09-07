//
//  Int+Formatted.swift
//  NimbleKit
//
//  Created by samsam on 7/26/25.
//

import Foundation

extension Int64 {
        public var formattedByteCount: String {
                let formatter = ByteCountFormatter()
                formatter.allowedUnits = [.useAll]
                formatter.countStyle = .file
                return formatter.string(fromByteCount: self)
        }
}

extension Double {
        /// Transfer rate in bytes/second, rendered as e.g. "1.4 MB/s".
        public var formattedSpeed: String {
                let formatter = ByteCountFormatter()
                formatter.allowedUnits = [.useAll]
                formatter.countStyle = .file
                return "\(formatter.string(fromByteCount: Int64(self)))/s"
        }

        /// Estimated time remaining for the given remaining byte count.
        public func formattedEta(remainingBytes: Int64) -> String? {
                guard self > 0, remainingBytes > 0 else { return nil }
                let seconds = Int((Double(remainingBytes) / self).rounded())
                if seconds < 60 { return "\(seconds)s" }
                if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
                return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
        }
}
