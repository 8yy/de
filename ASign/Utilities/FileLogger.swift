//
//  FileLogger.swift
//  ASign
//
//  A small rotating on-disk log (2 MB, single file) exposed through the
//  Files tab and the Web Manager. OSLog cannot be read back at runtime, so
//  anything that must survive a crash goes through here.
//

import Foundation

final class FileLogger {
    static let shared = FileLogger()

    private static let _maxBytes = 2 * 1024 * 1024
    private static let _fileName = "asign.log"

    private let _queue = DispatchQueue(label: "com.asign.signer.file-logger")
    private var _url: URL {
        URL.documentsDirectory.appendingPathComponent("Logs").appendingPathComponent(Self._fileName)
    }

    private init() {
        _queue.async {
            try? FileManager.default.createDirectoryIfNeeded(
                at: URL.documentsDirectory.appendingPathComponent("Logs")
            )
        }
    }

    func log(_ message: String) {
        _queue.async { [weak self] in
            guard let self else { return }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            let line = "[\(formatter.string(from: Date()))] \(message)\n"

            let url = self._url
            if let existing = try? Data(contentsOf: url), existing.count > Self._maxBytes {
                // Rotate: keep the tail half.
                let keep = existing.suffix(Self._maxBytes / 2)
                try? keep.write(to: url, options: .atomic)
            }

            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url, options: .atomic)
            }
        }
    }

    func read() -> String {
        _queue.sync {
            (try? String(contentsOf: _url, encoding: .utf8)) ?? ""
        }
    }

    func clear() {
        _queue.async {
            try? FileManager.default.removeItem(at: self._url)
        }
    }

    var fileURL: URL {
        _url
    }
}
