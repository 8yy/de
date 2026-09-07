//
//  AutoSignQueue.swift
//  ASign
//
//  Serial background signing queue with per-app certificate pinning,
//  superseded-version cleanup, post-sign installs, certificate self-heal
//  renewals and the app cloner.
//
//  Everything funnels through `FR.signPackageFile`, so the queue inherits the
//  same keep-alive reporting, keep-running and error surfaces as manual
//  signing. Jobs run strictly one at a time — zsign is CPU-bound and the
//  signing pipeline was never designed to run concurrently on-device.
//

import Foundation
import UIKit
import CoreData
import UserNotifications
import SwiftUI

// MARK: - Queue

@MainActor
final class AutoSignQueue: ObservableObject {
    static let shared = AutoSignQueue()

    // MARK: Job model

    enum Reason: String {
        case manual = "Manual"
        case autoSign = "Auto Sign"
        case autoUpdate = "Auto Update"
        case renewal = "Self-Heal"
        case clone = "Clone"
    }

    struct Job: Identifiable {
        let id = UUID()
        let app: AppInfoPresentable
        var reason: Reason
        var pinnedCertificateUUID: String?
        var optionsOverride: Options?
    }

    // MARK: Published state

    @Published private(set) var pending: [Job] = []
    @Published private(set) var isProcessing = false
    @Published private(set) var lastError: String?

    // MARK: Preferences

    /// Automatically delete superseded signed copies after a re-sign.
    @AppStorage("asign.autoDeleteOldVersions") private var _autoDeleteOldVersions: Bool = true
    /// Install automatically once a job finishes (foreground prompt or a
    /// tap-to-install notification when backgrounded).
    @AppStorage("asign.autoInstallAfterSign") private var _autoInstall: Bool = false
    /// Only trigger automatic installs while the device is charging.
    @AppStorage("asign.installChargingOnly") private var _chargingOnly: Bool = false
    /// Re-sign apps this many days before their certificate expires.
    @AppStorage("asign.renewThresholdDays") private var _renewThresholdDays: Int = 3
    @AppStorage("asign.selfHealEnabled") private var _selfHealEnabled: Bool = true

    private let _pinsKey = "asign.appCertificatePins"
    private let _renewedKey = "asign.renewedUUIDs"
    private let _revocationCheckKey = "asign.lastRevocationCheck."

    private init() {}

    // MARK: Certificate pinning

    func pinnedCertificateUUID(forBundleID bundleID: String) -> String? {
        let pins = UserDefaults.standard.dictionary(forKey: _pinsKey) as? [String: String]
        return pins?[bundleID]
    }

    func setPinnedCertificate(_ uuid: String?, forBundleID bundleID: String) {
        var pins = UserDefaults.standard.dictionary(forKey: _pinsKey) as? [String: String] ?? [:]
        if let uuid {
            pins[bundleID] = uuid
        } else {
            pins.removeValue(forKey: bundleID)
        }
        UserDefaults.standard.set(pins, forKey: _pinsKey)
    }

    // MARK: Enqueueing

    func enqueue(
        app: AppInfoPresentable,
        reason: Reason,
        optionsOverride: Options? = nil
    ) {
        let bundleID = app.identifier ?? ""
        let job = Job(
            app: app,
            reason: reason,
            pinnedCertificateUUID: pinnedCertificateUUID(forBundleID: bundleID),
            optionsOverride: optionsOverride
        )
        pending.append(job)
        ActivityLog.shared.add(
            .queued,
            title: String.localized("Queued for signing"),
            detail: "\(app.name ?? bundleID) — \(reason.rawValue)"
        )
        _drainIfNeeded()
    }

    func cancelAll() {
        pending.removeAll()
    }

    // MARK: Serial processing

    private func _drainIfNeeded() {
        guard !isProcessing, !pending.isEmpty else { return }
        isProcessing = true

        // Detached so the queue keeps running if the caller's task is cancelled.
        Task.detached { [weak self] in
            await self?._drain()
        }
    }

    private func _drain() async {
        while true {
            let job: Job? = await MainActor.run {
                guard !pending.isEmpty else { return nil }
                isProcessing = true
                return pending.removeFirst()
            }

            guard let job else { break }

            await _process(job)

            await MainActor.run {
                if pending.isEmpty { isProcessing = false }
            }
        }
    }

    private func _process(_ job: Job) async {
        let app = job.app
        let name = app.name ?? app.identifier ?? "Unknown"

        guard let certificate = _certificate(for: job) else {
            lastError = String.localized("No valid certificate available for signing")
            ActivityLog.shared.add(.failed, title: String.localized("Signing failed"), detail: "\(name) — no certificate")
            return
        }

        var options = job.optionsOverride
            ?? OptionsManager.shared.options.mergingDefaultTweaks()
        _resolveIdentifier(&options, for: app, certificate: certificate)

        let renewalUUID = app.uuid

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            FR.signPackageFile(
                app,
                using: options,
                icon: nil,
                certificate: options.doAdhocSigning ? nil : certificate,
                completion: { [weak self] error in
                    guard let self else { return continuation.resume() }

                    if let error {
                        Task { @MainActor in
                            self.lastError = error.localizedDescription
                            ActivityLog.shared.add(
                                .failed,
                                title: String.localized("Signing failed"),
                                detail: "\(name) — \(error.localizedDescription)"
                            )
                            continuation.resume()
                        }
                        return
                    }

                    Task { @MainActor in
                        ActivityLog.shared.add(
                            .signed,
                            title: String.localized("Signed"),
                            detail: "\(name) — \(job.reason.rawValue)"
                        )

                        self._cleanupSuperseded(app: app, newIdentifier: options.appIdentifier)

                        // Renewal bookkeeping: a freshly renewed app does not
                        // need another renewal pass for a while.
                        if job.reason == .renewal, let renewalUUID {
                            var renewed = UserDefaults.standard.stringArray(forKey: self._renewedKey) ?? []
                            renewed.removeAll { $0 == renewalUUID }
                            renewed.append(renewalUUID)
                            if renewed.count > 400 { renewed.removeFirst(renewed.count - 400) }
                            UserDefaults.standard.set(renewed, forKey: self._renewedKey)
                        }

                        self._maybeInstall(appName: name)
                        continuation.resume()
                    }
                }
            )
        }
    }

    /// Mirrors the identifier resolution the manual signing sheet performs:
    /// per-app dictionaries, prefix/suffix and PPQ protection.
    private func _resolveIdentifier(_ options: inout Options, for app: AppInfoPresentable, certificate: CertificatePair) {
        if options.ppqProtection, let identifier = app.identifier, certificate.ppQCheck {
            options.appIdentifier = "\(identifier).\(options.ppqString)"
        }

        if let currentBundleID = app.identifier, let newBundleID = options.identifiers[currentBundleID] {
            options.appIdentifier = newBundleID
        }

        if let currentName = app.name, let newName = options.displayNames[currentName] {
            options.appName = newName
        }

        if options.prefix != nil || options.suffix != nil {
            var name = app.name ?? ""
            if let dictName = options.displayNames[name] { name = dictName }
            if let prefix = options.prefix { name = prefix + name }
            if let suffix = options.suffix { name = name + suffix }
            options.appName = name
        }
    }

    // MARK: Certificate selection

    /// Pin → default selection → first healthy certificate.
    private func _certificate(for job: Job) -> CertificatePair? {
        let certificates = (try? Storage.shared.context.fetch(CertificatePair.fetchRequest())) ?? []

        if let pinUUID = job.pinnedCertificateUUID,
           let pinned = certificates.first(where: { $0.uuid == pinUUID }),
           Self.isHealthy(pinned) {
            return pinned
        }

        let selectedIndex = UserDefaults.standard.integer(forKey: "feather.selectedCert")
        let sorted = certificates.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        if selectedIndex >= 0, selectedIndex < sorted.count, Self.isHealthy(sorted[selectedIndex]) {
            return sorted[selectedIndex]
        }

        return sorted.first { Self.isHealthy($0) }
    }

    nonisolated static func isHealthy(_ cert: CertificatePair) -> Bool {
        guard !cert.revoked else { return false }
        if let expiration = cert.expiration {
            return expiration > Date()
        }
        return true
    }

    // MARK: Post-sign actions

    /// Deletes earlier signed copies of the same app (matched by original
    /// identifier, which also covers PPQ-renamed duplicates) and optionally the
    /// imported original once it has been re-signed.
    private func _cleanupSuperseded(app: AppInfoPresentable, newIdentifier: String?) {
        guard _autoDeleteOldVersions else { return }
        guard let identifier = app.identifier else { return }

        let request: NSFetchRequest<Signed> = Signed.fetchRequest()
        request.predicate = NSPredicate(format: "identifier == %@", identifier)
        let copies = (try? Storage.shared.context.fetch(request)) ?? []

        for copy in copies where copy.uuid != app.uuid {
            if let url = Storage.shared.getUuidDirectory(for: copy) {
                try? FileManager.default.removeItem(at: url)
            }
            Storage.shared.context.delete(copy)
        }

        if !app.isSigned {
            Storage.shared.deleteApp(for: app)
        }

        try? Storage.shared.context.save()
        _ = newIdentifier // identifier kept for future provenance tracking
    }

    private func _maybeInstall(appName: String) {
        guard _autoInstall else { return }

        if _chargingOnly, UIDevice.current.batteryState == .unplugged {
            _postInstallNotification(appName: appName, waitingForPower: true)
            return
        }

        // Server installs present an itms prompt; only sane while the user is
        // actually looking at the app.
        if UIApplication.shared.applicationState == .active {
            _installQueuedApps()
        } else {
            _postInstallNotification(appName: appName, waitingForPower: false)
        }
    }

    private func _installQueuedApps() {
        let request: NSFetchRequest<Signed> = Signed.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Signed.date, ascending: false)]
        request.fetchLimit = 1
        guard let latest = (try? Storage.shared.context.fetch(request))?.first else { return }
        InstallSession.shared.start(apps: [latest])
    }

    private func _postInstallNotification(appName: String, waitingForPower: Bool) {
        let content = UNMutableNotificationContent()
        content.title = waitingForPower
            ? String.localized("Waiting for power")
            : String.localized("Tap to install")
        content.body = appName
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "asign.autosign.install.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Called from the notification-center delegate when the user taps a
    /// tap-to-install notification.
    func handleInstallRequest() {
        _installQueuedApps()
    }

    // MARK: App cloner

    /// Re-signs an app under `bundleid.cloneNNN` with a fresh display name so
    /// two accounts can live side by side.
    func cloneApp(_ app: AppInfoPresentable) {
        var options = OptionsManager.shared.options.mergingDefaultTweaks()
        let originalIdentifier = app.identifier ?? "app"
        let cloneNumber = Int.random(in: 100...999)
        options.appIdentifier = "\(originalIdentifier).clone\(cloneNumber)"
        options.appName = "\(app.name ?? "App") \(Int.random(in: 2...9))"
        options.ppqProtection = false

        enqueue(app: app, reason: .clone, optionsOverride: options)
    }

    // MARK: Self-heal

    /// Re-signs apps whose certificate expires within the configured threshold
    /// or has been revoked. Revocation re-checks are throttled to once every
    /// six hours per certificate.
    func checkRenewals() {
        guard _selfHealEnabled else { return }

        let request: NSFetchRequest<Signed> = Signed.fetchRequest()
        let signedApps = (try? Storage.shared.context.fetch(request)) ?? []
        let renewed = Set(UserDefaults.standard.stringArray(forKey: _renewedKey) ?? [])

        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: max(0, _renewThresholdDays),
            to: Date()
        ) ?? Date()

        // Throttled revocation screening so a renewal sweep doesn't hammer the
        // Apple endpoint for every certificate at once.
        for cert in Set(signedApps.compactMap(\.certificate)) {
            let key = "\(_revocationCheckKey)\(cert.uuid ?? "?")"
            let last = UserDefaults.standard.double(forKey: key)
            if Date().timeIntervalSince1970 - last > 6 * 3600 {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)
                Storage.shared.revokagedCertificate(for: cert)
            }
        }

        for app in signedApps {
            guard let uuid = app.uuid, !renewed.contains(uuid) else { continue }
            guard let cert = app.certificate else { continue }

            let needsRenewal: Bool
            if cert.revoked {
                needsRenewal = true
            } else if let expiration = cert.expiration {
                needsRenewal = expiration <= cutoff
            } else {
                needsRenewal = false
            }

            guard needsRenewal else { continue }

            // Only renew with a cert that will actually outlive the current one.
            let target = _certificate(
                for: Job(app: app, reason: .renewal, pinnedCertificateUUID: nil, optionsOverride: nil)
            )
            guard let target, target != cert, Self.isHealthy(target) else { continue }

            enqueue(app: app, reason: .renewal)
        }
    }
}
