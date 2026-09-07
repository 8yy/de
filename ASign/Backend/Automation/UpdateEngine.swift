//
//  UpdateEngine.swift
//  ASign
//
//  Cross-source update checking, per-app update controls and automatic
//  background downloads.
//
//  Matching strategy, in order:
//    1. Source hint — when an app was downloaded through the App Store tab the
//       source app context is recorded in `AppProvenance`, keyed by bundle id.
//    2. Bundle-id scan — every enabled source is searched for an app whose
//       bundle identifier matches the library entry. This is what keeps
//       updates working for apps that were imported from Files or re-signed
//       under a PPQ-protected identifier (the *unsigned* id is what matches).
//

import Foundation
import UIKit
import AltSourceKit
import CoreData
import UserNotifications
import Network
import SwiftUI

// MARK: - Model

struct AppUpdate: Identifiable, Hashable {
    let localUUID: String
    let isSigned: Bool
    let bundleID: String
    let appName: String
    let localVersion: String
    let remoteVersion: String
    let downloadURL: URL
    let whatsNew: String?
    let sourceID: String?

    var id: String { localUUID }
}

// MARK: - Provenance store

/// Lightweight, JSON-persisted hints that remember where each bundle id came
/// from so update checks can prefer the right source. Survives re-signing.
final class AppProvenance {
    static let shared = AppProvenance()

    private struct Entry: Codable {
        var sourceIdentifier: String?
        var sourceURL: String?
        var appName: String?
        var lastVersion: String?
        var whatsNew: String?
        var recordedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let _key = "asign.appProvenance"
    private let _queue = DispatchQueue(label: "com.asign.signer.provenance")

    private init() {
        if
            let data = UserDefaults.standard.data(forKey: _key),
            let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        {
            entries = decoded
        }
    }

    func record(
        bundleID: String,
        sourceIdentifier: String?,
        sourceURL: URL?,
        appName: String?,
        version: String?,
        whatsNew: String?
    ) {
        _queue.async {
            self.entries[bundleID] = Entry(
                sourceIdentifier: sourceIdentifier,
                sourceURL: sourceURL?.absoluteString,
                appName: appName,
                lastVersion: version,
                whatsNew: whatsNew,
                recordedAt: Date()
            )
            self._persist()
        }
    }

    func hint(forBundleID bundleID: String) -> (sourceIdentifier: String?, sourceURL: URL?) {
        _queue.sync {
            guard let entry = entries[bundleID] else { return (nil, nil) }
            return (entry.sourceIdentifier, entry.sourceURL.flatMap(URL.init(string:)))
        }
    }

    func clear() {
        _queue.async {
            self.entries.removeAll()
            self._persist()
        }
    }

    private func _persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: _key)
        }
    }
}

// MARK: - Engine

@MainActor
final class UpdateEngine: ObservableObject {
    static let shared = UpdateEngine()

    // MARK: Published state

    @Published private(set) var updates: [AppUpdate] = []
    @Published private(set) var isChecking = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var isAutoDownloading = false

    // MARK: Preferences

    /// Hours between automatic checks. 0 disables the timer.
    @AppStorage("asign.autoUpdateInterval") private var _autoUpdateInterval: Int = 6
    @AppStorage("asign.autoUpdateWifiOnly") private var _wifiOnly: Bool = true
    @AppStorage("asign.autoDownloadUpdates") private var _autoDownload: Bool = false
    @AppStorage("asign.updateBadge") private var _badgeEnabled: Bool = true
    @AppStorage("asign.updateNotifications") private var _notificationsEnabled: Bool = true
    @AppStorage("asign.lastUpdateCheck") private var _lastCheckStored: Double = 0

    private var _timer: Timer?
    private var _pathMonitor: NWPathMonitor?
    private var _checkTask: Task<Void, Never>?

    private let _skippedKey = "asign.skippedVersions"
    private let _heldKey = "asign.heldApps"

    private init() {}

    // MARK: Lifecycle

    func start() {
        _startPathMonitor()
        _rescheduleTimer()

        // Throttled catch-up check on launch.
        let hours = max(0, _autoUpdateInterval)
        guard hours > 0 else { return }
        let last = Date(timeIntervalSince1970: _lastCheckStored)
        if Date().timeIntervalSince(last) > TimeInterval(hours * 3600) {
            checkForUpdates(showResults: false)
        }
    }

    func stop() {
        _timer?.invalidate()
        _timer = nil
        _pathMonitor?.cancel()
        _pathMonitor = nil
    }

    private func _startPathMonitor() {
        guard _pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        _pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            _ = path
        }
        monitor.start(queue: DispatchQueue(label: "com.asign.signer.pathmonitor"))
    }

    private func _rescheduleTimer() {
        _timer?.invalidate()
        _timer = nil

        let hours = max(0, _autoUpdateInterval)
        guard hours > 0 else { return }

        let timer = Timer(
            timeInterval: min(TimeInterval(hours * 3600), 15 * 60),
            target: self,
            selector: #selector(_timerFired),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        _timer = timer
    }

    @objc private func _timerFired() {
        let hours = max(0, _autoUpdateInterval)
        guard hours > 0 else { return }
        let last = Date(timeIntervalSince1970: _lastCheckStored)
        guard Date().timeIntervalSince(last) >= TimeInterval(hours * 3600) else { return }
        checkForUpdates(showResults: false)
    }

    // MARK: Connectivity gates

    private var _networkAllowsDownload: Bool {
        guard _wifiOnly else { return true }
        guard let path = _pathMonitor?.currentPath else { return true }
        return !path.isExpensive
    }

    // MARK: Checking

    func checkForUpdates(showResults: Bool) {
        guard !isChecking else { return }
        isChecking = true

        _checkTask?.cancel()
        _checkTask = Task { [weak self] in
            guard let self else { return }
            do {
                let found = try await self._scanForUpdates()
                self.updates = found
                self.lastChecked = Date()
                self._lastCheckStored = Date().timeIntervalSince1970
                self._updateBadge()
                self._notifyAboutNewUpdates(found)

                if self._autoDownload && self._networkAllowsDownload && !found.isEmpty {
                    self.downloadAllPendingUpdates()
                } else if showResults {
                    ActivityLog.shared.add(
                        .updateCheck,
                        title: String.localized("Checked for updates"),
                        detail: String(format: String.localized("%d update(s) available"), found.count)
                    )
                }
                self.isChecking = false
            } catch {
                self.isChecking = false
            }
        }
    }

    nonisolated private func _fetchSource(_ url: URL) async throws -> ASRepository {
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(ASRepository.self, from: data)
    }

    private func _scanForUpdates() async throws -> [AppUpdate] {
        let sources = Storage.shared.getSources()
        let repos = await _fetchRepos(from: sources)

        // Build a lookup of every remote app across every source.
        var remote: [String: (app: ASRepository.App, source: AltSource)] = [:]
        for (source, repo) in repos {
            for app in repo.apps {
                guard let bundleID = app.id, remote[bundleID] == nil else { continue }
                remote[bundleID] = (app, source)
            }
        }

        let signedRequest: NSFetchRequest<Signed> = Signed.fetchRequest()
        let importedRequest: NSFetchRequest<Imported> = Imported.fetchRequest()
        let signed = (try? Storage.shared.context.fetch(signedRequest)) ?? []
        let imported = (try? Storage.shared.context.fetch(importedRequest)) ?? []

        struct LibraryEntry {
            var identifier: String?
            var version: String?
            var uuid: String?
            var isSigned: Bool
            var name: String?
        }
        var library: [LibraryEntry] = []
        for app in signed {
            library.append(LibraryEntry(identifier: app.identifier, version: app.version, uuid: app.uuid, isSigned: true, name: app.name))
        }
        for app in imported {
            library.append(LibraryEntry(identifier: app.identifier, version: app.version, uuid: app.uuid, isSigned: false, name: app.name))
        }
        var found: [AppUpdate] = []

        for entry in library {
            guard
                let bundleID = entry.identifier,
                !bundleID.isEmpty,
                let remoteApp = remote[bundleID],
                !_isHeld(bundleID)
            else { continue }

            let remoteVersion = remoteApp.app.version ?? remoteApp.app.versions?.first?.version
            let localVersion = entry.version ?? "0"
            guard
                let remoteVersion,
                Self.compareVersions(remoteVersion, localVersion) > 0,
                !_isSkipped(bundleID: bundleID, version: remoteVersion)
            else { continue }

            guard let downloadURL = remoteApp.app.currentDownloadUrl else { continue }

            found.append(
                AppUpdate(
                    localUUID: entry.uuid ?? UUID().uuidString,
                    isSigned: entry.isSigned,
                    bundleID: bundleID,
                    appName: remoteApp.app.name ?? entry.name ?? bundleID,
                    localVersion: localVersion,
                    remoteVersion: remoteVersion,
                    downloadURL: downloadURL,
                    whatsNew: remoteApp.app.versionDescription ?? remoteApp.app.versions?.first?.localizedDescription,
                    sourceID: remoteApp.source.identifier
                )
            )
        }

        return found.sorted {
            $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
    }

    nonisolated private func _fetchRepos(from sources: [AltSource]) async -> [(AltSource, ASRepository)] {
        await withTaskGroup(of: (AltSource, ASRepository?).self) { group in
            for source in sources {
                guard let url = source.sourceURL else { continue }
                group.addTask { [weak self] in
                    do {
                        return (source, try await self?._fetchSource(url))
                    } catch {
                        return (source, nil)
                    }
                }
            }

            var result: [(AltSource, ASRepository)] = []
            for await (source, repo) in group {
                if let repo { result.append((source, repo)) }
            }
            return result
        }
    }

    // MARK: Per-app controls

    func skipThisVersion(_ update: AppUpdate) {
        var skipped = UserDefaults.standard.stringArray(forKey: _skippedKey) ?? []
        skipped.append("\(update.bundleID)|\(update.remoteVersion)")
        UserDefaults.standard.set(skipped, forKey: _skippedKey)
        updates.removeAll { $0.id == update.id }
        _updateBadge()
    }

    func holdUpdates(for update: AppUpdate) {
        holdUpdates(forBundleID: update.bundleID)
        updates.removeAll { $0.id == update.id }
        _updateBadge()
    }

    func holdUpdates(forBundleID bundleID: String) {
        var held = UserDefaults.standard.stringArray(forKey: _heldKey) ?? []
        if !held.contains(bundleID) { held.append(bundleID) }
        UserDefaults.standard.set(held, forKey: _heldKey)
    }

    func resumeUpdates(forBundleID bundleID: String) {
        var held = UserDefaults.standard.stringArray(forKey: _heldKey) ?? []
        held.removeAll { $0 == bundleID }
        UserDefaults.standard.set(held, forKey: _heldKey)
    }

    func heldBundleIDs() -> [String] {
        UserDefaults.standard.stringArray(forKey: _heldKey) ?? []
    }

    func skippedEntries() -> [String] {
        UserDefaults.standard.stringArray(forKey: _skippedKey) ?? []
    }

    private func _isSkipped(bundleID: String, version: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: _skippedKey) ?? []).contains("\(bundleID)|\(version)")
    }

    private func _isHeld(_ bundleID: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: _heldKey) ?? []).contains(bundleID)
    }

    // MARK: Downloading

    func download(_ update: AppUpdate) {
        updates.removeAll { $0.id == update.id }
        _startAutoDownload(update)
        _updateBadge()
    }

    func downloadAllPendingUpdates() {
        guard !updates.isEmpty else { return }
        isAutoDownloading = true
        let pending = updates
        updates.removeAll()
        _updateBadge()

        for update in pending {
            _startAutoDownload(update)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.isAutoDownloading = false
        }
    }

    private func _startAutoDownload(_ update: AppUpdate) {
        _ = DownloadManager.shared.startDownload(
            from: update.downloadURL,
            id: "asign.autoupdate.\(update.bundleID).\(update.remoteVersion)",
            meta: Download.SourceMeta(
                bundleID: update.bundleID,
                sourceID: update.sourceID,
                appName: update.appName,
                version: update.remoteVersion,
                whatsNew: update.whatsNew
            )
        )
        ActivityLog.shared.add(
            .downloading,
            title: String.localized("Downloading update"),
            detail: "\(update.appName) \(update.remoteVersion)"
        )
    }

    // MARK: Badge + notifications

    private func _updateBadge() {
        guard _badgeEnabled else { return }
        UIApplication.shared.applicationIconBadgeNumber = updates.isEmpty ? 0 : updates.count
    }

    private func _notifyAboutNewUpdates(_ found: [AppUpdate]) {
        guard _notificationsEnabled, !found.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = String.localized("Updates Available")
        content.body = found.prefix(3).map { $0.appName }.joined(separator: ", ")
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "asign.updates.\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    static func requestNotificationPermissionIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: Version comparison

    /// Returns > 0 when `lhs` is newer than `rhs`, < 0 when older, 0 when equal.
    /// Non-numeric suffixes ("1.2.3-beta") compare lower than their base.
    static func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        let leftParts = lhs.split(separator: ".").map(String.init)
        let rightParts = rhs.split(separator: ".").map(String.init)
        let count = max(leftParts.count, rightParts.count)

        for index in 0..<count {
            let l = index < leftParts.count ? _numericPrefix(leftParts[index]) : 0
            let r = index < rightParts.count ? _numericPrefix(rightParts[index]) : 0
            if l != r { return l < r ? -1 : 1 }
        }

        // Equal numerically: a version with a suffix is considered older.
        let lHasSuffix = leftParts.contains { !$0.allSatisfy(\.isNumber) }
        let rHasSuffix = rightParts.contains { !$0.allSatisfy(\.isNumber) }
        if lHasSuffix != rHasSuffix { return lHasSuffix ? -1 : 1 }
        return 0
    }

    private static func _numericPrefix(_ string: String) -> Int {
        let digits = string.prefix { $0.isNumber }
        return Int(digits) ?? 0
    }
}
