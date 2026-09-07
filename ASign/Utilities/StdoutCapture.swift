//
//  StdoutCapture.swift
//  ASign
//
//  Captures anything written to stdout/stderr at the fd level (zsign and the
//  other C components log through printf) and re-broadcasts it as
//  notifications the Logs screen can render.
//

import Foundation

final class StdoutCapture {
    static let shared = StdoutCapture()

    static let outputNotification = Notification.Name("asign.stdoutOutput")

    private var _pipeFD: Int32 = -1
    private var _originalStdout: Int32 = -1
    private var _originalStderr: Int32 = -1
    private var _source: DispatchSourceRead?
    private let _queue = DispatchQueue(label: "com.asign.signer.stdout-capture")
    private var _buffer = Data()
    private var _isCapturing = false

    private init() {}

    func start() {
        guard !_isCapturing else { return }
        _isCapturing = true

        let pipe = Pipe()
        _originalStdout = dup(STDOUT_FILENO)
        _originalStderr = dup(STDERR_FILENO)

        fflush(stdout)
        fflush(stderr)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        setvbuf(stdout, nil, _IONBF, 0)

        _pipeFD = pipe.fileHandleForReading.fileDescriptor
        let source = DispatchSource.makeReadSource(
            fileDescriptor: _pipeFD,
            queue: _queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let read = read(self._pipeFD, &chunk, chunk.count)
            guard read > 0 else { return }
            self._buffer.append(contentsOf: chunk[0..<read])

            // Split complete lines and forward them.
            while let newline = self._buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = self._buffer.subdata(in: self._buffer.startIndex..<newline)
                self._buffer.removeSubrange(self._buffer.startIndex...newline)
                if
                    let line = String(data: lineData, encoding: .utf8),
                    !line.isEmpty
                {
                    NotificationCenter.default.post(
                        name: Self.outputNotification,
                        object: nil,
                        userInfo: ["line": line]
                    )
                }
            }
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            close(self._pipeFD)
            self._pipeFD = -1
        }
        source.resume()
        _source = source
    }

    func stop() {
        guard _isCapturing else { return }
        _isCapturing = false

        fflush(stdout)
        fflush(stderr)
        if _originalStdout >= 0 { dup2(_originalStdout, STDOUT_FILENO) }
        if _originalStderr >= 0 { dup2(_originalStderr, STDERR_FILENO) }
        _source?.cancel()
        _source = nil
        close(_originalStdout)
        close(_originalStderr)
        _originalStdout = -1
        _originalStderr = -1
    }
}
