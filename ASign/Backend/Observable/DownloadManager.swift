//
//  enum.swift
//  Feather
//
//  Created by samara on 3.05.2025.
//

import Foundation
import Combine
import UIKit.UIImpactFeedbackGenerator
import SwiftUI // For ByteCountFormatter
import UserNotifications

// Import the error handlers module
@_exported import class UIKit.UIImpactFeedbackGenerator

class Download: Identifiable, @unchecked Sendable, ObservableObject {
        @Published var progress: Double = 0.0
        @Published var bytesDownloaded: Int64 = 0
        @Published var totalBytes: Int64 = 0
        @Published var unpackageProgress: Double = 0.0
        @Published var isPaused = false
        /// Smoothed transfer rate in bytes/second (updated by the manager).
        @Published var speed: Double = 0

        /// Source context recorded when a download originates from a source app,
        /// used by the update engine for provenance and whats-new text.
        struct SourceMeta {
            var bundleID: String?
            var sourceID: String?
            var appName: String?
            var version: String?
            var whatsNew: String?
        }
        var meta: SourceMeta?
        
        var overallProgress: Double {
                onlyArchiving
                ? unpackageProgress
                : (0.3 * unpackageProgress) + (0.7 * progress)
        }

        var formattedFileSize: String {
                return totalBytes.formattedByteCount
        }
        
        var progressText: String {
                if unpackageProgress > 0 {
                        return "\(Int(unpackageProgress * 100))%"
                }
                let downloadedStr = bytesDownloaded.formattedByteCount
                let totalStr = totalBytes.formattedByteCount
                return "\(downloadedStr) / \(totalStr) (\(Int(progress * 100))%)"
        }
    var task: URLSessionDownloadTask?
    var resumeData: Data?
        
        let id: String
        let url: URL
        let fileName: String
        let onlyArchiving: Bool
    
    init(
                id: String,
                url: URL,
                onlyArchiving: Bool = false
        ) {
                self.id = id
        self.url = url
                self.onlyArchiving = onlyArchiving
        self.fileName = url.lastPathComponent
    }
}

class DownloadManager: NSObject, ObservableObject {
        static let shared = DownloadManager()
        
    @Published var downloads: [Download] = []
        
        var manualDownloads: [Download] {
                downloads.filter { isManualDownload($0.id) }
        }

        // MARK: - Bulk import backlog
        //
        // A `Download` only exists once an import has actually started, and the
        // bulk importer deliberately runs two at a time so a big batch doesn't
        // kick off thirty-five extractions at once. That's why the header's "+N"
        // was pinned at "+1": it was counting work in flight, not work left.
        //
        // This is the rest of the batch — selected, but not yet handed a
        // `Download`. Batches are tracked by token rather than as one running
        // total so that starting a second import while the first is still going
        // can't leave a phantom count behind.
        @Published private(set) var queuedImportCount: Int = 0

        private var _importBatches: [UUID: Int] = [:]

        // The size each batch started at. `_importBatches` only holds what's left
        // to *start*, which is enough for the "+N" header but not for a bar — a bar
        // needs a denominator that doesn't shrink as work begins.
        private var _importTotals: [UUID: Int] = [:]

        @MainActor
        func beginImportBatch(count: Int) -> UUID {
                let token = UUID()
                if count > 0 {
                        _importBatches[token] = count
                        _importTotals[token] = count
                }
                _recomputeQueuedImports()
                return token
        }

        // Called the moment an item is dequeued and given a real `Download`, so
        // it moves from "waiting" to "in flight" without ever being counted twice.
        @MainActor
        func importDidStart(_ token: UUID) {
                guard let remaining = _importBatches[token] else { return }
                if remaining <= 1 {
                        _importBatches[token] = nil
                } else {
                        _importBatches[token] = remaining - 1
                }
                _recomputeQueuedImports()
        }

        // Safety net for the batch finishing early — cancellation, or a task that
        // never got to run. Without it the header could sit on a count forever.
        @MainActor
        func endImportBatch(_ token: UUID) {
                guard _importBatches.removeValue(forKey: token) != nil else { return }
                _importTotals.removeValue(forKey: token)
                _recomputeQueuedImports()
        }

        @MainActor
        private func _recomputeQueuedImports() {
                queuedImportCount = _importBatches.values.reduce(0, +)
                _reportImportProgress()
        }

        // Feeds the Dynamic Island bar during a batch import.
        //
        // "Finished" is the total minus what hasn't started yet minus what's
        // running right now — `_importDepth` is exactly the number in flight, so
        // this counts genuinely completed apps rather than started ones. Using
        // started would read 35 of 35 while two were still extracting.
        @MainActor
        private func _reportImportProgress() {
                guard #available(iOS 16.2, *) else { return }

                let total = _importTotals.values.reduce(0, +)

                // Batch fully drained: clear the denominators so the next one starts
                // clean, and withdraw the figure.
                if total == 0 || (_importBatches.isEmpty && _importDepth == 0) {
                        _importTotals.removeAll()
                        KeepAliveActivityController.shared.report(.importing, completed: 0, total: nil)
                        KeepAliveActivityController.shared.report(.importing, detail: nil)
                        return
                }

                let remaining = _importBatches.values.reduce(0, +)
                let completed = max(0, total - remaining - _importDepth)

                KeepAliveActivityController.shared.report(.importing, completed: completed, total: total)
                // The count only moves when an entire IPA finishes. Keep one stable phase
                // label so the widget's elapsed timer continues advancing during a long
                // extraction instead of looking frozen.
                KeepAliveActivityController.shared.report(.importing, detail: "Importing")
        }

        // MARK: - Import-in-progress flag
        //
        // The Downloads screen refreshes its finished list whenever `downloads.count`
        // changes, so a newly finished *download* shows up. But importing also adds
        // and removes entries in this same `downloads` array, so every imported app
        // was triggering that refresh — a full disk rescan and reorder of the list,
        // per app. That's the "jumping around while importing", and the repeated
        // main-thread rescans are what stalled the app long enough for the watchdog
        // to kill it during a bulk import.
        //
        // Importing shouldn't touch that list at all. The view checks `isImporting`
        // and skips its refresh while this is set. It's a depth counter, not a bool,
        // so overlapping imports (or a bulk batch) can't clear it early.
        //
        // @Published so the Downloads screen can *structurally* branch on it, not
        // just consult it inside a callback. While a batch import runs, that screen
        // swaps its live per-app "Downloading" section for a single static row.
        @Published private var _importDepth = 0
        var isImporting: Bool { _importDepth > 0 }

        @MainActor func beginImport() {
                _importDepth += 1
                _reportImportProgress()
        }

        @MainActor func endImport() {
                _importDepth = max(0, _importDepth - 1)
                _reportImportProgress()
        }
        
    private var _session: URLSession!
    
    private func _updateBackgroundAudioState() {
        if #unavailable(iOS 26.0){
            if !downloads.isEmpty {
                BackgroundAudioManager.shared.claim(.downloads)
            } else  {
                BackgroundAudioManager.shared.release(.downloads)
            }
        }
    }
    
    override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        _session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        _observeControlIntents()
    }
    
    // Pause/resume from the Dynamic Island. LiveActivityIntents run in the
    // app's process, so local notifications are the whole bridge.
    private func _observeControlIntents() {
        NotificationCenter.default.addObserver(
            forName: Notification.Name("asign.pauseDownloads"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.pauseAllDownloads()
        }
        
        NotificationCenter.default.addObserver(
            forName: Notification.Name("asign.resumeDownloads"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resumeAllDownloads()
        }
    }
    
    func startDownload(
                from url: URL,
                id: String = UUID().uuidString,
                meta: Download.SourceMeta? = nil
        ) -> Download {
        if let existingDownload = downloads.first(where: { $0.url == url }) {
            resumeDownload(existingDownload)
            return existingDownload
        }
        print(id)
                let download = Download(id: id, url: url)
                download.meta = meta
        
        let task = _session.downloadTask(with: url)
        download.task = task
        task.resume()
        
        downloads.append(download)
                if #available(iOS 26.0, *) {
                        BackgroundTaskManager.shared.startTask(for: id, filename: url.lastPathComponent)
                } else {
                        _updateBackgroundAudioState()
                }
        return download
    }
        
        func startArchive(
                from url: URL,
                id: String = UUID().uuidString
        ) -> Download {
                let download = Download(id: id, url: url, onlyArchiving: true)
                downloads.append(download)
                _updateBackgroundAudioState()
                return download
        }
    
    func resumeDownload(_ download: Download) {
        if let resumeData = download.resumeData {
            let task = _session.downloadTask(withResumeData: resumeData)
            download.task = task
            task.resume()
            download.isPaused = false
            _updateBackgroundAudioState()
        } else if let url = download.task?.originalRequest?.url {
            let task = _session.downloadTask(with: url)
            download.task = task
            task.resume()
            download.isPaused = false
            _updateBackgroundAudioState()
        }
    }
    
    // Pausing uses URLSessionTask suspension: the transfer stops, the socket
    // stays parked, and `resume()` picks up exactly where it left off. This is
    // what backs the Dynamic Island pause control.
    func pauseDownload(_ download: Download) {
        download.task?.suspend()
        download.isPaused = true
        download.speed = 0
        _updateBackgroundAudioState()
        _reportPauseState()
    }
    
    func resumePausedDownload(_ download: Download) {
        download.task?.resume()
        download.isPaused = false
        _updateBackgroundAudioState()
        _reportPauseState()
    }
    
    func pauseAllDownloads() {
        for download in downloads where !download.isPaused {
            pauseDownload(download)
        }
    }
    
    func resumeAllDownloads() {
        for download in downloads where download.isPaused {
            resumePausedDownload(download)
        }
    }
    
    var isAnyPaused: Bool {
        downloads.contains { $0.isPaused }
    }
    
    private func _reportPauseState() {
        guard #available(iOS 16.2, *) else { return }
        KeepAliveActivityController.shared.report(.downloads, isPaused: downloads.isEmpty ? nil : isAnyPaused)
    }
    
    func cancelDownload(_ download: Download) {
        download.task?.cancel()
        
        if let index = downloads.firstIndex(where: { $0.id == download.id }) {
            downloads.remove(at: index)
            _updateBackgroundAudioState()
            if #available(iOS 26.0, *) {
                BackgroundTaskManager.shared.stopTask(for: download.id, success: false)
            }
        }
    }
    
        func isManualDownload(_ string: String) -> Bool {
                return string.contains("FeatherManualDownload")
        }
        
        func getDownload(by id: String) -> Download? {
                return downloads.first(where: { $0.id == id })
        }
        
        func getDownloadIndex(by id: String) -> Int? {
                return downloads.firstIndex(where: { $0.id == id })
        }
        
        func getDownloadTask(by task: URLSessionDownloadTask) -> Download? {
                return downloads.first(where: { $0.task == task })
        }
}

extension DownloadManager: URLSessionDownloadDelegate {
        
        func handlePachageFile(
                url: URL,
                dl: Download?,
                completion: @escaping (Error?) -> Void
        ) {
                FR.handlePackageFile(url, download: dl) { err in
                        if let error = err {
                                let generator = UINotificationFeedbackGenerator()
                                generator.notificationOccurred(.error)
                                print("Package handling error: \(error.localizedDescription)")
                                if let nsError = error as? NSError {
                                        if nsError.domain == NSPOSIXErrorDomain && nsError.code == 28 {
                                                print("No space left on device")
                                        } else if nsError.domain == NSCocoaErrorDomain {
                                                print("Cocoa error: \(nsError.localizedDescription)")
                                        }
                                }
                                let errorString = String(describing: error)
                                if errorString.contains("notEnoughDiskSpace") {
                                        print("Not enough disk space for extraction")
                                } else if errorString.contains("payloadNotFound") {
                                        print("Payload folder not found in archive")
                                }
                        }
                        DispatchQueue.main.async {
                                if let dl = dl, let index = DownloadManager.shared.getDownloadIndex(by: dl.id) {
                                        DownloadManager.shared.downloads.remove(at: index)
                                }
                                if err == nil {
                                        self._notifyDownloadCompleted(fileName: url.lastPathComponent)
                                        self._removeStagedDownload(at: url)
                                        self._recordProvenance(for: dl)
                                }
                                completion(err)
                        }
                }
        }

        func handlePachageFile(url: URL, dl: Download?) async throws {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        self.handlePachageFile(url: url, dl: dl) { err in
                                if let error = err {
                                        continuation.resume(throwing: error)
                                } else {
                                        continuation.resume()
                                }
                        }
                }
        }
        
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
                guard let download = getDownloadTask(by: downloadTask) else { return }
                
                var downloadDir: URL
                if !OptionsManager.shared.options.saveAppStoreDownloadsToDownloadsFolder {
                        let tempDirectory = FileManager.default.temporaryDirectory
                        downloadDir = tempDirectory.appendingPathComponent("FeatherDownloads", isDirectory: true)
                } else {
                        downloadDir = URL.documentsDirectory.appendingPathComponent("Downloads")
                }
                
                do {
                        try FileManager.default.createDirectoryIfNeeded(at: downloadDir)
                        let suggestedFileName = downloadTask.response?.suggestedFilename ?? download.fileName
                        let destinationURL = downloadDir.appendingPathComponent(suggestedFileName)
                        try FileManager.default.removeFileIfNeeded(at: destinationURL)
                        try FileManager.default.moveItem(at: location, to: destinationURL)
                        self.handlePachageFile(url: destinationURL, dl: download) { err in
                                if let error = err {
                                        print("Error handling downloaded file: \(error.localizedDescription)")
                                }
                        }
                } catch {
                        print("Error handling downloaded file: \(error.localizedDescription)")
                }
        }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let download = getDownloadTask(by: downloadTask) else { return }
        
        // Exponentially-weighted speed sampling: weight the newest sample 0.3
        // so a single slow second doesn't make the whole display collapse.
        let now = Date()
        let sample = _speedSampler(for: download).sample(bytes: totalBytesWritten, at: now)
        
        DispatchQueue.main.async {
            download.progress = totalBytesExpectedToWrite > 0
                        ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                        : 0
            download.bytesDownloaded = totalBytesWritten
            download.totalBytes = totalBytesExpectedToWrite
            if let sample {
                download.speed = sample
            }
            
            if #available(iOS 26.0, *) {
                BackgroundTaskManager.shared.updateProgress(for: download.id, progress: download.overallProgress)
            }
            
            if #available(iOS 16.2, *) {
                KeepAliveActivityController.shared.report(.downloads, fraction: download.overallProgress)
                if let sample {
                    KeepAliveActivityController.shared.report(.downloads, speedText: sample.formattedSpeed)
                }
            }
        }
    }
    
    // Sampler state lives per download; the dictionary is only touched on the
    // session delegate queue.
    private var _samplers: [String: SpeedSampler] = [:]
    
    private func _speedSampler(for download: Download) -> SpeedSampler {
        if let sampler = _samplers[download.id] { return sampler }
        let sampler = SpeedSampler()
        _samplers[download.id] = sampler
        return sampler
    }
    
    /// Asymmetric EMA: fast rises, slow falls, so the reported speed feels
    /// stable without lying about stalls.
    struct SpeedSampler {
        private var lastBytes: Int64 = 0
        private var lastTime: Date?
        private var ema: Double = 0
        
        mutating func sample(bytes: Int64, at time: Date) -> Double? {
            guard let lastTime else {
                self.lastTime = time
                self.lastBytes = bytes
                return nil
            }
            
            let interval = time.timeIntervalSince(lastTime)
            guard interval >= 0.5 else { return ema > 0 ? ema : nil }
            
            let bytesDelta = max(0, bytes - lastBytes)
            let rate = Double(bytesDelta) / interval
            
            ema = ema == 0 ? rate : (rate * 0.35) + (ema * 0.65)
            self.lastTime = time
            self.lastBytes = bytes
            return ema
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard
                        let _ = error,
                        let downloadTask = task as? URLSessionDownloadTask,
                        let download = getDownloadTask(by: downloadTask)
                else {
                        return
                }
                
                DispatchQueue.main.async {
                        if let index = self.getDownloadIndex(by: download.id) {
                                self.downloads.remove(at: index)
                        }
                }
    }
    
    
    /// Persists where a downloaded app came from so update checks stay
    /// accurate after re-signing. Best effort; keyed by bundle id.
    private func _recordProvenance(for download: Download?) {
        guard let download, let meta = download.meta, let bundleID = meta.bundleID else { return }
        AppProvenance.shared.record(
            bundleID: bundleID,
            sourceIdentifier: meta.sourceID,
            sourceURL: download.url,
            appName: meta.appName,
            version: meta.version,
            whatsNew: meta.whatsNew
        )
    }

    // The .ipa has been extracted into Documents by this point, so the archive
    // itself is redundant — but only when it's ours to delete. If the user
    // asked for downloads to be kept, it's sitting in Documents/Downloads
    // deliberately and must stay. Anything else lives in tmp, which was only
    // ever swept at app launch, so a long session held on to every archive it
    // had downloaded.
    private func _removeStagedDownload(at url: URL) {
        guard !OptionsManager.shared.options.saveAppStoreDownloadsToDownloadsFolder else { return }

        // Belt and braces: only ever touch our own staging directory, never a
        // file the user handed us from elsewhere.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("FeatherDownloads", isDirectory: true)

        guard url.path.hasPrefix(staging.path) else { return }

        try? FileManager.default.removeItem(at: url)
    }

    private func _notifyDownloadCompleted(fileName: String) {
        let content = UNMutableNotificationContent()
        content.title = String.localized("Download Completed")
        content.body = fileName
        content.sound = .default
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "download.\(fileName)",
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error { print("Failed to schedule notification: \(error.localizedDescription)") }
        }
    }
}
